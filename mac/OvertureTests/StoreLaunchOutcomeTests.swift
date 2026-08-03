import Testing

// #1160: `overture` (build-install.sh --launch) reliably left TWO Overture instances running. The
// login agent starts the resident copy (it wins the store's single-writer lock); then
// `open overture://show` raced in before that copy had registered with LaunchServices, so a SECOND
// copy launched, lost the lock, and used to sit on the "data is unavailable" screen. A duplicate must
// instead DEFER to the resident and quit. StoreLaunchOutcome.classify is the decision that tells a
// duplicate (defer + terminate) apart from a genuinely broken store (show the degraded screen).
//
// #1968: the question is asked in ONE direction only. Quitting without a word is the outcome that can
// hide a real problem, so it takes an affirmative statement that another copy holds the lock. Every
// other launch, including one that never got as far as ASKING for the lock, keeps its voice.
@Suite("A launching Overture classifies its store-lock outcome (#1160)")
struct StoreLaunchOutcomeTests {
    @Test func holdsLockAndStoreOpened_isReady() {
        #expect(
            StoreLaunchOutcome.classify(lockHeldByAnotherCopy: false, storeOpened: true, reason: nil)
                == .ready)
    }

    @Test func lockHeldByAnotherCopy_isDuplicateInstance() {
        // The launch-race copy never got the lock, so it must defer to the resident and quit, not
        // linger on the degraded screen as a second instance.
        #expect(
            StoreLaunchOutcome.classify(
                lockHeldByAnotherCopy: true, storeOpened: false,
                reason: "Another copy of Overture is already using its data.")
                == .duplicateInstance)
    }

    // The edge that keeps the guard honest (the failure path): a genuinely broken store holds the lock
    // but couldn't open (a foreign database at the path, #663, or an open failure). It MUST show the
    // degraded screen and must NEVER be mistaken for a duplicate and silently terminated, which would
    // hide the real problem behind an app that just quietly vanishes.
    @Test func holdsLockButStoreUnusable_isUnavailableNotDuplicate() {
        let reason = "Overture refused to open a foreign database at this path."
        let outcome = StoreLaunchOutcome.classify(lockHeldByAnotherCopy: false, storeOpened: false,
                                                  reason: reason)
        #expect(outcome == .unavailable(reason: reason))
        #expect(outcome != .duplicateInstance)
    }

    // #1968: a launch that stopped BEFORE the lock was ever asked for. The one-time store move runs
    // first and can block (the file at the old path is not Overture's, or the move could not finish),
    // and nothing has been touched at that point, so the launch has a real reason to give and no
    // evidence whatsoever that another copy is running.
    //
    // This is the shape that used to vanish: not a duplicate, but a launch that knows exactly what is
    // wrong, and the whole point of the degraded screen is that Dan gets told.
    @Test func aLaunchThatNeverReachedTheLock_saysWhyRatherThanQuitting() {
        let reason = "Couldn't finish moving Overture's data to its own folder."
        let outcome = StoreLaunchOutcome.classify(lockHeldByAnotherCopy: false, storeOpened: false,
                                                  reason: reason)
        #expect(outcome == .unavailable(reason: reason))
        #expect(outcome != .duplicateInstance)
    }

    // The silent quit takes an affirmative statement and nothing else can produce it, so a launch route
    // nobody has thought of yet inherits the outcome that keeps talking rather than the one that dies.
    @Test func onlyAnAffirmativeDuplicateEverTerminates() {
        for storeOpened in [true, false] {
            for reason in [nil, "any reason at all"] {
                #expect(StoreLaunchOutcome.classify(lockHeldByAnotherCopy: false,
                                                    storeOpened: storeOpened,
                                                    reason: reason) != .duplicateInstance)
            }
        }
    }

    @Test func unavailableWithNoReason_fallsBackToADefaultMessage() {
        #expect(
            StoreLaunchOutcome.classify(lockHeldByAnotherCopy: false, storeOpened: false, reason: nil)
                == .unavailable(reason: "Overture's data is unavailable."))
    }
}
