import Testing
import VellaWorkerSupport
@testable import VellaWorker

extension WorkerTests {
    @Suite struct Mode {
        @Test func selfTestOwnsADeadlineEvenIfParentDies() {
            for name in ["VellaWorker", "VellaStreamingWorker"] {
                var limits: [UInt32] = []
                WorkerEntry.armSelfTestDeadline(arguments: [name, "fast-selftest", "--model", "/test"], arm: { limits.append($0) })
                #expect(limits == [45])
                WorkerEntry.armSelfTestDeadline(arguments: [name], arm: { limits.append($0) })
                #expect(limits == [45], "idle workers are not timed out")
            }
        }

        @Test func invokedNameSelectsProtocolWithoutResolvingSymlinks() {
            for name in ["VellaStreamingWorker", "/tmp/Vella.app/Contents/MacOS/VellaStreamingWorker"] {
                #expect(WorkerMode(executable: name) == .streaming)
            }
            for name in ["VellaWorker", "/tmp/Vella.app/Contents/MacOS/VellaWorker", "unknown", "VellaStreamingWorker-copy"] {
                #expect(WorkerMode(executable: name) == .dictation)
            }
        }
    }
}
