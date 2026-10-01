import Foundation
import MLX
import SmallMGEMM
import MLXNN
import MLXAudioCore
import MLXLMCommon

/// Parakeet TDT (the only NeMo target Vella ships: `EncDecRNNTBPEModel` with TDT durations).
public final class ParakeetModel: Module, STTGenerationModel {
    public let preprocessConfig: ParakeetPreprocessConfig
    public let encoderConfig: ParakeetConformerConfig

    public let vocabulary: [String]
    public let durations: [Int]
    public let maxSymbols: Int?

    /// Compute dtype applied to encoder features and decoder LSTM state.
    /// Defaults to `.bfloat16` (measured ~8% wall-clock speedup on batched decode
    /// with ~0.2% word drift). Set to `.float32` via the factory method to fall back.
    public var computeDType: DType = .bfloat16

    struct TDTTraceStep: Sendable, Equatable {
        let row: Int
        let time: Int
        let newSymbols: Int
        let token: Int
        let decisionIndex: Int
        let committedState: Bool
    }

    @ModuleInfo(key: "encoder") var encoder: ParakeetConformer
    @ModuleInfo(key: "decoder") var decoder: ParakeetPredictNetwork?
    @ModuleInfo(key: "joint") var joint: ParakeetJointNetwork?

    var tdtTraceEmitter: (@Sendable (TDTTraceStep) -> Void)?
    private var fastEncoder: FastParakeetEncoder?
    private var fastDecoder: FastParakeetTDT?
    private var fastTokenSink: ((Int) -> Void)?
    public private(set) var fastPathFinite = true
    public private(set) var fastPathError: String?
    private static let profilePath: String? = {
        guard let p = ProcessInfo.processInfo.environment["VELLA_PARAKEET_PROFILE"], p.hasPrefix("/") else { return nil }
        return p
    }()

