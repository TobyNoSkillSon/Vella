import Foundation
import MLX
import MLXNN
import MLXAudioCore
import MLXLMCommon

public final class NemotronASRModel: Module {
    public var keptLevers = KeptLevers(family: "", precision: "", recipe: .standard)
    public let config: NemotronASRConfig
    public let preprocessConfig: NemotronASRPreprocessConfig
    public let encoderConfig: NemotronASRConformerConfig
    public let vocabulary: [String]
    public let promptDictionary: [String: Int]
    public let numPrompts: Int
    public let blankTokenID: Int
    public let defaultLanguage: String
    public let defaultAttContextSize: [Int]
    public let maxSymbols: Int?

    public var computeDType: DType = .bfloat16
    let positionCache = NemotronASRPositionCache()
    /// Built by `prepareFusedEncoder()` on the optimized path only (after any load-time weight conversion).
    var fusedEncoder: VellaNemotronFusedEncoder?
    /// BF16 copy of the joint output projection for `VELLA_NEMO_JOINTBATCH=1` (built by the first optimized session).
    var jointBatch: VellaNemotronSmallLinear?
    /// The joint batch's BF16 copy exists (reported as `joint_batch`; nil for a quantized joint or a lossy copy).
    public var jointBatchPrepared: Bool { jointBatch != nil }

    @ModuleInfo(key: "encoder") var encoder: NemotronASRConformer
    @ModuleInfo(key: "prompt_kernel") var promptKernel: NemotronASRPromptKernel?
    @ModuleInfo(key: "decoder") var decoder: NemoPredictNetwork
    @ModuleInfo(key: "joint") var joint: NemoJointNetwork

    public init(_ config: NemotronASRConfig) {
        self.config = config
        self.preprocessConfig = config.preprocessor
        self.encoderConfig = config.encoder
        self.vocabulary = config.vocabulary
        self.promptDictionary = config.hasPromptConditioning ? config.prompt.promptDictionary : [:]
        self.numPrompts = config.hasPromptConditioning ? config.prompt.numPrompts : 0
        self.blankTokenID = config.decoder.vocabSize
        self.defaultLanguage = config.defaultLanguage
        self.defaultAttContextSize = config.defaultAttContextSize
        self.maxSymbols = config.maxSymbols

        self._encoder.wrappedValue = NemotronASRConformer(args: config.encoder)
        self._promptKernel.wrappedValue = config.hasPromptConditioning
            ? NemotronASRPromptKernel(
                dModel: config.encoder.dModel,
                numPrompts: config.prompt.numPrompts,
                promptHidden: config.prompt.promptHidden
            )
            : nil
        self._decoder.wrappedValue = NemoPredictNetwork(
            args: NemoPredictConfig(
                blankAsPad: config.decoder.blankAsPad,
                vocabSize: config.decoder.vocabSize,
                prednet: NemoPredictNetworkConfig(
                    predHidden: config.decoder.predHidden,
                    predRnnLayers: config.decoder.predRnnLayers
                )
            )
        )
        self._joint.wrappedValue = NemoJointNetwork(
            args: NemoJointConfig(
                numClasses: config.joint.numClasses,
                vocabulary: config.vocabulary,
                jointnet: NemoJointNetworkConfig(
                    jointHidden: config.joint.jointHidden,
                    activation: config.joint.activation,
                    encoderHidden: config.joint.encoderHidden,
                    predHidden: config.joint.predHidden
                )
            )
        )
    }

    func applyPrompt(_ encoded: MLXArray, language: String? = nil) -> MLXArray {
        guard let promptKernel else { return encoded }
        let promptIndex = resolvePromptIndex(language)
        let batch = encoded.shape[0]
        let time = encoded.shape[1]
        let promptIDs = MLXArray(Array(repeating: Int32(promptIndex), count: batch * time))
            .reshaped([batch, time])
            .expandedDimensions(axis: 2)
        let promptRange = MLX.arange(numPrompts, dtype: .int32).reshaped([1, 1, numPrompts])
        let oneHot = MLX.where(promptRange .== promptIDs, MLXArray(Float(1)), MLXArray(Float(0))).asType(encoded.dtype)
        let conditioned = MLX.concatenated([encoded, oneHot], axis: 2)
        return promptKernel(conditioned)
    }

    func resolvePromptIndex(_ language: String?) -> Int {
        let resolvedLanguage = language ?? defaultLanguage
        if let index = promptDictionary[resolvedLanguage] {
            return index
        }
        if let index = promptDictionary[defaultLanguage] {
            return index
        }
        return 0
    }

}

final class NemotronASRPromptKernel: Module {
    @ModuleInfo(key: "linear0") var linear0: Linear
    @ModuleInfo(key: "linear2") var linear2: Linear

    init(dModel: Int, numPrompts: Int, promptHidden: Int) {
        self._linear0.wrappedValue = Linear(dModel + numPrompts, promptHidden)
        self._linear2.wrappedValue = Linear(promptHidden, dModel)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        linear2(relu(linear0(x)))
    }
}

public extension NemotronASRModel {
    private static func normalizedConfigData(_ rawData: Data) -> Data {
        guard var text = String(data: rawData, encoding: .utf8) else {
            return rawData
        }

        text = text.replacingOccurrences(of: "-Infinity", with: "null")
        text = text.replacingOccurrences(of: "Infinity", with: "null")
        text = text.replacingOccurrences(of: "NaN", with: "null")
        return Data(text.utf8)
    }

