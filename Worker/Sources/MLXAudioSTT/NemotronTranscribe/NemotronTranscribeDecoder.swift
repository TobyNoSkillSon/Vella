// SPDX-License-Identifier: MIT
// Nemotron-H decoder of Nemotron 3.5 Transcribe. Ported from mlx-audio @92decb7 (MIT):
// mlx_audio/lm/models/nemotron_h.py and ssm.py (vendored from mlx-lm 0.31.3, Copyright © 2025 Apple Inc.) and the
// speech checkpoint's precision contract in mlx_audio/stt/models/nemotron_transcribe/language_model.py: the SSM scan,
// its skip connection and the gated norm run in Float32 (NeMo keeps A_log, D, dt_bias and the state in FP32).
import Foundation
import MLX
import MLXFast
import MLXNN

struct NTDecoderConfig: Sendable {
    var vocabSize: Int
    var hiddenSize: Int
    var numAttentionHeads: Int
    var numKeyValueHeads: Int
    var headDim: Int
    var mambaNumHeads: Int
    var mambaHeadDim: Int
    var ssmStateSize: Int
    var convKernel: Int
    var nGroups: Int
    var layerNormEpsilon: Float
    var moeIntermediateSize: Int
    var moeSharedExpertIntermediateSize: Int
    var nRoutedExperts: Int
    var numExpertsPerTok: Int
    var normTopkProb: Bool
    var routedScalingFactor: Float
    var timeStepLimit: (Float, Float)
    var useConvBias: Bool
    /// One character per layer: M (Mamba), * (attention), E (mixture of experts).
    var pattern: [Character]

    var mambaIntermediate: Int { mambaNumHeads * mambaHeadDim }
    var convDim: Int { mambaIntermediate + 2 * nGroups * ssmStateSize }

    /// From `llm_config` in the checkpoint's config.json.
    init(json: [String: Any]) throws {
        func int(_ key: String) throws -> Int {
            guard let value = json[key] as? Int else { throw NemotronTranscribeError.config(key) }
            return value
        }
        func float(_ key: String) throws -> Float {
            guard let value = (json[key] as? NSNumber)?.floatValue else { throw NemotronTranscribeError.config(key) }
            return value
        }
        guard json["model_type"] as? String == "nemotron_h" else { throw NemotronTranscribeError.config("llm_config.model_type") }
        vocabSize = try int("vocab_size"); hiddenSize = try int("hidden_size")
        numAttentionHeads = try int("num_attention_heads"); numKeyValueHeads = try int("num_key_value_heads")
        headDim = (json["head_dim"] as? Int) ?? hiddenSize / numAttentionHeads
        mambaNumHeads = try int("mamba_num_heads"); mambaHeadDim = try int("mamba_head_dim")
        ssmStateSize = try int("ssm_state_size"); convKernel = try int("conv_kernel"); nGroups = try int("n_groups")
        layerNormEpsilon = try float("layer_norm_epsilon")
        moeIntermediateSize = try int("moe_intermediate_size")
        moeSharedExpertIntermediateSize = try int("moe_shared_expert_intermediate_size")
        nRoutedExperts = try int("n_routed_experts"); numExpertsPerTok = try int("num_experts_per_tok")
        normTopkProb = (json["norm_topk_prob"] as? Bool) ?? false
        routedScalingFactor = try float("routed_scaling_factor")
        useConvBias = (json["use_conv_bias"] as? Bool) ?? true
        // NeMo serializes infinity as {"__float__": "Infinity"}.
        var limit: (Float, Float) = (0, .infinity)
        if let values = json["time_step_limit"] as? [Any], values.count == 2 {
            func value(_ v: Any) -> Float {
                if let n = v as? NSNumber { return n.floatValue }
                if let d = v as? [String: Any], let s = d["__float__"] as? String { return Float(s) ?? .infinity }
                return .infinity
            }
            limit = (value(values[0]), value(values[1]))
        }
        timeStepLimit = limit
        guard (json["n_group"] as? Int ?? 1) == 1, json["moe_latent_size"] == nil || json["moe_latent_size"] is NSNull,
              (json["attention_bias"] as? Bool) != true, (json["mamba_proj_bias"] as? Bool) != true,
              (json["mlp_bias"] as? Bool) != true
        else { throw NemotronTranscribeError.config("unsupported Nemotron-H variant") }
        guard let types = json["layers_block_type"] as? [String] else { throw NemotronTranscribeError.config("layers_block_type") }
        pattern = try types.map {
            switch $0 {
            case "mamba", "linear_attention": return "M"
            case "attention", "full_attention": return "*"
            case "moe": return "E"
            default: throw NemotronTranscribeError.config("block type \($0)")
            }
        }
    }
}

