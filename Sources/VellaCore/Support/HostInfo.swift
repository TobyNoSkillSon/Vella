import Darwin

/// Facts about this Mac read with sysctl.
public enum HostInfo {
    /// A sysctl string value (possibly empty); nil when it cannot be read.
    public static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
        return String(cString: bytes)
    }
    /// The CPU brand string, e.g. "Apple M5 Max".
    public static let cpuBrand: String? = sysctlString("machdep.cpu.brand_string")
}