    static func fromDirectory(
        _ modelDir: URL,
        computeDType: DType = .bfloat16,
        derived: DerivedPrecision? = nil
    ) throws -> NemotronASRModel {
        let configURL = modelDir.appendingPathComponent("config.json")
        let rawConfigData = try Data(contentsOf: configURL)
        let configData = normalizedConfigData(rawConfigData)
        let config = try JSONDecoder().decode(NemotronASRConfig.self, from: configData)
        let quantConfig = try JSONDecoder().decode(NemotronASRQuantizationConfig.self, from: configData)

        let model = NemotronASRModel(config)
        model.keptLevers = try KeptLevers.resolve(modelDir, derived: derived)
        var weights: [String: MLXArray] = [:]
        let files = try FileManager.default.contentsOfDirectory(at: modelDir, includingPropertiesForKeys: nil)
        let safetensors = files.filter { $0.pathExtension == "safetensors" }
        for file in safetensors {
            let shard = try MLX.loadArrays(url: file)
            weights.merge(shard) { _, new in new }
        }

        var sanitized = sanitize(
            weights: weights,
            quantization: quantConfig.perLayerQuantization
        )
        weights.removeAll()

        // A locally derived precision (Vella): quantize the float source tensor by tensor, then load it exactly like
        // the published 8b (same modules, group size and bits).
        var perLayerQuantization = quantConfig.perLayerQuantization
        if let derived {
            guard perLayerQuantization == nil else { throw DerivedPrecision.Invalid.manifest("the source is already quantized") }
            derived.apply(to: &sanitized, targets: try derived.quantizationTargets(model))
            perLayerQuantization = derived.quantization
        }

        if let perLayerQuant = perLayerQuantization {
            quantize(model: model) { path, _ in
                if sanitized["\(path).scales"] != nil {
                    return perLayerQuant.quantization(layer: path)?.asTuple
                }
                return nil
            }
        }

        try model.update(parameters: ModuleParameters.unflattened(sanitized), verify: .all)
        model.computeDType = computeDType

        let casted = Dictionary(
            uniqueKeysWithValues: model.parameters().flattened().map { key, value -> (String, MLXArray) in
                guard value.dtype.isFloatingPoint, value.dtype != computeDType else {
                    return (key, value)
                }
                return (key, value.asType(computeDType))
            }
        )
        try model.update(parameters: ModuleParameters.unflattened(casted), verify: .noUnusedKeys)

        model.train(false)
        eval(model)
        return model
    }


}

extension NemotronASRModel {
    static func sanitize(
        weights: [String: MLXArray],
        quantization: BaseConfiguration.PerLayerQuantization?
    ) -> [String: MLXArray] {
        var sanitized: [String: MLXArray] = [:]
        sanitized.reserveCapacity(weights.count)

        for (key, value) in weights {
            guard let remapped = remapKey(key) else { continue }
            sanitized[remapped] = value
        }

        let pointwiseWeights = sanitized.keys.filter { key in
            guard key.hasSuffix(".weight"),
                  key.contains(".conv.pointwise_conv"),
                  let weight = sanitized[key]
            else {
                return false
            }
            return weight.dtype == .uint32 && weight.ndim == 2
        }

        for weightKey in pointwiseWeights {
            let prefix = String(weightKey.dropLast(".weight".count))
            let scalesKey = "\(prefix).scales"
            let biasesKey = "\(prefix).biases"
            guard let weight = sanitized[weightKey],
                  let scales = sanitized[scalesKey],
                  let parameters = quantization?.quantization(layer: prefix)
            else {
                continue
            }

            sanitized[weightKey] = MLX.dequantized(
                weight,
                scales: scales,
                biases: sanitized[biasesKey],
                groupSize: parameters.groupSize,
                bits: parameters.bits,
                mode: parameters.mode,
                dtype: scales.dtype
            ).expandedDimensions(axis: 1)
            sanitized.removeValue(forKey: scalesKey)
            sanitized.removeValue(forKey: biasesKey)
        }

        return sanitized
    }

    private static func remapKey(_ key: String) -> String? {
        var newKey = key
        newKey = newKey.replacingOccurrences(of: "joint.joint_net.2.", with: "joint.joint_net.")
        newKey = newKey.replacingOccurrences(of: ".pos_bias_u", with: ".posBiasU")
        newKey = newKey.replacingOccurrences(of: ".pos_bias_v", with: ".posBiasV")
        // prompt_kernel.{0,2} are integer-keyed; MLX-swift would treat them as an
        // array (gap at index 1) and fail to load. Remap to explicit child keys.
        newKey = newKey.replacingOccurrences(of: "prompt_kernel.0.", with: "prompt_kernel.linear0.")
        newKey = newKey.replacingOccurrences(of: "prompt_kernel.2.", with: "prompt_kernel.linear2.")

        if let converted = remapPreEncodeConvListKey(newKey) {
            newKey = converted
        } else if shouldSkipPreEncodeConvListKey(newKey) {
            return nil
        }

        return newKey
    }

    private static func remapPreEncodeConvListKey(_ key: String) -> String? {
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

    private static func shouldSkipPreEncodeConvListKey(_ key: String) -> Bool {
        let pieces = key.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard pieces.count >= 5 else { return false }
        guard pieces[0] == "encoder", pieces[1] == "pre_encode", pieces[2] == "conv" else { return false }
        guard let rawIndex = Int(pieces[3]), rawIndex >= 2 else { return false }

        let shifted = rawIndex - 2
        return shifted % 3 == 2
    }
}

private struct NemotronASRQuantizationConfig: Decodable {
    let perLayerQuantization: BaseConfiguration.PerLayerQuantization?

    init(from decoder: Decoder) throws {
        if let base = try? BaseConfiguration(from: decoder) {
            self.perLayerQuantization = base.perLayerQuantization
            return
        }

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