// MARK: - Caches

/// A Mamba layer's convolution tail and Float32 SSM state.
final class NTMambaCache {
    var conv: MLXArray?
    var state: MLXArray?
}

/// Concatenating key/value cache (the same values as mlx-lm's step-allocated KVCache).
final class NTKVCache {
    var keys: MLXArray?
    var values: MLXArray?
    var offset: Int { keys?.dim(2) ?? 0 }

    func update(_ k: MLXArray, _ v: MLXArray) -> (MLXArray, MLXArray) {
        if let keys, let values {
            self.keys = concatenated([keys, k], axis: 2)
            self.values = concatenated([values, v], axis: 2)
        } else {
            keys = k; values = v
        }
        return (keys!, values!)
    }

    func trim(_ n: Int) {
        guard let keys, let values, n > 0 else { return }
        let keep = max(0, keys.dim(2) - n)
        self.keys = keys[0..., 0..., ..<keep, 0...]
        self.values = values[0..., 0..., ..<keep, 0...]
    }
}

enum NTLayerCache {
    case mamba(NTMambaCache)
    case attention(NTKVCache)
}

// MARK: - SSM (ssm.py)

private let ntSSMStepSource = """
        auto n = thread_position_in_grid.z;
        auto h_idx = n % H;
        auto g_idx = n / G;
        constexpr int n_per_t = Ds / 32;
        auto x = X + n * Dh;
        out += n * Dh;
        auto i_state = state_in + n * Dh * Ds;
        auto o_state = state_out + n * Dh * Ds;
        auto C_ = C + g_idx * Ds;
        auto B_ = B + g_idx * Ds;
        auto ds_idx = thread_position_in_threadgroup.x;
        auto d_idx = thread_position_in_grid.y;
        auto dt_ = static_cast<float>(dt[n]);
        auto A = -fast::exp(static_cast<float>(A_log[h_idx]));
        auto dA = fast::exp(A * dt_);
        float acc = 0.0;
        auto x_ = static_cast<float>(x[d_idx]);
        for (int i = 0; i < n_per_t; ++i) {
            auto s_idx = n_per_t * ds_idx + i;
            auto idx = d_idx * Ds + s_idx;
            auto dB_by_x = x_ * dt_ * static_cast<float>(B_[s_idx]);
            auto state = dA * i_state[idx] + dB_by_x;
            o_state[idx] = static_cast<U>(state);
            acc += state * C_[s_idx];
        }
        acc = simd_sum(acc);
        if (thread_index_in_simdgroup == 0) {
            out[d_idx] = static_cast<T>(acc + x_ * D[h_idx]);
        }
    """