    // FastPathCapable (worker gate + runtime fallback). The revision is hashed into the gate key:
    // bump it whenever kernels, the default component set or the clip set change.
    /// The NAX GEMM kernel (FastParakeetNAX) adds its own suffix when enabled (nax2: tolerance self-test, two-stage),
    /// with the shared SmallMGEMM package's tile revision since the kernel moved there. The opt-in integer encoders add
    /// theirs (int8-2/int4-2: native tile rows only, each self-testing its own bit width's classes).
    public static var fastPathRevision: String {
        "parakeet-r2-dense-encoder"
            + (FastParakeetNAX.enabled ? "+nax2+smallm-" + SmallMGEMM.tileRevision : "")
            + (FastParakeetInt8.enabled ? "+int8-2+smallm-" + SmallMGEMM.qtileRevision : "")
            + (FastParakeetInt8.int4Enabled ? "+int4-2+smallm-" + SmallMGEMM.qtileRevision : "")
            + FastParakeetDecodeOptions.revisionSuffix
    }
    /// The dtype the worker converts request samples to before `generate`: the log-mel is computed in it (BF16,
    /// matching mlx-audio's rounding).
    public static let inputDType: DType = .bfloat16
    /// Token-exact on all five bundled public clips for every precision (4b, 8b, BF16, FP32, ternary).
    public var fastPathSelfTestClips: [String] { ["clip-a", "clip-b", "clip-c", "clip-d", "clip-e"] }
    /// `nax_gemm` is reported only where it could run (enabled, dense BF16 checkpoint, eligible GPU): a false entry
    /// reads as "stock: nax_gemm" in the engine tooltip and `vella diagnose`, i.e. its self-test disabled it.
    public var fastPathComponents: [String: Bool] {
        var components = ["encoder": fastEncoder != nil, "decoder": fastDecoder != nil]
        if naxEligible { components["nax_gemm"] = fastEncoder?.useNAX ?? false }
        if let integerComponent { components[integerComponent] = fastEncoder?.useInt8 ?? false }
        return components
    }
    /// The native-integer encoder's gate component on this checkpoint and Mac (`int8_gemm` / `int4_gemm`), or nil:
    /// its switch on, an 8/4-bit affine group-64 encoder with BF16 scales, a GPU with tensor ops.
    var integerComponent: String? {
        guard FastParakeetInt8.available, let q = encoder.layers.first?.relSelfAttn?.linearQ as? QuantizedLinear else { return nil }
        return FastParakeetInt8.component(bits: q.bits, groupSize: q.groupSize, mode: q.mode, scales: q.scales)
    }
    /// NAX would run on this checkpoint and Mac: enabled, a dense BF16 encoder, a GPU with tensor ops.
    var naxEligible: Bool {
        guard FastParakeetNAX.enabled, FastParakeetNAX.available, let q = encoder.layers.first?.relSelfAttn?.linearQ,
              !(q is QuantizedLinear) else { return false }
        return q.weight.dtype == .bfloat16
    }
    /// Two-stage gate: the NAX GEMMs are the one inexact component; the fused encoder and decoder stay token-exact.
    public var fastPathTolerantComponents: [String] { (naxEligible ? ["nax_gemm"] : []) + (integerComponent.map { [$0] } ?? []) }
    public var fastPathDisabledComponents: Set<String> = []
    /// SentencePiece pieces joined, split at the word marker (special tokens dropped), as the transcript reads.
    public func qualificationWords(_ tokens: [Int]) -> [String] {
        ParakeetTokenizer.decode(tokens: tokens, vocabulary: vocabulary).split(whereSeparator: \.isWhitespace).map(String.init)
    }
    /// Self-test bound on the NAX GEMMs: relative RMS of the fused encoder's output with vs without them, per clip.
    /// The kernel only reorders BF16 sums, so the difference is rounding: 0.014–0.085 on the five clips for Ultra and
    /// v3 BF16 (the fused MLX-GEMM path itself sits 0.014–0.065 from the stock modules), while injected kernel faults
    /// (a dropped K slice, one zeroed column in 32, a zeroed last row) gave 0.46–0.98 (M5 Max, 28 Sep 2026).
    static let naxMaxDeviation: Float = 0.2
    /// Self-test bound on the native int8 GEMMs: relative RMS of the BF16-activation encoder's output with vs without
    /// them (MLX's quantized matmul and matmul instead), per clip. Calibration in lab/models/Parakeet/L3-int8.md.
    static let int8MaxDeviation: Float = 0.2
    /// Relative RMS ||kernel − mlx|| / ||mlx|| of the fused encoder output on `audio`'s log-mel with the active inexact
    /// GEMM component (NAX or native int8) on vs off (non-finite → ∞), or nil when neither is active.
    public func naxEncoderDeviation(audio: MLXArray) -> Float? {
        if let fastEncoder, fastEncoder.useInt8 {
            let mel = ParakeetAudio.logMelSpectrogram(normalizeAudioToMono(audio), config: preprocessConfig)
            var features = mel.ndim == 2 ? mel.expandedDimensions(axis: 0) : mel
            features = features.asType(computeDType)
            let lengths = MLXArray([Int32(features.shape[1])])
            fastEncoder.useInt8 = false
            let reference = fastEncoder.call(features, lengths: lengths).0.asType(.float32)
            fastEncoder.useInt8 = true
            let int8 = fastEncoder.call(features, lengths: lengths).0.asType(.float32)
            let delta = int8 - reference
            let value = MLX.sqrt((delta * delta).sum() / (reference * reference).sum()).item(Float.self)
            FastPathGate.debug("frames \(features.shape[1]) int8 vs bf16-mlx \(value) dtype \(int8.dtype)")
            return value.isFinite ? value : .infinity
        }
        guard let fastEncoder, fastEncoder.useNAX else { return nil }
        let mel = ParakeetAudio.logMelSpectrogram(normalizeAudioToMono(audio), config: preprocessConfig)
        var features = mel.ndim == 2 ? mel.expandedDimensions(axis: 0) : mel
        features = features.asType(computeDType)
        let lengths = MLXArray([Int32(features.shape[1])])
        fastEncoder.useNAX = false
        let reference = fastEncoder.call(features, lengths: lengths).0.asType(.float32)
        fastEncoder.useNAX = true
        let nax = fastEncoder.call(features, lengths: lengths).0.asType(.float32)
        let delta = nax - reference
        let value = MLX.sqrt((delta * delta).sum() / (reference * reference).sum()).item(Float.self)
        if ProcessInfo.processInfo.environment["VELLA_KERNEL_DEBUG_LOG"] != nil {
            // Lab calibration: how far the (already accepted) fused MLX-GEMM encoder sits from the stock modules.
            let stock = encoder(features, lengths: lengths).0.asType(.float32)
            let d1 = reference - stock, d2 = nax - stock
            let v = MLX.stacked([MLX.sqrt((d1 * d1).sum() / (stock * stock).sum()), MLX.sqrt((d2 * d2).sum() / (stock * stock).sum())]).asArray(Float.self)
            FastPathGate.debug("frames \(features.shape[1]) fused-mlx vs stock \(v[0]) nax vs stock \(v[1]) nax vs fused-mlx \(value)")
        }
        return value.isFinite ? value : .infinity
    }

    /// Only the worker's isolated model-specific token-ID qualification enables these paths.
    public func configureFastPath(enabled: Bool, component: String = "both") -> Bool {
        fastEncoder = nil
        fastDecoder = nil
        guard enabled else { return false }
        // Diagnosis/A-B only: VELLA_PARAKEET_FAST overrides the default component set.
        var component = component
        if component == "both", let forced = ProcessInfo.processInfo.environment["VELLA_PARAKEET_FAST"], !forced.isEmpty { component = forced }
        guard ["both", "all", "decoder", "encoder", "encoder-no-fused-conv"].contains(component) else { return false }
        let quantized = encoder.layers.first?.relSelfAttn?.linearQ is QuantizedLinear
        let wantsDecoder = component == "both" || component == "all" || component == "decoder"
        let wantsEncoder = component.hasPrefix("encoder") || component == "all" || component == "both"
        if wantsDecoder {
            guard let prepared = FastParakeetTDT(self) else { fastEncoder = nil; return false }
            fastDecoder = prepared
        }
        if wantsEncoder {
            // Quantized checkpoints keep FP32 activations; dense ones run in their own dtype.
            let dense = encoder.layers.first?.relSelfAttn?.linearQ.weight.dtype ?? .bfloat16
            // The native int8 encoder (tolerant component `int8_gemm`) runs an eligible 8-bit checkpoint in BF16.
            let int8 = quantized && integerComponent.map { !fastPathDisabledComponents.contains($0) } ?? false
            let dtype: DType = int8 ? .bfloat16 : quantized ? .float32 : (dense.isFloatingPoint ? dense : .bfloat16)
            guard let prepared = FastParakeetEncoder(encoder, dense: !quantized, dtype: dtype,
                                                     fusedConvolution: component != "encoder-no-fused-conv",
                                                     nax: FastParakeetNAX.enabled && !fastPathDisabledComponents.contains("nax_gemm"),
                                                     int8: int8) else {
                fastDecoder = nil
                return false
            }
            fastEncoder = prepared
        }
        return true
    }

