import Darwin

func installOfflineSandbox() -> Bool {
    // Darwin still exports the legacy seatbelt API used by sandbox-exec.
    // Resolve it explicitly because recent SDKs mark its Swift declaration unavailable.
    // Absence is fail-closed, not permission to run an unsandboxed worker.
    guard let handle = dlopen(nil, RTLD_NOW), let symbol = dlsym(handle, "sandbox_init"),
          let freeSymbol = dlsym(handle, "sandbox_free_error") else { return false }
    defer { dlclose(handle) }
    typealias Initialize = @convention(c) (UnsafePointer<CChar>, UInt64, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32
    typealias Release = @convention(c) (UnsafeMutablePointer<CChar>) -> Void
    let initialize = unsafeBitCast(symbol, to: Initialize.self)
    let release = unsafeBitCast(freeSymbol, to: Release.self)
    var error: UnsafeMutablePointer<CChar>?

    let result = initialize("(version 1)(allow default)(deny network*)", 0, &error)
    if let error { release(error) }
    return result == 0
}
func processMemory() -> [String: UInt64] {
    var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
    var result = ["processPeakRSSBytes": UInt64(usage.ru_maxrss)]
    var info = rusage_info_v4()
    let status = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: Optional<rusage_info_t>.self, capacity: 1) {
            proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
        }
    }
    if status == 0 {
        result["processRSSBytes"] = info.ri_resident_size
        result["processFootprintBytes"] = info.ri_phys_footprint
        result["processPeakFootprintBytes"] = info.ri_lifetime_max_phys_footprint
    }
    return result
}
