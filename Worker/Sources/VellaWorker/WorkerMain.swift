import Foundation
import Darwin
import MLX
import Cmlx
import MLXAudioSTT
import SmallMGEMM
import VellaWorkerSupport
import VellaWire

@main struct Main {
    static func main() async {
        let output = dup(STDOUT_FILENO)
        let sink = open("/dev/null", O_WRONLY)
        guard output >= 0, sink >= 0 else { exit(1) }
        dup2(sink, STDOUT_FILENO); dup2(sink, STDERR_FILENO); close(sink)
        guard installOfflineSandbox() else { exit(1) }
        guard FastPathGate.applyDeviceOverride() else { exit(1) }
        signal(SIGALRM, SIG_DFL)
        if CommandLine.arguments.dropFirst().first == "fast-selftest" {
            let values = Array(CommandLine.arguments.dropFirst(2))
            guard values.count == 2, values[0] == "--model", let path = try? localPath(values[1]),
                  let architecture = try? admit(path), let runtime = Worker.runtime(architecture) else { exit(FastPathGate.inconclusive) }
            // Test hook (reported in status): an unexplained child exit, or evidence against the fast path.
            switch FaultHooks.selfTest() {
            case .crash?: abort()
            case .exit?: exit(9)
            case .mismatch?: exit(FastPathGate.verdictFailed)
            case nil: break
            }
            let outcome: FastPathGate.SelfTestOutcome
            do {
                let worker = Worker()
                // A setup failure says nothing about the kernels: inconclusive, not a sticky verdict.
                guard let model = try? await withError({ try await worker.loadStock(path, architecture: architecture) }),
                      let capable = model as? any FastPathCapable else { exit(FastPathGate.inconclusive) }
                outcome = try withError { try FastPathGate.runSelfTest(capable, input: { runtime.input($0) }) }
            } catch {
                if let log = ProcessInfo.processInfo.environment["VELLA_KERNEL_DEBUG_LOG"], log.hasPrefix("/") {
                    try? String(describing: error).write(toFile: log, atomically: true, encoding: .utf8)
                }
                outcome = FastPathGate.SelfTestOutcome(passed: false)
            }
            guard outcome.passed else { exit(FastPathGate.verdictFailed) }
            guard !outcome.failed.isEmpty else { exit(0) }
            // Exact components passed; only the named tolerant ones stay off. No result file → inconclusive.
            guard let result = ProcessInfo.processInfo.environment[FastPathGate.resultVariable], result.hasPrefix("/"),
                  let bytes = try? JSONSerialization.data(withJSONObject: outcome.failed),
                  (try? bytes.write(to: URL(fileURLWithPath: result))) != nil else { exit(FastPathGate.inconclusive) }
            exit(FastPathGate.componentsFailed)
        }
        if CommandLine.arguments.dropFirst().first == "smallm-selftest" {
            // The shared SmallMGEMM package's unit self-test: relative RMS per class vs stock MLX, JSON on stdout.
            let results = SmallMGEMM.selfTest()
            let failures = SmallMGEMM.selfTestFailures(results)
            let report: [String: Any] = ["revision": SmallMGEMM.revision, "results": results.mapValues { Double($0) }, "failures": failures]
            if let bytes = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
                bytes.withUnsafeBytes { _ = write(output, $0.baseAddress, $0.count) }
                _ = write(output, "\n", 1)
            }
            close(output)
            exit(failures.isEmpty ? 0 : 1)
        }
        if CommandLine.arguments.dropFirst().first == "calibrate" {
            let status = await CalibrationCommand.run(arguments: Array(CommandLine.arguments.dropFirst(2)), output: output)
            close(output)
            exit(status)
        }
        do { try withError { Memory.cacheLimit = cacheBytes } } catch { exit(1) }
        #if VELLA_QUALIFICATION
        if CommandLine.arguments.dropFirst().first == "describe-model" {
            exit(await DescribeModel.run(Array(CommandLine.arguments.dropFirst(2))))
        }
        if CommandLine.arguments.dropFirst().first == "probe-parakeet" {
            alarm(120)
            do {
                let values = Array(CommandLine.arguments.dropFirst(2))
                guard values.count == 6 || values.count == 8 else { throw RequestError.invalid }
                let options = Dictionary(uniqueKeysWithValues: stride(from: 0, to: values.count, by: 2).map { (values[$0], values[$0+1]) })
                let path = try localPath(options["--model"])
                guard try admit(path) == .parakeet, let destination = options["--output"], destination.hasPrefix("/") else { throw RequestError.invalid }
                let audio = try Audio(options["--audio"])
                let model = try ParakeetModel.fromDirectory(path, preserveCheckpointDTypes: true)
                let reference = try options["--reference"].map { try MLX.loadArrays(url: URL(fileURLWithPath: $0))["mel"] } ?? nil
                let result = try model.qualificationSnapshot(audio: MLXArray(audio.samples).asType(ParakeetModel.inputDType), directory: URL(fileURLWithPath: destination), referenceMel: reference)
                let bytes = try responseBytes(result)
                bytes.withUnsafeBytes { _ = Darwin.write(output, $0.baseAddress, $0.count) }
                exit(0)
            } catch {
                let bytes = Data(#"{"error":"Qualification probe failed."}"#.utf8) + Data([10])
                bytes.withUnsafeBytes { _ = Darwin.write(output, $0.baseAddress, $0.count) }
                exit(1)
            }
        }
        #endif
        let worker = Worker()
        worker.push = { status in
            guard let data = try? responseBytes(["status": status]), writeAll(output, data) else { exit(1) }
        }
        while let line = readBoundedLine(stdin) {
            // Lab CPU device (VELLA_MLX_DEVICE=cpu, reported in test_hooks): CPU inference is far slower; 1 h deadline.
            if line.count <= maximumLine { alarm(FastPathGate.cpuDevice ? 3600 : 120) }
            let request = line.count <= maximumLine ? try? decodeJSON(line) : nil
            var response = await worker.handle(request)
            #if VELLA_QUALIFICATION
            if CommandLine.arguments.dropFirst().first == "probe-retention" { response["retirement"] = worker.qualificationRetirement }
            #endif
            guard let data = try? responseBytes(response), writeAll(output, data) else { exit(1) }
            alarm(0)
        }
        // stdin EOF: the app is gone or retired this worker. Exit; never outlive the app.
        try? worker.release(); close(output)
    }
}
