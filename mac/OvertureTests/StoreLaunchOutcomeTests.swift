import Testing
@testable import Overture

// #1160: `overture` (build-install.sh --launch) reliably left TWO Overture instances running. The
// login agent starts the resident copy (it wins the store's single-writer lock); then
// `open overture://show` raced in before that copy had registered with LaunchServices, so a SECOND
// copy launched, lost the lock, and used to sit on the "data is unavailable" screen. A duplicate must
// instead DEFER to the resident and quit. StoreLaunchOutcome.classify is the decision that tells a
// duplicate (defer + terminate) apart from a genuinely broken store (show the degraded screen).
@Suite("A launching Overture classifies its store-lock outcome (#1160)")
struct StoreLaunchOutcomeTests {
    @Test func holdsLockAndStoreOpened_isReady() {
        #expect(
            StoreLaunchOutcome.classify(lockAcquired: true, storeOpened: true, reason: nil) == .ready)
    }

    @Test func lockHeldByAnotherCopy_isDuplicateInstance() {
        // The launch-race copy never got the lock, so it must defer to the resident and quit, not
        // linger on the degraded screen as a second instance.
        #expect(
            StoreLaunchOutcome.classify(
                lockAcquired: false, storeOpened: false,
                reason: "Another copy of Overture is already using its data.")
                == .duplicateInstance)
    }

    // The edge that keeps the guard honest (the failure path): a genuinely broken store holds the lock
    // but couldn't open (a foreign database at the path, #663, or an open failure). It MUST show the
    // degraded screen and must NEVER be mistaken for a duplicate and silently terminated, which would
    // hide the real problem behind an app that just quietly vanishes.
    @Test func holdsLockButStoreUnusable_isUnavailableNotDuplicate() {
        let reason = "Overture refused to open a foreign database at this path."
        let outcome = StoreLaunchOutcome.classify(lockAcquired: true, storeOpened: false, reason: reason)
        #expect(outcome == .unavailable(reason: reason))
        #expect(outcome != .duplicateInstance)
    }

    @Test func unavailableWithNoReason_fallsBackToADefaultMessage() {
        #expect(
            StoreLaunchOutcome.classify(lockAcquired: true, storeOpened: false, reason: nil)
                == .unavailable(reason: "Overture's data is unavailable."))
    }
}
