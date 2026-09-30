import Foundation

/// Test hooks shared by both helpers (reported in status `test_hooks`; the gate's self-test child never inherits the
/// runtime ones). Each helper keeps its own lifecycle: when it reads a hook and what the fault does.
public enum FaultHooks {
    /// `VELLA_TEST_SELFTEST_FAULT`: the self-test child's injected outcome.
    public enum SelfTest: String { case crash, exit, mismatch }
    public static func selfTest(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> SelfTest? {
        environment["VELLA_TEST_SELFTEST_FAULT"].flatMap(SelfTest.init(rawValue:))
    }
    /// `VELLA_TEST_LOAD_FAULT`: loading a model whose path contains the value fails.
    public static func loadFails(_ path: URL, _ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard let fault = environment["VELLA_TEST_LOAD_FAULT"], !fault.isEmpty else { return false }
        return path.path.contains(fault)
    }
    /// `VELLA_TEST_OPTIMIZED_FAULT`: how the optimized path fails at run time (nil when unset or empty).
    public static func optimized(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        environment["VELLA_TEST_OPTIMIZED_FAULT"].flatMap { $0.isEmpty ? nil : $0 }
    }
}
