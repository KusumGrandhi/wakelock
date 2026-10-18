import IOKit.pwr_mgt

/// Holds a PreventUserIdleSystemSleep assertion. The kernel drops it
/// automatically if the process dies, so it needs no crash handling.
final class PowerAssertion {
    private var assertionID: IOPMAssertionID = 0
    private(set) var isHeld = false

    func set(_ on: Bool, reason: String) {
        on ? acquire(reason: reason) : release()
    }

    private func acquire(reason: String) {
        guard !isHeld else { return }
        let rc = IOPMAssertionCreateWithName(
            "PreventUserIdleSystemSleep" as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &assertionID
        )
        isHeld = rc == kIOReturnSuccess
    }

    func release() {
        guard isHeld else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
        isHeld = false
    }
}