    /// Qualification compares emitted token IDs, not formatted transcripts.
    public func qualificationTokens(audio: MLXArray) -> [Int] {
        final class Sink: @unchecked Sendable { var ids: [Int] = [] }
        let sink = Sink()
        tdtTraceEmitter = { step in if step.committedState { sink.ids.append(step.token) } }
        fastTokenSink = { sink.ids.append($0) }
        defer { tdtTraceEmitter = nil; fastTokenSink = nil }
        _ = generate(audio: audio, generationParameters: STTGenerateParameters(maxTokens: 1024, verbose: false, chunkDuration: 30))
        // Inexact component (tolerance self-test): the encoder output must stay within rounding of the MLX-GEMM fused
        // path; a larger deviation fails the component like non-finite output. The word-edit bound is the gate's.
        if let deviation = naxEncoderDeviation(audio: audio) {
            FastPathGate.debug("nax encoder deviation rms \(deviation)")
            if fastEncoder?.useInt8 == true, let integerComponent {
                // Only this component's own classes: a failure of the other bit width cannot disable it.
                let failures = FastParakeetInt8.libraryFailures(component: integerComponent)
                if !failures.isEmpty {
                    fastPathFinite = false
                    fastPathError = "SmallMGEMM self-test failed: \(failures.joined(separator: ", "))"
                } else if !(deviation <= Self.int8MaxDeviation) {
                    fastPathFinite = false
                    fastPathError = "int8 GEMM deviation \(deviation) > \(Self.int8MaxDeviation)"
                }
            } else if !FastParakeetNAX.libraryFailures.isEmpty {
                fastPathFinite = false
                fastPathError = "SmallMGEMM self-test failed: \(FastParakeetNAX.libraryFailures.joined(separator: ", "))"
            } else if !(deviation <= Self.naxMaxDeviation) {
                fastPathFinite = false
                fastPathError = "NAX GEMM deviation \(deviation) > \(Self.naxMaxDeviation)"
            }
        }
        return sink.ids
    }

    public var defaultGenerationParameters: STTGenerateParameters {
        STTGenerateParameters(
            maxTokens: 8192,
            temperature: 0.0,
            topP: 0.95,
            topK: 0,
            verbose: false,
            language: "en",
            chunkDuration: 1200.0,
            minChunkDuration: 1.0
        )
    }

    private var blankTokenId: Int {
        vocabulary.count
    }

    #if VELLA_QUALIFICATION
    private var qualificationMelOverride: MLXArray?
    private var qualificationObserver: (([MLXArray], MLXArray) -> Void)?
    #endif

    private lazy var compiledTDTStep = makeCompiledTDTStep(
        decoder: self.decoder,
        joint: self.joint,
        blankTokenId: self.blankTokenId
    )

    private init(
        preprocessConfig: ParakeetPreprocessConfig,
        encoderConfig: ParakeetConformerConfig,
        vocabulary: [String],
        durations: [Int],
        maxSymbols: Int?,
        decoderConfig: ParakeetPredictConfig?,
        jointConfig: ParakeetJointConfig?
    ) {
        self.preprocessConfig = preprocessConfig
        self.encoderConfig = encoderConfig
        self.vocabulary = vocabulary
        self.durations = durations
        self.maxSymbols = maxSymbols

        self._encoder.wrappedValue = ParakeetConformer(args: encoderConfig)
        if let decoderConfig {
            self._decoder.wrappedValue = ParakeetPredictNetwork(args: decoderConfig)
        } else {
            self._decoder.wrappedValue = nil
        }
        if let jointConfig {
            self._joint.wrappedValue = ParakeetJointNetwork(args: jointConfig)
        } else {
            self._joint.wrappedValue = nil
        }
    }

