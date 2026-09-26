import Foundation
@testable import Vella
import VellaCore

/// A Python stand-in for VellaWorker speaking the stdio protocol: load/unload/status/trim ops, status push before
/// every change, transcription replies. The model folder name selects behaviour (`loadfail`, `slowload` 10 s,
/// `delayload` 1 s, `slowexit`: ignores SIGTERM and exits 0.5 s after stdin EOF); `FAKE_FOOTPRINT_MB` sets the
/// footprint it reports. Tests pair it with an isolated `Runtime` (temp support dir, memory file, minute seconds).
enum FakeWorker {
    static let script = #"""
#!/usr/bin/env python3
import json,sys,os,time,signal
model=None
def push(event):
    fp=float(os.environ.get('FAKE_FOOTPRINT_MB','1000'))
    st={'worker':'dictation','pid':os.getpid(),'event':event,'model':model,'engine':'mlx' if model else None,
        'engine_reason':'No optimized path for this model yet.' if model else None,'optimizations':{},
        'load_s':0.01,'memory':{'footprint_mb':fp if model else 50.0},'gpu':{'chip':'Fake M','family':'apple9'}}
    print(json.dumps({'status':st}),flush=True)
for line in sys.stdin:
    r=json.loads(line); op=r.get('op')
    if op=='load':
        name=r['model'].split('/')[-1]
        if 'loadfail' in name: model=None; push('load-failed'); print(json.dumps({'id':r['id'],'error':{'code':'load','message':'x'}}),flush=True); continue
        if 'slowload' in name: time.sleep(10)
        if 'delayload' in name: time.sleep(1)
        if 'slowexit' in name: signal.signal(signal.SIGTERM, signal.SIG_IGN)
        model=r['model']; push('load'); print(json.dumps({'id':r['id'],'loaded':True}),flush=True); continue
    if op in ('unload','status','trim'):
        if op=='unload': model=None
        push(op); print(json.dumps({'id':r['id'],'ok':True}),flush=True); continue
    print(json.dumps({'id':r['id'],'text':'Fixture recognized speech.','metrics':{'pid':os.getpid()}}),flush=True)
if model and 'slowexit' in model: time.sleep(0.5)
"""#
    static func install(in root: URL) throws -> URL {
        let url = root.appendingPathComponent("fake-worker.py")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}

extension Runtime {
    /// An isolated runtime: its own support dir, a fake memory probe and fast minutes. Never the real support dir.
    @MainActor static func isolated(_ root: URL, availableMB: Double = 100_000, minuteSeconds: Double = 60) throws -> Runtime {
        let support = root.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let memory = root.appendingPathComponent("memory.json")
        try JSONSerialization.data(withJSONObject: ["available_mb": availableMB]).write(to: memory)
        return Runtime(support: support, environment: ["VELLA_TEST_MEMORY_FILE": memory.path, "VELLA_TEST_MINUTE_SECONDS": String(minuteSeconds)])
    }
    @MainActor func setAvailableMB(_ value: Double) throws {
        guard let file = probe.testFile else { return }
        try JSONSerialization.data(withJSONObject: ["available_mb": value]).write(to: file)
    }
}
