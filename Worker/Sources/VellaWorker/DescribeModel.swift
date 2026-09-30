#if VELLA_QUALIFICATION
    import CryptoKit
    import Foundation
    import MLX
    import MLXNN
    import MLXAudioSTT
    import VellaWorkerSupport
    import VellaWire

    /// Developer-only (qualification builds): `VellaWorker describe-model --model <dir> --output <json>` loads a model the
    /// way the workers do (derived precisions included) and writes every parameter's name, dtype, shape and SHA-256 of its
    /// bytes, plus the MLX peak memory of the load. `--save <file.safetensors>` also writes the loaded parameters. Used by lab/bench/tests/suites/quant to compare derived and published quants.
    enum DescribeModel {
        static func run(_ arguments: [String]) async -> Int32 {
            guard arguments.count == 4 || (arguments.count == 6 && arguments[4] == "--save"), arguments[0] == "--model", arguments[2] == "--output",
                let path = try? localPath(arguments[1])
            else { return 64 }
            do {
                let derived = try DerivedPrecision.resolve(path)
                let config = try jsonObject((derived?.source ?? path).appendingPathComponent("config.json"))
                Memory.peakMemory = 0
                let start = ProcessInfo.processInfo.systemUptime
                let module: Module
                if config["model_type"] as? String == "nemotron_asr" {
                    module = try withError { try NemotronASRModel.fromDirectory(derived?.source ?? path, derived: derived) }
                } else {
                    let architecture = try admit(path)
                    guard let model = try await Worker().loadStock(path, architecture: architecture) as? Module else { return 65 }
                    module = model
                }
                let seconds = ProcessInfo.processInfo.systemUptime - start
                let peak = Memory.peakMemory
                var parameters: [String: Any] = [:]
                for (name, array) in module.parameters().flattened() {
                    let bytes = array.asData(access: .copy).data
                    parameters[name] = [
                        "dtype": "\(array.dtype)", "shape": array.shape,
                        "sha256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                    ]
                }
                if arguments.count == 6 {
                    try MLX.save(arrays: Dictionary(uniqueKeysWithValues: module.parameters().flattened()), url: URL(fileURLWithPath: arguments[5]))
                }
                let result: [String: Any] = [
                    "model": path.path, "derived": derived?.canonical ?? NSNull(), "parameters": parameters,
                    "load_s": seconds, "load_peak_mlx_bytes": peak, "active_mlx_bytes": Memory.activeMemory,
                    "device": "\(Device.defaultDevice())"
                ]
                try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]).write(to: URL(fileURLWithPath: arguments[3]))
                return 0
            } catch {
                try? Data("\(error)".utf8).write(to: URL(fileURLWithPath: arguments[3] + ".error"))
                return 1
            }
        }
    }
#endif
