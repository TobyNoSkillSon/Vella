import Foundation
import CoreFoundation
import Darwin

// IOReport is a private, system-wide API. Resolve it at runtime; failure is explicit.
typealias CopyChannels = @convention(c) (UInt64, UInt64) -> UnsafeRawPointer?
typealias Subscribe = @convention(c) (UnsafeRawPointer?, UnsafeRawPointer, UnsafeMutablePointer<UnsafeRawPointer?>, UInt64, UnsafeRawPointer?) -> UnsafeRawPointer?
typealias Samples = @convention(c) (UnsafeRawPointer, UnsafeRawPointer, UnsafeRawPointer?) -> UnsafeRawPointer?
typealias Delta = @convention(c) (UnsafeRawPointer, UnsafeRawPointer, UnsafeRawPointer?) -> UnsafeRawPointer?
typealias ChannelString = @convention(c) (UnsafeRawPointer) -> UnsafeRawPointer?
typealias IntegerValue = @convention(c) (UnsafeRawPointer, Int32) -> Int64

@_silgen_name("proc_pid_rusage")
private func pidRusage(_ pid: Int32, _ flavor: Int32, _ buffer: UnsafeMutablePointer<rusage_info_v6>) -> Int32

func cf<T: AnyObject>(_ pointer: UnsafeRawPointer, as type: T.Type) -> T {
    Unmanaged<T>.fromOpaque(pointer).takeUnretainedValue()
}
func release(_ pointer: UnsafeRawPointer) { Unmanaged<AnyObject>.fromOpaque(pointer).release() }

func string(_ ptr: UnsafeRawPointer?) -> String {
        guard let ptr else { return "" }
        return (Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String).trimmingCharacters(in: .whitespacesAndNewlines)
    }
func fail(_ message: String) -> Never {
    fputs("vella-energy: \(message)\n", stderr)
    exit(2)
}

struct ProcUsage {
    let raw: rusage_info_v6
    init?(_ pid: Int32) {
        var usage = rusage_info_v6()
        guard pidRusage(pid, 6, &usage) == 0 else { return nil }
        raw = usage
    }
    func report(since before: ProcUsage?) -> [String: Any] {
        let r = raw
        var result: [String: Any] = [
            "cpuUserSeconds": Double(r.ri_user_time) / 1e9,
            "cpuSystemSeconds": Double(r.ri_system_time) / 1e9,
            "packageIdleWakeups": r.ri_pkg_idle_wkups,
            "interruptWakeups": r.ri_interrupt_wkups,
            "physicalFootprintBytes": r.ri_phys_footprint,
            "residentBytes": r.ri_resident_size,
            "lifetimePeakFootprintBytes": r.ri_lifetime_max_phys_footprint,
            "billedEnergyRaw": r.ri_billed_energy,
            "billedEnergyUnit": "nJ; cross-task billing balance, not task energy",
            "cpuEnergyJoules": Double(r.ri_energy_nj) * 1e-9,
            "cpuEnergyScope": "XNU Recount task CPU energy estimate; excludes GPU/ANE/system energy"
        ]
        if let b = before?.raw {
            guard r.ri_proc_start_abstime == b.ri_proc_start_abstime else {
                result["deltaUnavailable"] = "PID reused"; return result
            }
            func diff(_ x: UInt64, _ y: UInt64) -> UInt64? { x >= y ? x-y : nil }
            result["deltaCpuUserSeconds"] = diff(r.ri_user_time, b.ri_user_time).map { Double($0)/1e9 } ?? NSNull()
            result["deltaCpuSystemSeconds"] = diff(r.ri_system_time, b.ri_system_time).map { Double($0)/1e9 } ?? NSNull()
            result["deltaPackageIdleWakeups"] = diff(r.ri_pkg_idle_wkups, b.ri_pkg_idle_wkups) ?? NSNull() as Any
            result["deltaInterruptWakeups"] = diff(r.ri_interrupt_wkups, b.ri_interrupt_wkups) ?? NSNull() as Any
            result["deltaBilledEnergyRaw"] = diff(r.ri_billed_energy, b.ri_billed_energy) ?? NSNull() as Any
            result["deltaCpuEnergyJoules"] = diff(r.ri_energy_nj, b.ri_energy_nj).map { Double($0) * 1e-9 } ?? NSNull()
        }
        return result
    }
}