private let ntSSMInitialSource = """
        auto length = static_cast<int>(sequence_length[0]);
        auto n = thread_position_in_grid.z;
        auto batch = n / H;
        auto head = n % H;
        auto group = head / HpG;
        auto d = thread_position_in_grid.y;
        auto lane = thread_position_in_threadgroup.x;
        constexpr int n_per_t = Ds / 32;
        auto output_state = state_out + n * Dh * Ds;
        float local_state[n_per_t];
        for (int i = 0; i < n_per_t; ++i) {
            local_state[i] = 0.0f;
        }
        for (int t = 0; t < length; ++t) {
            auto token_head = (batch * length + t) * H + head;
            auto token_group = (batch * length + t) * Ng + group;
            auto x_ = static_cast<float>(X[token_head * Dh + d]);
            auto dt_ = static_cast<float>(dt[token_head]);
            auto dA = static_cast<float>(decay[token_head]);
            auto input_scale = x_ * dt_;
            auto B_ = B + token_group * Ds;
            auto C_ = C + token_group * Ds;
            float acc = 0.0f;
            for (int i = 0; i < n_per_t; ++i) {
                auto s = n_per_t * lane + i;
                auto next = dA * local_state[i]
                    + input_scale * static_cast<float>(B_[s]);
                local_state[i] = next;
                acc += next * C_[s];
            }
            acc = simd_sum(acc);
            if (thread_index_in_simdgroup == 0) {
                out[token_head * Dh + d] = static_cast<T>(
                    acc + x_ * D[head]);
            }
        }
        for (int i = 0; i < n_per_t; ++i) {
            auto s = n_per_t * lane + i;
            output_state[d * Ds + s] = static_cast<U>(local_state[i]);
        }
    """

private final class NTSSMKernels: @unchecked Sendable {
    static let shared = NTSSMKernels()
    let step = MLXFast.metalKernel(
        name: "nt_ssm_kernel", inputNames: ["X", "A_log", "B", "C", "D", "dt", "state_in"],
        outputNames: ["out", "state_out"], source: ntSSMStepSource)
    let initial = MLXFast.metalKernel(
        name: "nt_ssm_initial_kernel", inputNames: ["X", "decay", "B", "C", "D", "dt", "sequence_length"],
        outputNames: ["out", "state_out"], source: ntSSMInitialSource)
}

private func ntComputeDt(_ dt: MLXArray, _ dtBias: MLXArray, _ limit: (Float, Float)) -> MLXArray {
    clip(softplus(dt.asType(.float32) + dtBias), min: limit.0, max: limit.1)
}

private func ntSegsum(_ x: MLXArray) -> MLXArray {
    let l = x.dim(-1)
    var y = repeated(expandedDimensions(x, axis: -1), count: l, axis: -1)
    y = tril(y, k: -1)
    return cumsum(y, axis: -2)
}

/// SSD forward over a chunk with an existing state (`ssm_attn`, 256-step blocks).
private func ntSSMAttn(
    _ x: MLXArray, aLog: MLXArray, B: MLXArray, C: MLXArray, D: MLXArray, dt: MLXArray, dtBias: MLXArray,
    state initial: MLXArray?, limit: (Float, Float), step: Int = 256
) -> (MLXArray, MLXArray) {
    let (b, l, h, dh) = (x.dim(0), x.dim(1), x.dim(2), x.dim(3))
    let (g, d) = (B.dim(2), B.dim(3))
    let dtc = ntComputeDt(dt, dtBias, limit)
    let repeats = h / g
    let A = -exp(aLog).asType(dtc.dtype)
    let dtA = dtc * A.reshaped(1, 1, -1)
    let dtx = dtc.reshaped(b, l, h, 1) * x
    var state = initial
    var ys: [MLXArray] = []
    var i = 0
    while i < l {
        let e = min(l, i + step)
        let sDtx = dtx[0..., i ..< e], sDtA = dtA[0..., i ..< e]
        var sB = B[0..., i ..< e], sC = C[0..., i ..< e]
        let s = sDtx.dim(1)
        sB = sB.transposed(0, 2, 3, 1)
        var CB = matmul(sC.swappedAxes(1, 2), sB)
        CB = repeated(CB, count: repeats, axis: 1)
        var decay = exp(ntSegsum(sDtA.swappedAxes(1, 2)))
        let surrogate = tril(CB * decay, k: 0)
        var y = matmul(surrogate, sDtx.swappedAxes(1, 2)).swappedAxes(1, 2)
        decay = decay[0..., 0..., (-1)..., 0...].transposed(0, 3, 1, 2)
        let Bh = repeated(sB, count: h / g, axis: 1).swappedAxes(2, 3)
        let dtxdecay = (sDtx * decay).swappedAxes(1, 2).swappedAxes(2, 3)
        var next = matmul(dtxdecay, Bh)
        if let previous = state {
            let expCum = exp(cumsum(sDtA, axis: -2))
            next = next + expandedDimensions(expCum[0..., -1, 0...], axes: [-1, -2]) * previous
            let C6 = sC.reshaped(b, s, g, 1, d, 1)
            let yPrev = matmul(previous.reshaped(b, 1, g, repeats, dh, d), C6).squeezed(axis: -1).flattened(start: 2, end: 3)
            y = y + expandedDimensions(expCum, axis: -1) * yPrev
        }
        state = next
        ys.append(y.asType(x.dtype))
        i = e
    }
    let y = concatenated(ys, axis: 1) + x * D.reshaped(1, 1, h, 1)
    return (y, state!)
}

