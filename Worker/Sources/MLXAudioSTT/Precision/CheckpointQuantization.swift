import Foundation
import MLX
import MLXNN

/// Loading quantized weights is not quantizing fresh random tensors. Construct
/// the stock layers directly from the checkpoint; avoid abandoned quantize graphs.
func installCheckpointQuantization(
    model: Module, weights: [String: MLXArray],
    recipe: (String, Module) -> (groupSize: Int, bits: Int, mode: QuantizationMode)?
) throws {
    var updates: [(String, Module)] = []
    for (path, module) in model.leafModules().flattened() {
        guard let settings = recipe(path, module),
              let weight = weights[path + ".weight"],
              let scales = weights[path + ".scales"] else { continue }
        let biases = weights[path + ".biases"]
        let globalScale = weights[path + ".global_scale"]
        let replacement: Module
        if module is Linear {
            replacement = QuantizedLinear(weight: weight, bias: weights[path + ".bias"], scales: scales, biases: biases,
                                          groupSize: settings.groupSize, bits: settings.bits, mode: settings.mode, globalScale: globalScale)
        } else if module is Embedding {
            replacement = QuantizedEmbedding(weight: weight, scales: scales, biases: biases,
                                             groupSize: settings.groupSize, bits: settings.bits, mode: settings.mode, globalScale: globalScale)
        } else { throw CocoaError(.coderInvalidValue) }
        replacement.freeze()
        updates.append((path, replacement))
    }
    model.update(modules: ModuleChildren.unflattened(updates))
}