    public func generate(
        audio: MLXArray,
        generationParameters: STTGenerateParameters
    ) -> STTOutput {
        fastPathFinite = true
        fastPathError = nil
        let audio1D = normalizeAudioToMono(audio)
        let sampleRate = preprocessConfig.sampleRate
        let totalSamples = audio1D.shape[0]
        let audioDuration = Double(totalSamples) / Double(sampleRate)
        let chunkDuration = Double(generationParameters.chunkDuration)
        let overlapDuration = 2.0

        let result: ParakeetAlignedResult
        if chunkDuration <= 0 || audioDuration <= chunkDuration {
            result = decodeChunk(audio1D)
        } else {
            let chunkSamples = max(1, Int(chunkDuration * Double(sampleRate)))
            let overlapSamples = max(0, min(chunkSamples - 1, Int(overlapDuration * Double(sampleRate))))
            let stepSamples = max(1, chunkSamples - overlapSamples)

            var allTokens: [ParakeetAlignedToken] = []
            var start = 0
            while start < totalSamples {
                let end = min(start + chunkSamples, totalSamples)
                let chunkAudio = audio1D[start..<end]
                let chunkResult = decodeChunk(chunkAudio)

                var chunkTokens = flattenTokens(from: chunkResult)
                let chunkOffset = Double(start) / Double(sampleRate)
                for i in chunkTokens.indices {
                    chunkTokens[i].start += chunkOffset
                }

                allTokens = mergeTokenSequences(
                    existing: allTokens,
                    incoming: chunkTokens,
                    overlapDuration: overlapDuration
                )

                start += stepSamples
            }

            result = ParakeetAlignment.sentencesToResult(ParakeetAlignment.tokensToSentences(allTokens))
        }

        return STTOutput(
            text: result.text,
            segments: result.segments,
            language: generationParameters.language
        )
    }

    func decode(mel: MLXArray, lengths: MLXArray? = nil) -> [ParakeetAlignedResult] {
        decodeTDT(mel: mel, lengths: lengths)
    }

    func encodeBatchFeatures(_ features: MLXArray, lengths: MLXArray? = nil) -> (MLXArray, MLXArray) {
        let resolvedLengths = lengths ?? MLXArray(Array(repeating: Int32(features.shape[1]), count: features.shape[0])).asType(.int32)
        if features.shape[0] == 1, let fastEncoder {
            do {
                return try MLX.withError {
                    let encoded = fastEncoder.call(features, lengths: resolvedLengths)
                    MLX.eval(encoded.0, encoded.1)
                    return encoded
                }
            } catch {
                fastPathFinite = false
                fastPathError = String(describing: error)
                return encoder(features, lengths: resolvedLengths)
            }
        }
        return encoder(features, lengths: resolvedLengths)
    }

    private func decodeTDT(mel: MLXArray, lengths: MLXArray? = nil) -> [ParakeetAlignedResult] {
        var features = mel
        if features.ndim == 2 {
            features = features.expandedDimensions(axis: 0)
        }

        assert(
            features.ndim == 3 && features.shape[2] == preprocessConfig.features,
            "Parakeet TDT input feature shape mismatch: expected [B, T, \(preprocessConfig.features)], got \(features.shape)"
        )

        features = features.asType(computeDType)
        guard let profile = Self.profilePath else {
            let encoded = encodeBatchFeatures(features, lengths: lengths)
            return decodeTDTEncoded(batchFeatures: encoded.0, lengths: encoded.1)
        }
        // VELLA_PARAKEET_PROFILE=/abs/path: append "frames encoder_s decoder_s ... mel_s= blocks=" per chunk. The log-mel
        // is evaluated first, so encoder_s excludes it; blocks = 32-step fast decoder blocks (-1: stock decoder).
        let tm = CFAbsoluteTimeGetCurrent()
        eval(features)
        let t0 = CFAbsoluteTimeGetCurrent()
        let encoded = encodeBatchFeatures(features, lengths: lengths)
        eval(encoded.0, encoded.1)
        let t1 = CFAbsoluteTimeGetCurrent()
        let result = decodeTDTEncoded(batchFeatures: encoded.0, lengths: encoded.1)
        let t2 = CFAbsoluteTimeGetCurrent()
        if let handle = FileHandle(forWritingAtPath: profile) {
            _ = try? handle.seekToEnd()
            let finiteEncoded = MLX.all(MLX.isFinite(encoded.0)).item(Bool.self)
            try? handle.write(contentsOf: Data("\(features.shape[1]) \(t1 - t0) \(t2 - t1) enc_finite=\(finiteEncoded) fast_finite=\(fastPathFinite) err=\(fastPathError ?? "-") mel_s=\(t0 - tm) blocks=\(fastDecoder?.lastBlocks ?? -1) active=\(fastDecoder?.lastActive ?? -1)\n".utf8))
            try? handle.close()
        }
        return result
    }

    private func decodeTDTEncoded(batchFeatures: MLXArray, lengths: MLXArray) -> [ParakeetAlignedResult] {
        guard let decoder, let joint else { return [] }

        assert(
            batchFeatures.ndim == 3 && batchFeatures.shape[2] == encoderConfig.dModel,
            "Parakeet TDT encoder output shape mismatch: expected last dim \(encoderConfig.dModel), got \(batchFeatures.shape)"
        )
        eval(batchFeatures, lengths)

        if batchFeatures.shape[0] == 1, let fastDecoder {
            let result = fastDecoder.decode(batchFeatures, length: Int(lengths[0].item(Int32.self)), onToken: fastTokenSink)
            fastPathError = fastDecoder.lastError
            fastPathFinite = fastPathFinite && fastDecoder.lastFinite
                && MLX.all(MLX.isFinite(batchFeatures)).item(Bool.self)
            return [result]
        }

        return decodeTDTSerial(batchFeatures: batchFeatures, lengths: lengths, decoder: decoder, joint: joint)
    }