/// `ssm_update`: the whole-chunk kernel without a state, the step kernel for one token, SSD otherwise.
func ntSSMUpdate(
    _ x: MLXArray, aLog: MLXArray, B: MLXArray, C: MLXArray, D: MLXArray, dt: MLXArray, dtBias: MLXArray,
    state: MLXArray?, limit: (Float, Float)
) -> (MLXArray, MLXArray) {
    let (n, l, h, d) = (x.dim(0), x.dim(1), x.dim(2), x.dim(3))
    let (groups, ds) = (B.dim(-2), B.dim(-1))
    // The custom kernels need Metal; on the CPU (lab VELLA_MLX_DEVICE=cpu) everything runs as SSD, like mlx-audio.
    let metal = Device.defaultDevice().deviceType == .gpu
    if metal, state == nil, ds % 32 == 0 {
        let dtc = ntComputeDt(dt, dtBias, limit)
        let decay = exp(-exp(aLog) * dtc)
        let out = NTSSMKernels.shared.initial(
            [x, decay, B, C, D, dtc, MLXArray([UInt32(l)])],
            template: [("T", x.dtype), ("U", DType.float32), ("Dh", d), ("Ds", ds), ("H", h), ("Ng", groups), ("HpG", h / groups)],
            grid: (32, d, h * n), threadGroup: (32, 8, 1),
            outputShapes: [x.shape, [n, h, d, ds]], outputDTypes: [x.dtype, DType.float32])
        return (out[0], out[1])
    }
    if l > 1 || state == nil || !metal {
        return ntSSMAttn(x, aLog: aLog, B: B, C: C, D: D, dt: dt, dtBias: dtBias, state: state, limit: limit)
    }
    let s = state!
    let dtc = ntComputeDt(dt, dtBias, limit)
    let out = NTSSMKernels.shared.step(
        [x, aLog, B, C, D, dtc, s],
        template: [("T", x.dtype), ("U", s.dtype), ("Dh", d), ("Ds", ds), ("H", h), ("G", h / groups)],
        grid: (32, d, h * n), threadGroup: (32, 8, 1),
        outputShapes: [[n, 1, h, d], s.shape], outputDTypes: [x.dtype, s.dtype])
    return (out[0], out[1])
}

// MARK: - Layers

/// NeMo's gate-before-normalization kernel, in Float32.
final class NTGatedRMSNorm: Module {
    var weight: MLXArray
    let groupSize: Int
    let eps: Float
    init(width: Int, groupSize: Int, eps: Float) {
        weight = MLXArray.ones([width]); self.groupSize = groupSize; self.eps = eps
        super.init()
    }
    func callAsFunction(_ x: MLXArray, gate: MLXArray) -> MLXArray {
        let dtype = x.dtype
        var y = x.asType(.float32) * silu(gate.asType(.float32))
        let shape = y.shape
        y = y.reshaped(Array(shape.dropLast()) + [-1, groupSize])
        y = MLXFast.rmsNorm(y, weight: MLXArray.ones([groupSize], dtype: .float32), eps: eps).reshaped(shape)
        return (y * weight).asType(dtype)
    }
}

final class NTMamba: Module {
    let config: NTDecoderConfig
    @ModuleInfo(key: "in_proj") var inProj: Linear
    @ModuleInfo(key: "out_proj") var outProj: Linear
    @ModuleInfo(key: "conv1d") var conv1d: Conv1d
    @ModuleInfo(key: "norm") var norm: NTGatedRMSNorm
    @ParameterInfo(key: "dt_bias") var dtBias: MLXArray
    @ParameterInfo(key: "A_log") var aLog: MLXArray
    @ParameterInfo(key: "D") var D: MLXArray

