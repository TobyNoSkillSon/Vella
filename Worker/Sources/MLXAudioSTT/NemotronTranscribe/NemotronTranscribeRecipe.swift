// SPDX-License-Identifier: MIT
// The int8 and int4 precisions of Nemotron 3.5 Transcribe, made at load from NVIDIA's BF16 checkpoint (Vella's
// derived-at-load precisions, `DerivedPrecision`). Ported from the research recipes (Assistant/Research/
// 2026-10-28-nemotron-transcribe/code: recipes.py `mixed`, the int8 export, mtp.py `quantize_mtp`).
import Foundation
import MLX
import MLXNN

/// Not a parameter: a checkpoint's quantization entries (wrapped so module reflection skips them).
struct NTQuantizationEntries { let value: [String: Any]? }

/// Which layers are quantized and at how many bits. Affine, group 64, from the BF16 weights (MLX `quantize`, the same
/// rounding as the published MLX quants); nothing calibrated.
///
/// - int4: the routed experts (`switch_mlp.fc1`/`fc2`, 87 % of the parameters) at 4 bits; every other decoder
///   projection a token always passes through (shared experts, Mamba `in_proj`/`out_proj`, attention q/k/v/o) at 8.
/// - int8: all of those decoder projections at 8 bits.
/// - Both keep as shipped: embeddings, output head, norms, the MoE router (FP32), Mamba A_log/D/dt_bias (FP32),
///   `conv1d`, and the speech and speaker encoders and their projection.
/// - The MTP draft head: routed experts 4-bit, its other projections 8-bit, in both precisions.
public enum NemotronTranscribeRecipe {
    /// Bits for a decoder module path (nil = kept as shipped).
    public static func decoderBits(_ path: String, precisionBits: Int) -> Int? {
        guard path.hasPrefix("llm.backbone.layers.") else { return nil }
        return path.contains(".switch_mlp.") ? (precisionBits == 4 ? 4 : 8) : 8
    }

    /// Bits for an MTP head module path.
    public static func mtpBits(_ path: String) -> Int { path.contains("switch_mlp") ? 4 : 8 }

    /// Every quantizable layer (Linear or stacked experts) of `module` the rule selects, with its bits.
    static func plan(_ module: Module, bits rule: (String) -> Int?) -> [String: Int] {
        var plan: [String: Int] = [:]
        for (path, leaf) in module.leafModules().flattened() where leaf is Linear || leaf is NTSwitchLinear {
            if let bits = rule(path) { plan[path] = bits }
        }
        return plan
    }

    static func decoderPlan(_ model: NemotronTranscribeModel, precisionBits: Int) -> [String: Int] {
        plan(model) { decoderBits($0, precisionBits: precisionBits) }
    }

    static func mtpPlan(_ head: NTMTP) -> [String: Int] { plan(head) { mtpBits($0) } }

    /// Quantizes one weight (the shared step of the loader and the golden test).
    public static func quantize(_ weight: MLXArray, bits: Int, groupSize: Int) -> (weight: MLXArray, scales: MLXArray, biases: MLXArray?) {
        let (packed, scales, biases) = MLX.quantized(weight, groupSize: groupSize, bits: bits, mode: .affine)
        return (packed, scales, biases)
    }

    /// Replaces each planned `.weight` by its packed form plus `.scales`/`.biases`, one tensor at a time: each is
    /// read from the file, quantized, evaluated, and its BF16 source dropped before the next, so the peak is the derived
    /// model plus about two source tensors (the stacked experts are a transposed view, so quantizing one reads it and
    /// makes a contiguous copy: about 2.6 GB for the largest). Returns the per-module entries the installer reads.
    static func quantize(_ weights: inout [String: MLXArray], plan: [String: Int], groupSize: Int) -> [String: Any] {
        var entries: [String: Any] = ["group_size": groupSize, "mode": "affine"]
        for (index, path) in plan.keys.sorted().enumerated() {
            guard let bits = plan[path], let source = weights[path + ".weight"] else { continue }
            autoreleasepool {
                let q = quantize(source, bits: bits, groupSize: groupSize)
                if let biases = q.biases { eval(q.weight, q.scales, biases) } else { eval(q.weight, q.scales) }
                weights[path + ".weight"] = q.weight
                weights[path + ".scales"] = q.scales
                weights[path + ".biases"] = q.biases
            }
            entries[path] = ["group_size": groupSize, "bits": bits]
            if index % 8 == 7 { Memory.clearCache() }
        }
        Memory.clearCache()
        return entries
    }
}
