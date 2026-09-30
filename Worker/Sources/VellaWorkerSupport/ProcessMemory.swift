import Darwin

/// This process's resource usage from proc_pid_rusage (nil when unavailable).
private func rusage() -> rusage_info_v4? {
    var info = rusage_info_v4()
    let status = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: Optional<rusage_info_t>.self, capacity: 1) {
            proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
        }
    }
    return status == 0 ? info : nil
}

/// Physical footprint in bytes (what Activity Monitor shows as Memory).
public func processFootprintBytes() -> UInt64? { rusage()?.ri_phys_footprint }

/// The dictation helper's memory metrics: peak RSS, and resident size, footprint and peak footprint.
public func processMemory() -> [String: UInt64] {
    var usage = Darwin.rusage(); getrusage(RUSAGE_SELF, &usage)
    var result = ["processPeakRSSBytes": UInt64(usage.ru_maxrss)]
    if let info = rusage() {
        result["processRSSBytes"] = info.ri_resident_size
        result["processFootprintBytes"] = info.ri_phys_footprint
        result["processPeakFootprintBytes"] = info.ri_lifetime_max_phys_footprint
    }
    return result
}