    init(_ c: NTDecoderConfig) {
        config = c
        _inProj.wrappedValue = Linear(c.hiddenSize, c.mambaIntermediate + c.convDim + c.mambaNumHeads, bias: false)
        _outProj.wrappedValue = Linear(c.mambaIntermediate, c.hiddenSize, bias: false)
        _conv1d.wrappedValue = Conv1d(inputChannels: c.convDim, outputChannels: c.convDim, kernelSize: c.convKernel,
                                      groups: c.convDim, bias: c.useConvBias)
        _norm.wrappedValue = NTGatedRMSNorm(width: c.mambaIntermediate, groupSize: c.mambaIntermediate / c.nGroups, eps: c.layerNormEpsilon)
        _dtBias.wrappedValue = MLXArray.ones([c.mambaNumHeads])
        _aLog.wrappedValue = MLXArray.ones([c.mambaNumHeads])
        _D.wrappedValue = MLXArray.ones([c.mambaNumHeads])
        super.init()
    }

    func callAsFunction(_ x: MLXArray, cache: NTMambaCache) -> MLXArray {
        let c = config
        let (b, t) = (x.dim(0), x.dim(1))
        let parts = split(inProj(x), indices: [c.mambaIntermediate, c.mambaIntermediate + c.convDim], axis: -1)
        let (gate, convInput, dt) = (parts[0], parts[1], parts[2])
        let convState = cache.conv ?? MLXArray.zeros([b, c.convKernel - 1, c.convDim], dtype: convInput.dtype)
        let padded = concatenated([convState, convInput], axis: 1)
        cache.conv = padded[0..., (padded.dim(1) - (c.convKernel - 1))..., 0...]
        let conv = silu(conv1d(padded))
        let s = split(conv, indices: [c.mambaIntermediate, c.mambaIntermediate + c.nGroups * c.ssmStateSize], axis: -1)
        let (y, state) = ntSSMUpdate(
            s[0].reshaped(b, t, c.mambaNumHeads, c.mambaHeadDim).asType(.float32), aLog: aLog,
            B: s[1].reshaped(b, t, c.nGroups, c.ssmStateSize).asType(.float32),
            C: s[2].reshaped(b, t, c.nGroups, c.ssmStateSize).asType(.float32),
            D: D, dt: dt, dtBias: dtBias, state: cache.state, limit: c.timeStepLimit)
        cache.state = state
        let flat = y.reshaped(b, t, c.mambaIntermediate).asType(x.dtype)
        return outProj(norm(flat, gate: gate))
    }
}

final class NTAttention: Module {
    let heads: Int, kvHeads: Int, headDim: Int, scale: Float
    @ModuleInfo(key: "q_proj") var q: Linear
    @ModuleInfo(key: "k_proj") var k: Linear
    @ModuleInfo(key: "v_proj") var v: Linear
    @ModuleInfo(key: "o_proj") var o: Linear

    init(_ c: NTDecoderConfig) {
        heads = c.numAttentionHeads; kvHeads = c.numKeyValueHeads; headDim = c.headDim
        scale = pow(Float(c.headDim), -0.5)
        _q.wrappedValue = Linear(c.hiddenSize, heads * headDim, bias: false)
        _k.wrappedValue = Linear(c.hiddenSize, kvHeads * headDim, bias: false)
        _v.wrappedValue = Linear(c.hiddenSize, kvHeads * headDim, bias: false)
        _o.wrappedValue = Linear(heads * headDim, c.hiddenSize, bias: false)
        super.init()
    }

