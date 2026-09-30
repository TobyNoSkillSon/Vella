import IOKit.pwr_mgt

/// Prevent idle system sleep only while capturing; never changes system settings.
final class RecordingPower {
    private var assertion: IOPMAssertionID = 0
    func begin() {
        guard assertion == 0 else { return }
        _ = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn), "Vella is recording until you stop dictation" as CFString, &assertion)
    }
    func end() { if assertion != 0 { IOPMAssertionRelease(assertion); assertion = 0 } }
    deinit { end() }
}
