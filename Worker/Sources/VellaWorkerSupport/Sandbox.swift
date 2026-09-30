import Darwin

/// Installs the helpers' OS sandbox: everything allowed except networking. Darwin still exports the legacy seatbelt API
/// used by sandbox-exec; it is resolved explicitly because recent SDKs mark its Swift declaration unavailable. Absence
/// is fail-closed (false), never permission to run an unsandboxed helper. Call before any model or MLX work.
public func installOfflineSandbox() -> Bool {
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