    /// No positional encoding (Nemotron-H attention). Causal for more than one query, as mlx-lm's cache mask.
    func callAsFunction(_ x: MLXArray, cache: NTKVCache) -> MLXArray {
        let (b, l) = (x.dim(0), x.dim(1))
        let queries = q(x).reshaped(b, l, heads, -1).transposed(0, 2, 1, 3)
        let (keys, values) = cache.update(
            k(x).reshaped(b, l, kvHeads, -1).transposed(0, 2, 1, 3), v(x).reshaped(b, l, kvHeads, -1).transposed(0, 2, 1, 3))
        let out = MLXFast.scaledDotProductAttention(
            queries: queries, keys: keys, values: values, scale: scale, mask: l > 1 ? .causal : .none)
        return o(out.transposed(0, 2, 1, 3).reshaped(b, l, -1))
    }
}

final class NTMLP: Module {
    @ModuleInfo(key: "up_proj") var up: Linear
    @ModuleInfo(key: "down_proj") var down: Linear
    init(hidden: Int, intermediate: Int) {
        _up.wrappedValue = Linear(hidden, intermediate, bias: false)
        _down.wrappedValue = Linear(intermediate, hidden, bias: false)
        super.init()
    }
    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let y = maximum(up(x), 0)
        return down(y * y)
    }
}

/// Stacked experts, [experts, out, in]; replaced by `NTQuantizedSwitchLinear` from a quantized checkpoint.
class NTSwitchLinear: Module {
    var weight: MLXArray
    init(weight: MLXArray) { self.weight = weight; super.init() }
    init(experts: Int, input: Int, output: Int) {
        // Never evaluated: the checkpoint replaces it before the first eval.
        weight = MLXArray.zeros([experts, output, input], dtype: .bfloat16)
        super.init()
    }
    func callAsFunction(_ x: MLXArray, _ indices: MLXArray, sorted: Bool) -> MLXArray {
        gatherMM(x, weight.swappedAxes(-1, -2), rhsIndices: indices, sortedIndices: sorted)
    }
}

final class NTQuantizedSwitchLinear: NTSwitchLinear {
    var scales: MLXArray
    var biases: MLXArray?
    let groupSize: Int, bits: Int
    init(weight: MLXArray, scales: MLXArray, biases: MLXArray?, groupSize: Int, bits: Int) {
        self.scales = scales; self.biases = biases; self.groupSize = groupSize; self.bits = bits
        super.init(weight: weight)
        freeze()
    }
    override func callAsFunction(_ x: MLXArray, _ indices: MLXArray, sorted: Bool) -> MLXArray {
        gatherQuantizedMM(x, weight, scales: scales, biases: biases, rhsIndices: indices, transpose: true,
                          groupSize: groupSize, bits: bits, sortedIndices: sorted)
    }
}

final class NTSwitchMLP: Module {
    @ModuleInfo(key: "fc1") var fc1: NTSwitchLinear
    @ModuleInfo(key: "fc2") var fc2: NTSwitchLinear
    init(hidden: Int, intermediate: Int, experts: Int) {
        _fc1.wrappedValue = NTSwitchLinear(experts: experts, input: hidden, output: intermediate)
        _fc2.wrappedValue = NTSwitchLinear(experts: experts, input: intermediate, output: hidden)
        super.init()
    }
    func callAsFunction(_ x: MLXArray, _ indices: MLXArray) -> MLXArray {
        var x = expandedDimensions(x, axes: [-2, -3])
        let sort = indices.size >= 64
        var idx = indices
        var inverse: MLXArray?
        if sort {
            let m = indices.dim(-1)
            let flat = indices.flattened()
            let order = argSort(flat)
            inverse = argSort(order)
            x = x.flattened(start: 0, end: -3)[order.floorDivide(m)]
            idx = flat[order]
        }
        var y = fc1(x, idx, sorted: sort)
        y = maximum(y, 0)
        y = fc2(y * y, idx, sorted: sort)
        if let inverse {
            y = unflatten(y[inverse], axis: 0, shape: indices.shape)
        }
        return y.squeezed(axis: -2)
    }
}

final class NTRouter: Module {
    var weight: MLXArray
    @ParameterInfo(key: "e_score_correction_bias") var bias: MLXArray
    init(experts: Int, hidden: Int) {
        weight = MLXArray.zeros([experts, hidden], dtype: .float32)
        _bias.wrappedValue = MLXArray.zeros([experts], dtype: .float32)
        super.init()
    }
}

