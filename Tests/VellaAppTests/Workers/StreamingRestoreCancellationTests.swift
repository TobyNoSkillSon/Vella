import XCTest
import Foundation
import Darwin
@testable import Vella
@testable import VellaCore

/// A streaming Reload whose replacement fails to load (and whose child ignores SIGTERM, so the restore
/// waits for it) is interrupted by shutdown; the restore must not bring a worker back afterwards.
final class StreamingRestoreCancellationTests: XCTestCase {
    private var root: URL!
    private var pids: [Int32] = []
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-restore-cancel-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        for pid in pids where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        try? FileManager.default.removeItem(at: root)
    }
    @MainActor private func pair() throws -> (Runtime, StreamingBackend) {
        let runtime = try Runtime.isolated(root)
        runtime.resolver = { path, mode in
            ModelRef(id: "stream", precision: URL(fileURLWithPath: path).lastPathComponent, path: path, mode: mode, memoryMB: 1000)
        }
        let script = root.appendingPathComponent("stream.py")
        try #"""
#!/usr/bin/python3
import sys,json,os,time,base64
frames=0
for line in sys.stdin:
    q=json.loads(line)
    if q['op'] in ('start','load'):
        frames=0
        if 'loadfail' in q['model']:
            print(json.dumps({'id':q['id'],'frames':0,'error':'injected load failure'}),flush=True)
            continue
        print(json.dumps({'status':{'pid':os.getpid(),'engine':'mlx','memory':{'footprint_mb':1000}}}),flush=True)
    if q['op']=='audio': frames += len(base64.b64decode(q['pcm']))//4
    r={'id':q['id'],'frames':frames,'partial':'','committed':''}
    if q['op']=='load': r['loaded']=True
    if q['op']=='finish': r.update(done=True,committed='hello')
    print(json.dumps(r),flush=True)
time.sleep(.2)
"""#.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let backend = StreamingBackend(helper: script, timeout: 2, runtime: runtime)
        runtime.streaming = backend
        return (runtime, backend)
    }
    private func config(_ path: String) -> Configuration { Configuration(model: path, mode: .streaming, streamingModel: path) }
    private func pause(_ seconds: Double) async throws { try await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }

    @MainActor func testShutdownDuringRestoreWaitDoesNotResurrectWorker() async throws {
        let (runtime, backend) = try pair(); defer { backend.shutdown() }
        let script = root.appendingPathComponent("stream.py")
        var source = try String(contentsOf: script)
        source = source.replacingOccurrences(of: "import sys,json,os,time,base64", with: "import sys,json,os,time,base64,signal")
        source = source.replacingOccurrences(of: "if 'loadfail' in q['model']:", with: "if 'loadfail' in q['model']:\n            signal.signal(signal.SIGTERM, signal.SIG_IGN)")
        source = source.replacingOccurrences(of: "            continue", with: "            time.sleep(1.0)\n            continue")
        try source.write(to: script, atomically: false, encoding: .utf8)
        try await runtime.load(runtime.resolve("/fixture/8b", mode: .streaming))
        if let pid = backend.processID { pids.append(pid) }
        let replacement = Task { try await runtime.load(runtime.resolve("/fixture/loadfail", mode: .streaming)) }
        for _ in 0..<100 where runtime.status.error == nil { try await pause(0.01) }
        XCTAssertNotNil(runtime.status.error)
        try await pause(0.05) // the catch is waiting for the failed child to exit
        backend.shutdown() // cancellation must survive that suspension
        _ = try? await replacement.value
        if let pid = backend.processID { pids.append(pid) }
        XCTAssertNil(backend.processID, "new regression: cancelled replacement restored a worker after shutdown")
        XCTAssertTrue(runtime.status.models.isEmpty)
    }
}
