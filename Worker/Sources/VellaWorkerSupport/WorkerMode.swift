import Foundation

/// One executable serves two protocols. The caller's invoked name also survives into gate children.
public enum WorkerMode: Equatable {
    case dictation, streaming

    public init(executable: String) {
        self = URL(fileURLWithPath: executable).lastPathComponent == "VellaStreamingWorker" ? .streaming : .dictation
    }
}
