import Foundation
import VellaWire

/// Nemotron 3.5 streaming. Its optimized path uses stock MLX ops (no GPU-family kernels); the streaming helper builds
/// the session (NemotronNative) from `VellaNemotronSession` and `VellaNemotronOptions`.
public enum NemotronRuntime: StreamingModelRuntime {
    public static let architecture = Architecture.nemotronASR
    public static var gateRevision: String { VellaNemotronOptions.revision }
    public static let requiredGPUFamily: String? = nil
}
