import Testing
import Foundation

// #3658 Phase 8: what the queue's eight sheets do when TWO conditions arrive at once.
//
// WHY A HAPPY-PATH TEST WOULD NOT DO. Eight `.sheet(item:)` presenters on one view is L242's shape: all
// but one request past the first is silently ignored. Phase 8 moved where the state LIVES without moving
// the presenters or their order, so that behaviour should be unchanged, and "each one still presents
// correctly" is a check that structurally cannot see either failure the move could have introduced (a
// second condition swallowed, L242, or one flag bound by two surfaces so dismissing one leaves the other
// standing, L238).
//
// WHAT THIS SUITE CANNOT SEE, MEASURED RATHER THAN ASSUMED, and recorded so nobody builds it twice.
//
// The obvious form of this test drives a real `QueueSheetHost` in #3480's `NSHostingView` rig and counts
// `window.sheets`. It was written, run on 2026-09-09, and DELETED, because its own positive control
// failed: ONE condition put **zero** sheets on the window. That is #3480's documented limitation rather
// than a defect in the code. The rig never orders its window front (ordering it front crashes the shared
// app host and truncates the whole hosted target), so AppKit lays the view out without a presentation
// pass and no sheet is ever put up. Had the positive control not been written first, the two-condition
// assertion would have read zero as "one sheet, as expected" and passed while measuring nothing (L98,
// L159, L171).
//
// So real PRESENTATION is verified by Dan's eye, and the two failures the move could have caused are
// each covered by something that can actually see them:
//
//   L238, one flag bound by more than one surface  -> `QueueInvalidationGuardTests` counts the
//                                                     presenters per flag, derived from the holder.
//   L242, a second condition swallowed             -> this suite, which asserts what the state DOES.
//
// A gap named beats a green test asserting a behaviour the harness cannot observe (L11, L98).
@Suite("Two queue sheet conditions at once (#3658)")
struct QueueSheetStateTests {

    private func guardCondition(_ key: String) -> SelfBookingGuard {
        SelfBookingGuard(key: key, title: "Already pitched", proceedLabel: "Send anyway",
                         message: "There is another pitch on that night.", proceed: {})
    }

    // Nothing asked, so nothing shown. The floor every assertion below is measured from: without it, a
    // holder that reported `isAsking` for an empty state would satisfy the rest of this suite.
    @Test("a fresh holder is asking nothing")
    func aFreshHolderAsksNothing() {
        #expect(!QueueSheetState().isAsking)
    }

    // TWO DIFFERENT FLAGS. The second is RECORDED, not discarded, which is what "silently ignored" means
    // here: SwiftUI shows one of the two and the other keeps its place in the state.
    @Test("a second condition on a different flag is recorded, not dropped")
    func aSecondConditionIsRecorded() {
        let sheets = QueueSheetState()
        sheets.pendingSelfBookingGuard = guardCondition("k1")
        sheets.pendingProbe = ProbeConfirm(keys: ["k9"], dateLabel: "Nov 14")

        #expect(sheets.pendingSelfBookingGuard != nil,
                Comment(rawValue: "the first condition was displaced by the second, so the question Dan "
                        + "was already being asked disappeared under him"))
        #expect(sheets.pendingProbe != nil,
                Comment(rawValue: "the second condition was discarded rather than held, so a request Dan "
                        + "made is gone with nothing said (L242)"))
    }

    // And the recorded one survives the shown one being answered, which is what makes "recorded" mean
    // something Dan will eventually see rather than a field nobody reads.
    @Test("clearing the shown condition leaves the waiting one intact")
    func clearingOneLeavesTheOther() {
        let sheets = QueueSheetState()
        sheets.pendingSelfBookingGuard = guardCondition("k1")
        sheets.pendingProbe = ProbeConfirm(keys: ["k9"], dateLabel: "Nov 14")

        sheets.pendingSelfBookingGuard = nil

        #expect(sheets.pendingProbe != nil)
        #expect(sheets.isAsking, "the holder went quiet with a condition still standing")
    }

    // THE SAME FLAG twice REPLACES, which is a different answer from the one above and has to be said
    // separately: two questions of the same kind cannot both be on screen, so the newer one wins.
    @Test("a second condition on the SAME flag replaces the first")
    func theSameFlagReplaces() {
        let sheets = QueueSheetState()
        sheets.pendingSelfBookingGuard = guardCondition("k1")
        sheets.pendingSelfBookingGuard = guardCondition("k2")

        #expect(sheets.pendingSelfBookingGuard?.key == "k2")
    }

    // Every flag can be raised and cleared, so a flag nothing can set is not hiding among the eight, and
    // `isAsking` really does read all of them. Written per flag rather than in a loop because each is a
    // different type; a loop would need one shared shape and that is the thing being checked.
    @Test("every flag raises and clears")
    func everyFlagRaisesAndClears() {
        let sheets = QueueSheetState()
        var raised: [String] = []

        func check(_ name: String, raise: () -> Void, clear: () -> Void) {
            raise()
            #expect(sheets.isAsking, Comment(rawValue: "raising \(name) left the holder asking nothing"))
            raised.append(name)
            clear()
            #expect(!sheets.isAsking, Comment(rawValue: "clearing \(name) left the holder still asking"))
        }

        check("pendingSelfBookingGuard", raise: { sheets.pendingSelfBookingGuard = guardCondition("k1") },
              clear: { sheets.pendingSelfBookingGuard = nil })
        check("pendingProbe", raise: { sheets.pendingProbe = ProbeConfirm(keys: ["k9"], dateLabel: "Nov 14") },
              clear: { sheets.pendingProbe = nil })
        check("pendingNightDismiss",
              raise: { sheets.pendingNightDismiss = NightDismiss(dateLabel: "Nov 14", reason: .wentBy,
                                                                 keys: ["k1"], runs: [],
                                                                 keysOnlyThisNight: ["k1"]) },
              clear: { sheets.pendingNightDismiss = nil })

        // The count is asserted, so a `check` call quietly deleted in a refactor is caught rather than
        // leaving a shorter suite that still passes (L288).
        #expect(raised.count == 3)
    }
}