final class NTMoE: Module {
    let topK: Int, normTopk: Bool, scaling: Float
    @ModuleInfo(key: "gate") var gate: NTRouter
    @ModuleInfo(key: "switch_mlp") var switchMLP: NTSwitchMLP
    @ModuleInfo(key: "shared_experts") var shared: NTMLP

    init(_ c: NTDecoderConfig) {
        topK = c.numExpertsPerTok; normTopk = c.normTopkProb; scaling = c.routedScalingFactor
        _gate.wrappedValue = NTRouter(experts: c.nRoutedExperts, hidden: c.hiddenSize)
        _switchMLP.wrappedValue = NTSwitchMLP(hidden: c.hiddenSize, intermediate: c.moeIntermediateSize, experts: c.nRoutedExperts)
        _shared.wrappedValue = NTMLP(hidden: c.hiddenSize, intermediate: c.moeSharedExpertIntermediateSize)
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        // The FP32 router promotes the logits (Automodel routes in FP32).
        let original = sigmoid(matmul(x, gate.weight.T).asType(.float32))
        let biased = original + gate.bias
        let inds = argPartition(-biased, kth: topK - 1, axis: -1)[.ellipsis, ..<topK]
        var scores = takeAlong(original, inds, axis: -1)
        if topK > 1 && normTopk { scores = scores / (scores.sum(axis: -1, keepDims: true) + 1e-20) }
        scores = scores * scaling
        let y = switchMLP(x, inds)
        let mixed = (y * expandedDimensions(scores, axis: -1)).sum(axis: -2).asType(y.dtype)
        return mixed + shared(x)
    }
}

final class NTBlock: Module {
    let kind: Character
    @ModuleInfo(key: "norm") var norm: RMSNorm
    @ModuleInfo(key: "mixer") var mixer: Module

    init(_ c: NTDecoderConfig, kind: Character) {
        self.kind = kind
        _norm.wrappedValue = RMSNorm(dimensions: c.hiddenSize, eps: c.layerNormEpsilon)
        switch kind {
        case "M": _mixer.wrappedValue = NTMamba(c)
        case "*": _mixer.wrappedValue = NTAttention(c)
        default: _mixer.wrappedValue = NTMoE(c)
        }
        super.init()
    }

    func callAsFunction(_ x: MLXArray, cache: NTLayerCache?) -> MLXArray {
        let h = norm(x)
        let out: MLXArray
        switch (mixer, cache) {
        case (let m as NTMamba, .mamba(let c)?): out = m(h, cache: c)
        case (let a as NTAttention, .attention(let c)?): out = a(h, cache: c)
        case (let e as NTMoE, _): out = e(h)
        default: fatalError("Nemotron-H block without its cache")
        }
        return x + out
    }
}

final class NTBackbone: Module {
    @ModuleInfo(key: "embeddings") var embeddings: Embedding
    @ModuleInfo(key: "layers") var layers: [NTBlock]
    @ModuleInfo(key: "norm_f") var normF: RMSNorm

    init(_ c: NTDecoderConfig) {
        _embeddings.wrappedValue = Embedding(embeddingCount: c.vocabSize, dimensions: c.hiddenSize)
        _layers.wrappedValue = c.pattern.map { NTBlock(c, kind: $0) }
        _normF.wrappedValue = RMSNorm(dimensions: c.hiddenSize, eps: c.layerNormEpsilon)
        super.init()
    }

    func makeCache() -> [NTLayerCache?] {
        layers.map {
            switch $0.kind {
            case "M": .mamba(NTMambaCache())
            case "*": .attention(NTKVCache())
            default: nil
            }
        }
    }

    /// Hidden states after the final norm.
    func callAsFunction(_ embedded: MLXArray, cache: [NTLayerCache?]) -> MLXArray {
        var h = embedded
        for (layer, c) in zip(layers, cache) { h = layer(h, cache: c) }
        return normF(h)
    }
}

