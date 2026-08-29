import Testing
import Foundation

// #1521: "This page is right" may not be offered on a page nobody has fetched.
//
// The scout results card is drawn from two places at once. Its ADDRESS comes off the LIVE watchlist row
// (#1125), so a correction Dan just saved shows immediately. Its failure message and its buttons came off
// the run SNAPSHOT. So the moment he corrected an address, the card offered Confirm on a page that had
// never been read at the address the card was showing.
//
// Pressing it there was not harmless in the way it looked. `WatchlistEditing.editURL` nils both content
// hashes, so `confirmEmpty` takes its no-hash path: it clears the failing display, writes no
// `confirmedEmptyHash`, and returns `.noHash`. Nothing is lost (the unread flag survives, so the next
// scout still reads the corrected page), but Dan has recorded "this page is right" about bytes nobody has
// ever fetched, and the only visible effect is the card disappearing. Dan's call, 2026-08-11: Confirm
// comes off the moment the address is corrected. Fix and Stop watching stay.
//
// Stated as "are there bytes to anchor to" rather than "was the address just corrected", because the
// missing bytes are WHY the button is meaningless and a correction is only one way to arrive there.
@Suite("Confirm needs bytes to anchor to (#1521)")
struct ConfirmNeedsBytesToAnchorToTests {

    @Test func aRowWithNoBytesHasNothingToConfirm() {
        #expect(SourceConfirmation.hasBytesToConfirm(anchorHash: nil) == false)
        #expect(SourceConfirmation.hasBytesToConfirm(anchorHash: "abc123"))
    }

    // The failure path #1521 was reported on: a page that read fine and carried no dated listings is the
    // one failure Confirm exists for, and it stops being offered once there is nothing to anchor to.
    @Test func theEmptyPageFailureStopsOfferingConfirmOnceTheAddressIsCorrected() {
        #expect(SourceFixConfirmActions.offersConfirm(.verdict(.noDatedContent), kind: .html,
                                                      hasBytesToConfirm: true),
                "the ordinary case is unchanged: bytes were read, and confirming them means something")
        #expect(SourceFixConfirmActions.offersConfirm(.verdict(.noDatedContent), kind: .html,
                                                      hasBytesToConfirm: false) == false)
    }

    // The SILENTLY EMPTY path (#2207), which #1521 does not mention and which had the identical defect.
    // Its card also survives a correction on purpose, and its route into Confirm is a short circuit that
    // returns true before any failure is consulted, so the anchor check has to sit AHEAD of it. This is
    // the assertion that pins that ordering: put the guard after the short circuit and this one alone
    // goes red while everything else still passes.
    @Test func theSilentlyEmptyPathIsCoveredByTheSameRule() {
        #expect(SourceFixConfirmActions.offersConfirm(nil, kind: .html, readFineAndCameBackEmpty: true,
                                                      hasBytesToConfirm: true),
                "a page that read fine and came back quiet is exactly what Confirm settles")
        #expect(SourceFixConfirmActions.offersConfirm(nil, kind: .html, readFineAndCameBackEmpty: true,
                                                      hasBytesToConfirm: false) == false,
                "with no bytes, the same press records a judgement about a page nobody fetched")
    }

    // The negative direction, which is the half Dan named explicitly: Fix and Stop watching STAY. A
    // corrected address that took every control with it would leave the card with nothing to do, and
    // "Read the ones I fixed" is what that card is for.
    @Test func fixAndStopWatchingSurviveTheCorrection() {
        #expect(SourceFixConfirmActions.offersFix(.verdict(.noDatedContent), kind: .html),
                "Fix is not gated on the bytes; a wrong address is the thing it exists to correct")
        #expect(SourceFixConfirmActions.offersAnything(failure: .verdict(.noDatedContent), kind: .html,
                                                       stopWatching: true, hasBytesToConfirm: false),
                "the card still draws its controls: Stop watching and Fix are both still on offer")
    }

    // And the kind still gets its say first: a source with no editable page offers neither control
    // whatever its bytes look like (#1450), so this rule cannot resurrect Confirm for Carnegie.
    @Test func aSourceWithNoEditablePageIsUnaffected() {
        #expect(SourceFixConfirmActions.offersConfirm(.verdict(.noDatedContent), kind: .algolia,
                                                      hasBytesToConfirm: true) == false)
        #expect(SourceFixConfirmActions.offersConfirm(.verdict(.noDatedContent), kind: .algolia,
                                                      hasBytesToConfirm: false) == false)
    }
}