    private func decodeTDTSerial(
        batchFeatures: MLXArray,
        lengths: MLXArray,
        decoder: ParakeetPredictNetwork,
        joint: ParakeetJointNetwork
    ) -> [ParakeetAlignedResult] {

        var results: [ParakeetAlignedResult] = []
        let batchSize = batchFeatures.shape[0]
        let blankToken = blankTokenId

        for b in 0..<batchSize {
            let featureSeq = batchFeatures[b..<(b + 1)]
            let maxLength = Int(lengths[b].item(Int32.self))

            var lastToken = blankToken
            var hypothesis: [ParakeetAlignedToken] = []

            var t = 0
            var newSymbols = 0
            var state = makeInitialDecoderState(batchSize: 1, dtype: featureSeq.dtype)
            var currentToken = MLXArray(Int32(lastToken)).reshaped([1, 1]).asType(.int32)

            while t < maxLength {
                let frame = featureSeq[0..., t..<(t + 1), 0...]

                let stepOutputs = compiledTDTStep([
                    frame,
                    currentToken,
                    state.hidden!,
                    state.cell!
                ])
                let decisions = stepOutputs[0]
                let hidden = stepOutputs[1]
                let cell = stepOutputs[2]
                MLX.eval(decisions, hidden, cell)
                #if VELLA_QUALIFICATION
                qualificationObserver?([frame, currentToken, state.hidden!, state.cell!], decisions)
                #endif
                let decisionPair = decisions.asArray(Int32.self)
                let token = Int(decisionPair[0])
                let decisionIndex = Int(decisionPair[1])
                let step = ParakeetDecodingLogic.tdtStep(
                    predictedToken: token,
                    blankToken: blankToken,
                    decisionIndex: decisionIndex,
                    durations: durations,
                    time: t,
                    newSymbols: newSymbols,
                    maxSymbols: maxSymbols
                )

                tdtTraceEmitter?(
                    TDTTraceStep(
                        row: b,
                        time: t,
                        newSymbols: newSymbols,
                        token: token,
                        decisionIndex: decisionIndex,
                        committedState: token != blankToken
                    )
                )

                if token != blankToken {
                    lastToken = token
                    state = (hidden: hidden, cell: cell)
                    currentToken = MLXArray(Int32(lastToken)).reshaped([1, 1]).asType(.int32)
                    if !ParakeetTokenizer.isSpecialToken(token, vocabulary: vocabulary) {
                        let start = frameTimeSeconds(frameIndex: t)
                        let duration = frameTimeSeconds(frameIndex: step.jump)
                        hypothesis.append(
                            ParakeetAlignedToken(
                                id: token,
                                text: ParakeetTokenizer.decode(tokens: [token], vocabulary: vocabulary),
                                start: start,
                                duration: duration
                            )
                        )
                    }
                }

                t = step.nextTime
                newSymbols = step.nextNewSymbols
            }

            results.append(
                ParakeetAlignment.sentencesToResult(
                    ParakeetAlignment.tokensToSentences(hypothesis)
                )
            )
        }

        return results
    }

    private func gatherActiveFrames(
        batchFeatures: MLXArray,
        activeRows: [Int],
        timeByRow: [Int]
    ) -> MLXArray {
        let gathered = activeRows.map { row in
            let time = timeByRow[row]
            return batchFeatures[row..<(row + 1), time..<(time + 1), 0...]
        }

        if gathered.count == 1 {
            return gathered[0]
        }
        return MLX.concatenated(gathered, axis: 0)
    }

    private func gatherActiveState(_ state: ParakeetLSTMState, activeRows: [Int]) -> ParakeetLSTMState {
        func gather(_ array: MLXArray?) -> MLXArray? {
            guard let array else { return nil }
            let slices = activeRows.map { row in
                array[0..., row..<(row + 1), 0...]
            }

            if slices.count == 1 {
                return slices[0]
            }
            return MLX.concatenated(slices, axis: 1)
        }

        return (hidden: gather(state.hidden), cell: gather(state.cell))
    }

    private func mergeUpdatedState(
        _ state: ParakeetLSTMState,
        activeRows: [Int],
        updatedState: ParakeetLSTMState,
        committedRows: [Bool]
    ) -> ParakeetLSTMState {
        func merge(_ original: MLXArray?, _ updated: MLXArray?) -> MLXArray? {
            guard let original, let updated else { return original }
            guard !activeRows.isEmpty else { return original }

            var rowSlices = (0..<original.shape[1]).map { row in
                original[0..., row..<(row + 1), 0...]
            }
            let updatedSlices = updated.split(parts: activeRows.count, axis: 1)

            for (index, row) in activeRows.enumerated() where committedRows[index] {
                rowSlices[row] = updatedSlices[index]
            }

            if rowSlices.count == 1 {
                return rowSlices[0]
            }
            return MLX.concatenated(rowSlices, axis: 1)
        }

        return (
            hidden: merge(state.hidden, updatedState.hidden),
            cell: merge(state.cell, updatedState.cell)
        )
    }