final class NTLanguageModel: Module {
    @ModuleInfo(key: "backbone") var backbone: NTBackbone
    @ModuleInfo(key: "lm_head") var lmHead: Linear
    init(_ c: NTDecoderConfig) {
        _backbone.wrappedValue = NTBackbone(c)
        _lmHead.wrappedValue = Linear(c.hiddenSize, c.vocabSize, bias: false)
        super.init()
    }
}

// MARK: - Multi-token prediction head (research mtp.py)

/// The checkpoint's repeated MTP block (attention + MoE), trained to predict the token after next:
/// concat(enorm(e), hnorm(h)) with h after the backbone's final norm.
final class NTMTP: Module {
    @ModuleInfo(key: "eh_proj") var ehProj: Linear
    @ModuleInfo(key: "enorm") var enorm: RMSNorm
    @ModuleInfo(key: "hnorm") var hnorm: RMSNorm
    @ModuleInfo(key: "attn_norm") var attnNorm: RMSNorm
    @ModuleInfo(key: "attn") var attn: NTAttention
    @ModuleInfo(key: "moe_norm") var moeNorm: RMSNorm
    @ModuleInfo(key: "moe") var moe: NTMoE
    @ModuleInfo(key: "final_norm") var finalNorm: RMSNorm

    init(_ c: NTDecoderConfig) {
        let (d, eps) = (c.hiddenSize, c.layerNormEpsilon)
        _ehProj.wrappedValue = Linear(2 * d, d, bias: false)
        _enorm.wrappedValue = RMSNorm(dimensions: d, eps: eps)
        _hnorm.wrappedValue = RMSNorm(dimensions: d, eps: eps)
        _attnNorm.wrappedValue = RMSNorm(dimensions: d, eps: eps)
        _attn.wrappedValue = NTAttention(c)
        _moeNorm.wrappedValue = RMSNorm(dimensions: d, eps: eps)
        _moe.wrappedValue = NTMoE(c)
        _finalNorm.wrappedValue = RMSNorm(dimensions: d, eps: eps)
        super.init()
    }

    func callAsFunction(_ e: MLXArray, _ h: MLXArray, cache: NTKVCache) -> (MLXArray, MLXArray) {
        var x = ehProj(concatenated([enorm(e), hnorm(h)], axis: -1))
        x = x + attn(attnNorm(x), cache: cache)
        x = x + moe(moeNorm(x))
        return (x, finalNorm(x))
    }

    /// NVIDIA checkpoint keys → this module's keys.
    static let nvidiaKeys: [String: String] = [
        "llm.mtp.layers.0.eh_proj.weight": "eh_proj.weight",
        "llm.mtp.layers.0.enorm.weight": "enorm.weight",
        "llm.mtp.layers.0.hnorm.weight": "hnorm.weight",
        "llm.mtp.layers.0.norm.weight": "attn_norm.weight",
        "llm.mtp.layers.0.mixer.q_proj.weight": "attn.q_proj.weight",
        "llm.mtp.layers.0.mixer.k_proj.weight": "attn.k_proj.weight",
        "llm.mtp.layers.0.mixer.v_proj.weight": "attn.v_proj.weight",
        "llm.mtp.layers.0.mixer.o_proj.weight": "attn.o_proj.weight",
        "llm.mtp.layers.1.norm.weight": "moe_norm.weight",
        "llm.mtp.layers.1.mixer.gate.weight": "moe.gate.weight",
        "llm.mtp.layers.1.mixer.gate.e_score_correction_bias": "moe.gate.e_score_correction_bias",
        "llm.mtp.layers.1.mixer.shared_experts.up_proj.weight": "moe.shared_experts.up_proj.weight",
        "llm.mtp.layers.1.mixer.shared_experts.down_proj.weight": "moe.shared_experts.down_proj.weight",
        "llm.mtp.layers.1.mixer.experts.gate_and_up_projs": "moe.switch_mlp.fc1.weight",
        "llm.mtp.layers.1.mixer.experts.down_projs": "moe.switch_mlp.fc2.weight",
        "llm.mtp.layers.1.final_layernorm.weight": "final_norm.weight"
    ]
}