final class Energy {
    private let handle: UnsafeMutableRawPointer
    private let source: UnsafeRawPointer
    private let channels: UnsafeRawPointer
    private let subscription: UnsafeRawPointer
    private let extra: UnsafeRawPointer?
    private let samples: Samples
    private let delta: Delta
    private let group: ChannelString
    private let name: ChannelString
    private let unit: ChannelString
    private let integer: IntegerValue
    private let metadata: [[String: String]]
    init() {
        guard let h = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY) else { fail("IOReport unavailable: \(String(cString: dlerror()))") }
        handle = h
        func symbol<T>(_ s: String, _ type: T.Type) -> T {
            guard let p = dlsym(h, s) else { fail("IOReport missing \(s)") }
            return unsafeBitCast(p, to: T.self)
        }
        let copy = symbol("IOReportCopyAllChannels", CopyChannels.self)
        let subscribe = symbol("IOReportCreateSubscription", Subscribe.self)
        samples = symbol("IOReportCreateSamples", Samples.self)
        delta = symbol("IOReportCreateSamplesDelta", Delta.self)
        group = symbol("IOReportChannelGetGroup", ChannelString.self)
        name = symbol("IOReportChannelGetChannelName", ChannelString.self)
        unit = symbol("IOReportChannelGetUnitLabel", ChannelString.self)
        integer = symbol("IOReportSimpleGetIntegerValue", IntegerValue.self)
        guard let all = copy(0, 0) else { fail("IOReportCopyAllChannels failed") }
        source = all
        guard let entries = CFDictionaryGetValue(cf(all, as: CFDictionary.self), Unmanaged.passUnretained("IOReportChannels" as CFString).toOpaque()) else { fail("IOReportChannels missing") }
        let array = cf(entries, as: CFArray.self)
        let count = CFArrayGetCount(array)
        var callbacks = kCFTypeArrayCallBacks
        let selected = CFArrayCreateMutable(kCFAllocatorDefault, count, &callbacks)!
        var found = [[String: String]]()
        for i in 0..<count {
            guard let item = CFArrayGetValueAtIndex(array, i) else { continue }
            let label = string(name(item))
            if string(group(item)) == "Energy Model" &&
                (label == "GPU Energy" || label.hasSuffix("CPU Energy") || label.hasPrefix("ANE") || label.hasPrefix("DRAM")) {
                CFArrayAppendValue(selected, item)
                found.append(["group": "Energy Model", "name": label, "unit": string(unit(item))])
            }
        }
        guard !found.isEmpty else { fail("Energy Model channel group unavailable") }
        metadata = found
        guard let mutable = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, cf(all, as: CFDictionary.self)) else { fail("channel dictionary copy failed") }
        channels = UnsafeRawPointer(Unmanaged.passRetained(mutable).toOpaque())
        CFDictionarySetValue(mutable, Unmanaged.passUnretained("IOReportChannels" as CFString).toOpaque(), Unmanaged.passUnretained(selected).toOpaque())
        var subChannels: UnsafeRawPointer?
        guard let s = subscribe(nil, channels, &subChannels, 0, nil) else { fail("IOReport subscription failed") }
        subscription = s
        extra = subChannels
    }
    deinit {
        release(subscription); release(channels); release(source)
        // IOReport's auxiliary subscription dictionary is owned by the API, not the caller.
        _ = extra
        dlclose(handle)
    }
    func snapshot() -> UnsafeRawPointer {
        guard let s = samples(subscription, channels, nil) else { fail("IOReportCreateSamples failed") }
        return s
    }
    func capture(_ action: () throws -> Void) rethrows -> [String: Any] {
        let start = snapshot(), clock = DispatchTime.now().uptimeNanoseconds
        defer { release(start) }
        try action()
        let end = snapshot(), elapsed = Double(DispatchTime.now().uptimeNanoseconds - clock)/1e9
        defer { release(end) }
        guard let difference = delta(start, end, nil) else { fail("IOReportCreateSamplesDelta failed") }
        defer { release(difference) }
        guard let list = CFDictionaryGetValue(cf(difference, as: CFDictionary.self), Unmanaged.passUnretained("IOReportChannels" as CFString).toOpaque()) else { fail("delta channels missing") }
        let arr = cf(list, as: CFArray.self)
        var channelsOutput = [[String: Any]]()
        var sums: [String: Double] = [:]
        var seen: [String: Int] = [:]
        for i in 0..<CFArrayGetCount(arr) {
            guard let item = CFArrayGetValueAtIndex(arr, i) else { continue }
            let label = string(name(item)), u = string(unit(item)), raw = integer(item, 0)
            let component: String? = label == "GPU Energy" ? "gpu" : label.hasSuffix("CPU Energy") ? "cpu" : label.hasPrefix("ANE") ? "ane" : label.hasPrefix("DRAM") ? "dram" : nil
            let scale: Double? = ["mJ": 1e-3, "uJ": 1e-6, "nJ": 1e-9][u]
            var entry: [String: Any] = ["name": label, "unit": u, "rawDelta": raw, "component": component ?? "unclassified"]
            if let component, let scale, raw >= 0 {
                let joules = Double(raw)*scale
                entry["joules"] = joules
                sums[component, default: 0] += joules
                seen[component, default: 0] += 1
            } else { entry["joules"] = NSNull(); entry["status"] = raw < 0 ? "negative delta" : "unknown unit or component" }
            channelsOutput.append(entry)
        }
        var components: [String: Any] = [:]
        for component in ["cpu", "gpu", "ane", "dram"] {
            let matched = channelsOutput.filter { $0["component"] as? String == component }
            components[component] = (seen[component] == matched.count && !matched.isEmpty) ? sums[component]! : NSNull() as Any
        }
        return ["elapsedSeconds": elapsed, "componentsJoules": components,
                "channels": channelsOutput, "availableChannels": metadata,
                "scope": "system-wide IOReport Energy Model (not process-attributed)"]
    }
}

