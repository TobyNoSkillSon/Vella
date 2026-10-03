import Foundation
import Darwin
import IOKit

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
    /// Registry hardware fact, independent of a Rosetta process's architecture.
    public static let gpuCoreCount: Int? = {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return (IORegistryEntryCreateCFProperty(service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue
    }()
    public static let benchmarkHardware = BenchmarkHardware(chip: cpuBrand, gpuCores: gpuCoreCount)
    /// The CPU brand string, e.g. "Apple M5 Max".
    public static let cpuBrand: String? = sysctlString("machdep.cpu.brand_string")
}
