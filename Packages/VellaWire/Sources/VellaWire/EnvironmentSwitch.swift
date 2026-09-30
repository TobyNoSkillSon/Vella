/// Every `VELLA_*` environment switch the app, the `vella` command and the helpers read, with who uses it and what
/// the code does with it. The helpers' gate key, their status `test_hooks`, the app's status `test_hooks` and the
/// self-test child's environment all derive from this one list.
public struct EnvironmentSwitch: Equatable, Sendable {
    /// Who sets it: the app itself, the installer or `vella` command, tests, or the lab (diagnosis and A/B runs).
    public enum Owner: String, Sendable { case app, installer, test, lab }
    public let name: String
    /// `name` is a prefix (a family of switches, e.g. every `VELLA_NEMO_<OPTION>`).
    public let isPrefix: Bool
    public let owner: Owner
    /// Its effective value joins the fast-path gate key (it changes which optimized components run or what they
    /// compute), so a verdict qualified under it is never reused for the defaults.
    public let gateKey: Bool
    /// Reported in a helper's status `test_hooks` when set.
    public let workerReported: Bool
    /// Reported in the app's status `test_hooks` when set.
    public let appReported: Bool
    /// Never passed to the gate's self-test child (instrumentation and runtime-fault hooks must not weaken it).
    public let strippedFromSelfTestChild: Bool

    init(_ name: String, prefix: Bool = false, _ owner: Owner, gateKey: Bool = false, worker: Bool = false, app: Bool = false,
         stripped: Bool = false) {
        self.name = name; isPrefix = prefix; self.owner = owner; self.gateKey = gateKey
        workerReported = worker; appReported = app; strippedFromSelfTestChild = stripped
    }

    public static let all: [EnvironmentSwitch] = [
        // Gate components (lab A/B and the two-stage gate's test hook).
        .init("VELLA_PARAKEET_FAST", .lab, gateKey: true, worker: true),
        .init("VELLA_PARAKEET_NAX", .lab, gateKey: true, worker: true),
        .init("VELLA_TEST_TOLERANT_FAULT", .test, gateKey: true, worker: true),
        .init("VELLA_NEMO_", prefix: true, .lab, gateKey: true, worker: true),
        // The user's selection: set by the app for every helper, reported as the status's `recipe`.
        .init("VELLA_RECIPE", .app),
        // Diagnosis and instrumentation.
        .init("VELLA_FORCE_STOCK", .lab, worker: true, app: true),
        .init("VELLA_PARAKEET_FORCE_STOCK", .lab, worker: true, app: true),
        .init("VELLA_MLX_DEVICE", .lab, worker: true),
        .init("VELLA_KERNEL_DEBUG_LOG", .lab, worker: true),
        .init("VELLA_KERNEL_DIAGNOSTIC_COMPONENT", .lab, worker: true, stripped: true),
        .init("VELLA_KERNEL_DIAGNOSTIC_CLIP", .lab, worker: true, stripped: true),
        .init("VELLA_PARAKEET_PROFILE", .lab, worker: true),
        .init("VELLA_QWEN_PROFILE", .lab, worker: true),
        .init("VELLA_WHISPER_PROFILE", .lab, worker: true),
        .init("VELLA_STREAM_PROFILE", .lab, worker: true),
        .init("VELLA_WHISPER_SEED", .lab, worker: true),
        // Where state lives (isolated runs).
        .init("VELLA_SUPPORT_DIR", .test, worker: true, app: true),
        .init("VELLA_WORKER_DATA_DIR", .test, worker: true),
        // Test hooks.
        .init("VELLA_STUB_MODELS", .test, worker: true, app: true),
        .init("VELLA_TEST_LOAD_FAULT", .test, worker: true, app: true),
        .init("VELLA_TEST_OPTIMIZED_FAULT", .test, worker: true, app: true),
        .init("VELLA_TEST_STOCK_FAULT", .test, worker: true, app: true),
        .init("VELLA_TEST_STUB_FOOTPRINT_MB", .test, worker: true, app: true),
        .init("VELLA_TEST_SELFTEST_FAULT", .test, worker: true, app: true),
        .init("VELLA_TEST_DECODER_NONFINITE", .test, worker: true, stripped: true),
        .init("VELLA_TEST_ENCODER_NONFINITE", .test, worker: true, stripped: true),
        .init("VELLA_TEST_MEMORY_FILE", .test, app: true),
        .init("VELLA_TEST_VM_STATS", .test, app: true),
        .init("VELLA_TEST_MINUTE_SECONDS", .test, app: true),
        // The gate's parent → self-test child result file.
        .init("VELLA_SELFTEST_RESULT", .app, worker: true, stripped: true),
        // App features a user may switch off (reported so a run without them never looks like the defaults).
        .init("VELLA_API", .app, app: true),
        .init("VELLA_UPDATE", .app, app: true),
        // The `vella` command, the installer, renders and update tests.
        .init("VELLA_APP", .installer),
        .init("VELLA_NO_LAUNCH", .test),
        .init("VELLA_BENCHMARKS", .test),
        .init("VELLA_RENDER_CHIP", .test),
        .init("VELLA_UPDATE_API_URL", .test),
        .init("VELLA_RELEASE_BASE_URL", .test),
        .init("VELLA_UPDATE_READY_SECONDS", .test),
    ]

    /// Exact names with a policy, in registry order.
    public static func names(where policy: (EnvironmentSwitch) -> Bool) -> [String] {
        all.filter { !$0.isPrefix && policy($0) }.map(\.name)
    }
    /// Prefixes with a policy.
    public static func prefixes(where policy: (EnvironmentSwitch) -> Bool) -> [String] {
        all.filter { $0.isPrefix && policy($0) }.map(\.name)
    }
}