func delay(_ milliseconds: Int) { Thread.sleep(forTimeInterval: Double(milliseconds)/1000) }
func requireVellaIdle() {
    let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Vella/dictation-status.json")
    guard let bytes = try? Data(contentsOf: path),
          let status = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
          status["phase"] as? String == "idle" else { fail("Vella not idle; discard this bracket") }
}
func number(_ arg: String, _ label: String, min: Int = 1) -> Int {
    guard let n = Int(arg), n >= min else { fail("invalid \(label): \(arg)") }
    return n
}
func output(_ data: [String: Any]) {
    let json = try! JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
    print(String(decoding: json, as: UTF8.self))
}

let args = Array(CommandLine.arguments.dropFirst())
guard let mode = args.first else { fail("usage: sample --interval-ms N [--pid PID] | measure [--baseline-ms N] -- command [args...]") }
let energy = Energy()
switch mode {
case "sample":
    var duration: Int?, pid: Int32?, requireIdle = false
    var i = 1
    while i < args.count {
        if args[i] == "--require-idle" { requireIdle = true; i += 1; continue }
        guard i+1 < args.count else { fail("missing argument to \(args[i])") }
        switch args[i] {
        case "--interval-ms": duration = number(args[i+1], "interval")
        case "--pid": pid = Int32(number(args[i+1], "pid"))
        default: fail("unknown option \(args[i])")
        }
        i += 2
    }
    guard let duration else { fail("--interval-ms required") }
    let before = pid.flatMap(ProcUsage.init)
    if pid != nil && before == nil { fail("cannot read pid rusage; process may have exited or access denied") }
    if requireIdle { requireVellaIdle() }
    let result = energy.capture {
        var remaining = duration
        while remaining > 0 {
            let n = min(remaining, 1000)
            delay(n); remaining -= n
            if requireIdle { requireVellaIdle() }
        }
    }
    var report: [String: Any] = ["mode": "sample", "energy": result]
    if let pid, let before {
        var usage = ProcUsage(pid)?.report(since: before) ?? ["unavailable": "process exited"]
        usage["pid"] = pid
        report["process"] = usage
    }
    output(report)
case "measure":
    var baselineMs = 5000, i = 1, handshake = false, requireIdle = false
    while i < args.count && args[i] != "--" {
        if args[i] == "--baseline-ms" && i+1 < args.count { baselineMs = number(args[i+1], "baseline"); i += 2 }
        else if args[i] == "--handshake" { handshake = true; i += 1 }
        else if args[i] == "--require-idle" { requireIdle = true; i += 1 }
        else { fail("unexpected option \(args[i])") }
    }
    guard i < args.count, args[i] == "--", i+1 < args.count else { fail("measure [--baseline-ms N] -- command [args...]") }
    let command = Array(args.dropFirst(i+1))
    if requireIdle { requireVellaIdle() }
    let baseline = energy.capture {
        var remaining = baselineMs
        while remaining > 0 {
            let n = min(remaining, 1000); delay(n); remaining -= n
            if requireIdle { requireVellaIdle() }
        }
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: command[0])
    process.arguments = Array(command.dropFirst())
    func subtract(_ measured: [String: Any], _ baseline: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        let idle = baseline["componentsJoules"] as! [String: Any]
        let work = measured["componentsJoules"] as! [String: Any]
        let ratio = (measured["elapsedSeconds"] as! Double)/(baseline["elapsedSeconds"] as! Double)
        for key in ["cpu", "gpu", "ane", "dram"] {
            result[key] = (work[key] as? Double).flatMap { w in (idle[key] as? Double).map { w - $0*ratio } } ?? NSNull() as Any
        }
        return result
    }
    if handshake {
        let input = Pipe(), stdout = Pipe()
        process.standardInput = input
        process.standardOutput = stdout
        let cold = energy.capture {
            if requireIdle { requireVellaIdle() }
            do { try process.run() } catch { fail("failed to launch child: \(error)") }
            var line = Data()
            while true {
                let byte = stdout.fileHandleForReading.readData(ofLength: 1)
                if byte.isEmpty { fail("child exited before READY") }
                if byte == Data([10]) { break }
                line.append(byte)
                if line.count > 4096 { fail("child READY line too long") }
            }
            guard String(data: line, encoding: .utf8) == "READY" else { fail("child did not signal READY") }
        }
        let loadedIdle = energy.capture {
            var remaining = baselineMs
            while remaining > 0 {
                let n = min(remaining, 1000); delay(n); remaining -= n
                if requireIdle { requireVellaIdle() }
            }
        }
        let work = energy.capture {
            if requireIdle { requireVellaIdle() }
            input.fileHandleForWriting.write(Data("GO\n".utf8))
            input.fileHandleForWriting.closeFile()
            process.waitUntilExit()
        }
        output(["mode": "measure-handshake", "command": command, "exitCode": process.terminationStatus,
                "preloadIdle": baseline, "coldStart": cold, "coldIdleSubtractedJoules": subtract(cold, baseline),
                "loadedIdle": loadedIdle, "warmWork": work, "warmIdleSubtractedJoules": subtract(work, loadedIdle),
                "warning": "System-wide counters. Baselines precede their bracket and scale by wall time; negative differences retained. Warm bracket includes child exit/teardown."])
        exit(process.terminationStatus == 0 ? 0 : 1)
    }
    let measured = energy.capture {
        if requireIdle { requireVellaIdle() }
        do { try process.run() } catch { fail("failed to launch child: \(error)") }
        process.waitUntilExit()
    }
    output(["mode": "measure", "command": command, "exitCode": process.terminationStatus,
            "idleBaseline": baseline, "work": measured, "idleSubtractedJoules": subtract(measured, baseline),
            "warning": "Baseline precedes process and is scaled by elapsed wall time; system-wide concurrent work is included. Negative differences are retained."])
default: fail("unknown mode \(mode)")
}
