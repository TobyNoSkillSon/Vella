import Testing
import VellaWorkerSupport

extension WorkerTests {
    @Suite struct Mode {
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
