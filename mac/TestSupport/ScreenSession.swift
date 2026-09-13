import Foundation
import CoreGraphics

// #3842: whether this Mac's screen is LOCKED, which decides whether a test that drives a real window can
// measure anything at all.
//
// WHY IT EXISTS. `RealScrollInvalidationTests` and `ArchiveScrollDoesNotRebuildTests` host a borderless
// window and deliver a real `CGEvent` wheel turn to the `NSScrollView` SwiftUI builds. On a LOCKED session
// the WindowServer never lays that window out, so there is nothing to scroll, and every one of those tests
// failed with "a real CGEvent wheel turn did not move the content at all".
//
// Measured 2026-09-12 on unchanged `main`: green at 15:42 with the session unlocked, and the same four
// tests red on every run after 16:00, on three separate trees, with `CGSSessionScreenIsLocked == 1`
// throughout. Waking the DISPLAY does not clear it; a woken display on a locked session still shows the
// lock screen. That was checked, because the display turning off correlated perfectly with the first red
// and was the wrong cause (L203).
//
// WHAT IT COST. Every merge in this repository goes through `scripts/test-all.sh`, so a locked screen
// blocked every merge, and the message it blocked with named four scroll tests rather than the lock. A red
// that is not a defect is worse than no test: it is indistinguishable from a real regression in the
// mechanism #3431 and #3437 rest on, and the natural next move is to go and debug the scroll path, which
// is what happened (L411, L538).
enum ScreenSession {

    // The rule, PURE, so every outcome can be produced by a test rather than waited for on a real Mac
    // whose lock state no test can set (L151).
    //
    // ABSENT READS AS UNLOCKED, deliberately, and this is the one judgement in the file. A missing
    // dictionary, or a missing key, means this reader cannot say. Treating that as LOCKED would skip the
    // tests on every machine that answers differently, and a silently skipped test is the failure this
    // whole file exists to prevent. Treating it as UNLOCKED leaves the tests running and failing loudly,
    // which is the recoverable direction (L93).
    static func isLocked(in session: [String: Any]?) -> Bool {
        guard let session else { return false }
        // The value arrives as a CFBoolean bridged to NSNumber, so it is read as a number rather than as
        // a `Bool`, which a conditional cast rejects on some bridgings.
        guard let flag = session["CGSSessionScreenIsLocked"] as? NSNumber else { return false }
        return flag.intValue == 1
    }

    // The live reading. A thin wrapper over the rule above, for the reason `MainThreadStall` states about
    // its own watchdog: a rule inside a system call is a rule no test can reach.
    static var isLocked: Bool {
        isLocked(in: CGSessionCopyCurrentDictionary() as? [String: Any])
    }

    // What a test says when it cannot measure. ONE spelling, so the runner's reader and every call site
    // cannot drift (L41), and it carries the test's own name so the report can say WHICH could not run.
    //
    // Printed rather than recorded as an Issue: an Issue is a FAILURE, and this is the absence of a
    // measurement, which must not read as either a pass or a defect (L98, L11).
    static func reportUnmeasured(_ what: String) {
        print("screen-locked-unmeasured: \(what)")
    }
}