    private func frameTimeSeconds(frameIndex: Int) -> Double {
        Double(frameIndex * encoderConfig.subsamplingFactor * preprocessConfig.hopLength) / Double(preprocessConfig.sampleRate)
    }

    private func normalizeAudioToMono(_ audio: MLXArray) -> MLXArray {
        audio.ndim > 1 ? audio.mean(axis: -1) : audio
    }

    private func makeMelFeatures(from audio: MLXArray) -> MLXArray {
        ParakeetAudio.logMelSpectrogram(audio, config: preprocessConfig).squeezed(axis: 0)
    }

    private func padMelFeatures(_ mel: MLXArray, targetFrameLength: Int) -> MLXArray {
        let currentFrameLength = mel.shape[0]
        guard currentFrameLength < targetFrameLength else {
            return mel
        }

        let featureCount = mel.shape[1]
        let padding = MLXArray.zeros([targetFrameLength - currentFrameLength, featureCount], type: Float.self)
            .asType(mel.dtype)
        return MLX.concatenated([mel, padding], axis: 0)
    }

    private func makeInitialDecoderState(batchSize: Int, dtype: DType) -> ParakeetLSTMState {
        guard let decoder else {
            return (hidden: nil, cell: nil)
        }

        let decRnn = decoder.prediction.decRnn
        let hiddenSize = decRnn.layers.first?.hiddenSize ?? decoder.predHidden
        let shape = [decRnn.numLayers, batchSize, hiddenSize]
        let zeros = MLXArray.zeros(shape, type: Float.self).asType(dtype)
        return (hidden: zeros, cell: zeros)
    }

    private func decodeChunk(_ chunkAudio: MLXArray) -> ParakeetAlignedResult {
        #if VELLA_QUALIFICATION
        if let qualificationMelOverride { return decode(mel: qualificationMelOverride)[0] }
        #endif
        let mel = ParakeetAudio.logMelSpectrogram(chunkAudio, config: preprocessConfig)
        return decode(mel: mel)[0]
    }

    private func flattenTokens(from result: ParakeetAlignedResult) -> [ParakeetAlignedToken] {
        result.sentences.flatMap { $0.tokens }
    }

    private func mergeTokenSequences(
        existing: [ParakeetAlignedToken],
        incoming: [ParakeetAlignedToken],
        overlapDuration: Double
    ) -> [ParakeetAlignedToken] {
        if existing.isEmpty { return incoming }
        if incoming.isEmpty { return existing }

        do {
            return try ParakeetAlignment.mergeLongestContiguous(existing, incoming, overlapDuration: overlapDuration)
        } catch {
            return ParakeetAlignment.mergeLongestCommonSubsequence(existing, incoming, overlapDuration: overlapDuration)
        }
    }
}

private func makeCompiledTDTStep(
    decoder: ParakeetPredictNetwork?,
    joint: ParakeetJointNetwork?,
    blankTokenId: Int, includeLogits: Bool = false
) -> @Sendable ([MLXArray]) -> [MLXArray] {
    guard let decoder, let joint else {
        return { arrays in
            [MLXArray([Int32(0), Int32(0)]), arrays[2], arrays[3]]
        }
    }

    let blankTokenArray = MLXArray(Int32(blankTokenId)).reshaped([1, 1])

    // Treat model weights as explicit state inputs, not captured constants in TLS tapes.
    return compile(inputs: [decoder, joint]) { arrays in
        let feature = arrays[0]
        let currentToken = arrays[1]
        let hidden = arrays[2]
        let cell = arrays[3]

        let embedded = decoder.prediction.embed(currentToken)
        let blankMask = (currentToken .== blankTokenArray).expandedDimensions(axis: 2)
        let zeroEmbedded = MLXArray.zeros(like: embedded)
        let maskedEmbedded = MLX.where(blankMask, zeroEmbedded, embedded)

        let decoderOut = decoder.prediction.decRnn(maskedEmbedded, state: (hidden: hidden, cell: cell))
        let pred = decoderOut.0.asType(feature.dtype)
        let hiddenOut = decoderOut.1.hidden!.asType(feature.dtype)
        let cellOut = decoderOut.1.cell!.asType(feature.dtype)

        let jointOut = joint(feature, pred)
        let tokenLogits = jointOut[0, 0, 0, ..<(blankTokenId + 1)]
        let durationLogits = jointOut[0, 0, 0, (blankTokenId + 1)...]
        let predToken = tokenLogits.argMax(axis: -1).asType(.int32)
        let decision = durationLogits.argMax(axis: -1).asType(.int32)
        let decisions = MLX.stacked([predToken, decision], axis: 0)
        return includeLogits ? [decisions, hiddenOut, cellOut, jointOut] : [decisions, hiddenOut, cellOut]
    }
}

public extension ParakeetModel {
    private static func normalizedConfigData(_ rawData: Data) -> Data {
        guard var text = String(data: rawData, encoding: .utf8) else {
            return rawData
        }

        // Some exported NeMo configs use non-standard JSON float tokens.
        text = text.replacingOccurrences(of: "-Infinity", with: "null")
        text = text.replacingOccurrences(of: "Infinity", with: "null")
        text = text.replacingOccurrences(of: "NaN", with: "null")
        return Data(text.utf8)
    }

