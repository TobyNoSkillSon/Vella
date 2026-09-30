import Foundation
import MLX
import MLXNN
import MLXLMCommon

/// A precision derived locally at load from an installed source checkpoint (a float cast, then optionally an affine
/// quantization). The app hands the worker a directory holding only `vella-derived.json` (written by VellaCore's
/// `prepareDerivedModel`; keep the keys in step); config, tokenizer and weights come from `source`.
///
/// The derived model is structurally identical to the published community quants of the same architecture: the same
/// Linear/Embedding layers are quantized (every one whose input width divides the group size, the MLX `nn.quantize`
/// rule), with the same group size and bit width; everything else keeps the source's float weights (cast when the
/// recipe casts). Derivation runs tensor by tensor: peak memory is the derived model plus one source tensor.
public struct DerivedPrecision: Equatable, Sendable {
    public static let manifestName = "vella-derived.json"
    public let source: URL
    public let precision: String
    public let dtype: DType?
    public let bits: Int?
    public let groupSize: Int?
    /// A mixed per-layer recipe (manifest key `floatModules`, optional): module-path prefixes, as the architecture's
    /// loader names them (Whisper `model.encoder`), whose layers keep the source's float weights instead of being
    /// quantized. Empty = the uniform recipe. Stock and optimized paths load the same derived weights.
    public let floatModules: [String]

    public init(source: URL, precision: String, dtype: DType?, bits: Int?, groupSize: Int?, floatModules: [String] = []) {
        self.source = source; self.precision = precision; self.dtype = dtype; self.bits = bits; self.groupSize = groupSize
        self.floatModules = floatModules
    }

    /// Recipe identity for the fast-path gate key (the source files are hashed separately). A mixed recipe appends
    /// `:float=<prefixes>`; uniform recipes keep their string byte for byte.
    public var canonical: String {
        "derived:\(precision):dtype=\(dtype.map { "\($0)" } ?? "-"):bits=\(bits.map(String.init) ?? "-"):group=\(groupSize.map(String.init) ?? "-")"
            + (floatModules.isEmpty ? "" : ":float=\(floatModules.joined(separator: ","))")
    }

    /// True when `path` is one of the float-kept modules or inside one.
    public func keepsFloat(_ path: String) -> Bool {
        floatModules.contains { path == $0 || path.hasPrefix($0 + ".") }
    }

    public enum Invalid: Error { case manifest(String) }