    static func fromDirectory(
        _ modelDir: URL,
        computeDType: DType = .bfloat16,
        preserveCheckpointDTypes: Bool = false,
        derived: DerivedPrecision? = nil
    ) throws -> ParakeetModel {
        let configURL = modelDir.appendingPathComponent("config.json")
        let rawConfigData = try Data(contentsOf: configURL)
        let configData = normalizedConfigData(rawConfigData)
        let rawConfig = try JSONDecoder().decode(ParakeetRawConfig.self, from: configData)
        let quantConfig = try JSONDecoder().decode(ParakeetQuantizationConfig.self, from: configData)
        try ParakeetVariantResolver.requireTDT(rawConfig)
        let cfg = try ParakeetConfigParser.parseTDT(rawConfig)
        let model = ParakeetModel(
            preprocessConfig: cfg.preprocessor,
            encoderConfig: cfg.encoder,
            vocabulary: cfg.joint.vocabulary,
            durations: cfg.decoding.durations,
            maxSymbols: cfg.decoding.greedy?.maxSymbols,
            decoderConfig: cfg.decoder,
            jointConfig: cfg.joint
        )

        var weights: [String: MLXArray] = [:]
        let files = try FileManager.default.contentsOfDirectory(at: modelDir, includingPropertiesForKeys: nil)
        let safetensors = files.filter { $0.pathExtension == "safetensors" }
        for file in safetensors {
            let shard = try MLX.loadArrays(url: file)
            weights.merge(shard) { _, new in new }
        }

        var sanitized = sanitize(weights: weights)
        weights.removeAll()

        // A locally derived precision (Vella): cast and/or quantize the float source tensor by tensor, then load it
        // exactly like the published quant (same modules, group size and bits).
        var perLayerQuantization = quantConfig.perLayerQuantization
        if let derived {
            guard perLayerQuantization == nil else { throw DerivedPrecision.Invalid.manifest("the source is already quantized") }
            derived.apply(to: &sanitized, targets: derived.quantizationTargets(model))
            perLayerQuantization = derived.quantization
        }

        if let perLayerQuant = perLayerQuantization {
            try installCheckpointQuantization(model: model, weights: sanitized) { path, _ in
                if sanitized["\(path).scales"] != nil {
                    return perLayerQuant.quantization(layer: path)?.asTuple
                }
                return nil
            }
        }

        try model.update(parameters: ModuleParameters.unflattened(sanitized), verify: .all)

        model.computeDType = computeDType

        // Vella mirrors Python base_load_model, which retains checkpoint dtypes.
        if !preserveCheckpointDTypes {
        // Cast all floating-point params to computeDType after load.
        // Skips params already matching target dtype and leaves non-float (e.g. uint32
        // packed quantized) weights untouched.
        let casted = Dictionary(
            uniqueKeysWithValues: model.parameters().flattened().map { key, value -> (String, MLXArray) in
                guard value.dtype.isFloatingPoint, value.dtype != computeDType else {
                    return (key, value)
                }
                return (key, value.asType(computeDType))
            }
        )
        try model.update(parameters: ModuleParameters.unflattened(casted), verify: .noUnusedKeys)
        }

        model.train(false)
        eval(model)
        return model
    }


}

private extension ParakeetModel {
    static func sanitize(weights: [String: MLXArray]) -> [String: MLXArray] {
        var sanitized: [String: MLXArray] = [:]
        sanitized.reserveCapacity(weights.count)

        for (key, value) in weights {
            guard let remapped = remapKey(key) else { continue }
            sanitized[remapped] = value
        }

        return sanitized
    }

    static func remapKey(_ key: String) -> String? {
        var newKey = key

        // ConvASRDecoder list index -> single module path.
        newKey = newKey.replacingOccurrences(of: ".decoder_layers.0.", with: ".decoder_layers.")

        // Joint net linear is index 2 in the source list.
        newKey = newKey.replacingOccurrences(of: "joint.joint_net.2.", with: "joint.joint_net.")
        newKey = newKey.replacingOccurrences(of: ".pos_bias_u", with: ".posBiasU")
        newKey = newKey.replacingOccurrences(of: ".pos_bias_v", with: ".posBiasV")

        // DwStridingSubsampling list remap:
        // conv.0 -> conv0
        // conv.(2 + 3n) -> depthwise_layers.n
        // conv.(3 + 3n) -> pointwise_layers.n
        // conv.(4 + 3n) are ReLU placeholders (no params), skip if encountered.
        if let converted = remapPreEncodeConvListKey(newKey) {
            newKey = converted
        } else if shouldSkipPreEncodeConvListKey(newKey) {
            return nil
        }

        return newKey
    }

    static func remapPreEncodeConvListKey(_ key: String) -> String? {
        let pieces = key.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard pieces.count >= 5 else { return nil }
        guard pieces[0] == "encoder", pieces[1] == "pre_encode", pieces[2] == "conv" else { return nil }
        guard let rawIndex = Int(pieces[3]) else { return nil }

        let suffix = pieces.dropFirst(4).joined(separator: ".")

        if rawIndex == 0 {
            return "encoder.pre_encode.conv0.\(suffix)"
        }
        if rawIndex < 2 {
            return nil
        }

        let shifted = rawIndex - 2
        let block = shifted / 3
        let mod = shifted % 3

        if mod == 0 {
            return "encoder.pre_encode.depthwise_layers.\(block).\(suffix)"
        }
        if mod == 1 {
            return "encoder.pre_encode.pointwise_layers.\(block).\(suffix)"
        }

        return nil
    }

    static func shouldSkipPreEncodeConvListKey(_ key: String) -> Bool {
        let pieces = key.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard pieces.count >= 5 else { return false }
        guard pieces[0] == "encoder", pieces[1] == "pre_encode", pieces[2] == "conv" else { return false }
        guard let rawIndex = Int(pieces[3]), rawIndex >= 2 else { return false }

        let shifted = rawIndex - 2
        return shifted % 3 == 2
    }
}

private struct ParakeetQuantizationConfig: Decodable {
    let perLayerQuantization: BaseConfiguration.PerLayerQuantization?

    init(from decoder: Decoder) throws {
        // BaseConfiguration requires model_type, but Parakeet configs use 'target'
        // instead, so BaseConfiguration decoding fails. Try it first for future
        // compatibility, then fall back to reading 'quantization' directly.
        if let base = try? BaseConfiguration(from: decoder) {
            self.perLayerQuantization = base.perLayerQuantization
            return
        }

        // Parakeet config has: "quantization": { "group_size": N, "bits": N, "mode": "..." }
        struct FlatQuantization: Decodable {
            let groupSize: Int
            let bits: Int
            enum CodingKeys: String, CodingKey {
                case groupSize = "group_size"
                case bits
            }
        }
        enum Keys: String, CodingKey { case quantization }
        let container = try decoder.container(keyedBy: Keys.self)
        if let q = try? container.decode(FlatQuantization.self, forKey: .quantization) {
            self.perLayerQuantization = BaseConfiguration.PerLayerQuantization(
                quantization: BaseConfiguration.Quantization(groupSize: q.groupSize, bits: q.bits),
                perLayerQuantization: [:]
            )
        } else {
            self.perLayerQuantization = nil
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}

#if VELLA_QUALIFICATION
private final class ParakeetQualificationCapture {
    var arrays: [String: MLXArray] = [:]
    var steps: [[String: Any]] = []
}
public extension ParakeetModel {
    /// Developer-only stage capture, omitted from production builds.
    func qualificationSnapshot(audio: MLXArray, directory: URL, referenceMel: MLXArray? = nil) throws -> [String: Any] {
        let capture = ParakeetQualificationCapture()
        let nativeMel = ParakeetAudio.logMelSpectrogram(audio, config: preprocessConfig) { capture.arrays[$0] = $1 }
        let mel = referenceMel ?? nativeMel
        capture.arrays["native_mel"] = nativeMel
        qualificationMelOverride = referenceMel
        let encoded = encodeBatchFeatures(mel.asType(computeDType))
        eval(mel, encoded.0, encoded.1)
        capture.arrays["mel"] = mel
        capture.arrays["encoder"] = encoded.0
        capture.arrays["lengths"] = encoded.1
        if let posEnc = encoder.posEnc {
            capture.arrays["positional"] = posEnc.pe
            let time = encoded.0.dim(1), middle = posEnc.pe.dim(1) / 2
            capture.arrays["used_positional"] = posEnc.pe[0..., (middle-time+1)..<(middle+time), 0...].asType(encoded.0.dtype)
        }
        let logitsProbe = makeCompiledTDTStep(decoder: decoder, joint: joint, blankTokenId: blankTokenId, includeLogits: true)
        qualificationObserver = { inputs, actualDecisions in
            let index = capture.steps.count
            guard index < 2048 else { return }
            let probed = logitsProbe(inputs)
            eval(probed)
            let decision = actualDecisions.asArray(Int32.self)
            let probeDecision = probed[0].asArray(Int32.self)
            let prefix = String(format: "step_%04d", index)
            capture.arrays[prefix + "_feature"] = inputs[0]
            capture.arrays[prefix + "_token"] = inputs[1]
            capture.arrays[prefix + "_hidden"] = inputs[2]
            capture.arrays[prefix + "_cell"] = inputs[3]
            capture.arrays[prefix + "_logits"] = probed[3]
            capture.steps.append(["token": Int(decision[0]), "duration": Int(decision[1]), "probeDecisionMatches": decision == probeDecision])
        }
        defer { qualificationObserver = nil; qualificationMelOverride = nil }
        let output = generate(audio: audio, generationParameters: STTGenerateParameters(maxTokens: 1024, verbose: false, chunkDuration: 30))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try MLX.save(arrays: capture.arrays, url: directory.appendingPathComponent("stages.safetensors"))
        let result: [String: Any] = ["text": output.text, "steps": capture.steps, "referenceMelInjected": referenceMel != nil]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("trace.json"))
        return ["text": output.text, "steps": capture.steps.count, "arrays": capture.arrays.count]
    }
}
#endif