    /// Nil when `directory` is not a derived model directory; throws when its manifest is invalid.
    public static func resolve(_ directory: URL) throws -> DerivedPrecision? {
        let file = directory.appendingPathComponent(manifestName)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular, (attributes[.size] as? NSNumber)?.intValue ?? .max <= 65536,
              let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] else { throw Invalid.manifest("unreadable") }
        // A derived directory holds nothing but its manifest (weights never mix with a recipe).
        let others = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0 != manifestName && $0 != ".DS_Store" }
        guard others.isEmpty else { throw Invalid.manifest("extra files") }
        guard (object["schema"] as? NSNumber)?.intValue == 1, let precision = object["precision"] as? String,
              let sourcePath = object["source"] as? String, sourcePath.hasPrefix("/"), !sourcePath.contains("\0"),
              let resolved = realpath(sourcePath, nil) else { throw Invalid.manifest("source") }
        let source = URL(fileURLWithPath: String(cString: resolved), isDirectory: true); free(resolved)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue,
              !FileManager.default.fileExists(atPath: source.appendingPathComponent(manifestName).path),
              source.standardizedFileURL != directory.standardizedFileURL else { throw Invalid.manifest("source directory") }
        var dtype: DType?
        switch object["dtype"] {
        case nil, is NSNull: dtype = nil
        case "bfloat16" as String: dtype = .bfloat16
        case "float16" as String: dtype = .float16
        default: throw Invalid.manifest("dtype")
        }
        // A cast alone carries its exact float label (BF16 ≠ FP16); a cast-then-quantize chain carries the bit width.
        if object["bits"] == nil, let dtype, precision != (dtype == .bfloat16 ? "BF16" : "FP16") { throw Invalid.manifest("dtype label") }
        let bits = (object["bits"] as? NSNumber)?.intValue, groupSize = (object["groupSize"] as? NSNumber)?.intValue
        if object["bits"] != nil || object["groupSize"] != nil {
            // Never below 4 bits; the label names the width.
            guard let bits, let groupSize, [4, 8].contains(bits), [32, 64, 128].contains(groupSize), precision == "\(bits)b" else {
                throw Invalid.manifest("quantization")
            }
        } else if dtype == nil { throw Invalid.manifest("empty recipe") }
        var floatModules: [String] = []
        if let value = object["floatModules"] {
            // Only meaningful with a quantization; prefixes are plain module paths.
            guard bits != nil, let list = value as? [String], !list.isEmpty, list.count <= 16, Set(list).count == list.count,
                  list.allSatisfy({ !$0.isEmpty && $0.count <= 128 && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }
                                    && !$0.hasPrefix(".") && !$0.hasSuffix(".") })
            else { throw Invalid.manifest("floatModules") }
            floatModules = list
        }
        return DerivedPrecision(source: source, precision: precision, dtype: dtype, bits: bits, groupSize: groupSize,
                                floatModules: floatModules)
    }

    /// The quantization the loader installs, as a checkpoint config would declare it.
    public var quantization: BaseConfiguration.PerLayerQuantization? {
        guard let bits, let groupSize else { return nil }
        return BaseConfiguration.PerLayerQuantization(quantization: BaseConfiguration.Quantization(groupSize: groupSize, bits: bits), perLayerQuantization: [:])
    }

    /// Module paths the published community quants quantize: Linear and Embedding leaves whose input width is a
    /// multiple of the group size (MLX `nn.quantize`'s default predicate). `exclude` drops architecture-specific
    /// subtrees that the published quants keep float.
    public func quantizationTargets(_ model: Module, exclude: (String) -> Bool = { _ in false }) -> Set<String> {
        guard let groupSize else { return [] }
        var targets: Set<String> = []
        for (path, module) in model.leafModules().flattened() where !exclude(path) && !keepsFloat(path) {
            let width: Int?
            if let linear = module as? Linear { width = linear.weight.shape.last }
            else if let embedding = module as? Embedding { width = embedding.weight.shape.last }
            else { width = nil }
            if let width, width % groupSize == 0 { targets.insert(path) }
        }
        return targets
    }

    /// Rewrites a sanitized checkpoint (module-path keys) into the derived precision, one tensor at a time: each source
    /// tensor is read, cast and/or quantized, evaluated and dropped before the next. Quantized modules get
    /// `.weight` (packed uint32), `.scales` and `.biases`, like a published checkpoint; other floats are cast when the
    /// recipe casts, else left untouched (still lazy).
    public func apply(to weights: inout [String: MLXArray], targets: Set<String>) {
        for key in weights.keys.sorted() {
            guard let source = weights[key], source.dtype.isFloatingPoint else { continue }
            let module = key.split(separator: ".").dropLast().joined(separator: ".")
            let quantize = bits != nil && key.hasSuffix(".weight") && targets.contains(module)
            guard quantize || dtype != nil else { continue }
            autoreleasepool {
                let value = dtype.map { source.asType($0) } ?? source
                weights[key] = nil
                if quantize, let bits, let groupSize {
                    let (packed, scales, biases) = MLX.quantized(value, groupSize: groupSize, bits: bits, mode: .affine)
                    if let biases { eval(packed, scales, biases) } else { eval(packed, scales) }
                    weights[key] = packed
                    weights[module + ".scales"] = scales
                    weights[module + ".biases"] = biases
                } else {
                    eval(value)
                    weights[key] = value
                }
            }
        }
        Memory.clearCache()
    }
}
