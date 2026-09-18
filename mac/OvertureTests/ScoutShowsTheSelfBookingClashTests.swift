import Testing
import Foundation

// #2689: the self-booking clash was invisible on Scout, which is the one stage where Keep happens.
//
// Dan asked directly, 2026-08-13, whether anything warns him about keeping a show on a date he has already
// pitched. `SelfBookingConflict` and every marker built on it worked, and all three of them were gated
// `focusedStage != .scout`, so the first time he learned a date already held a committed pitch was at
// Review, one screen after he had chosen the night.
//
// The gate's own comment gave the reason as "untriaged candidates are not commitments Dan is protecting
// yet". That conflates the two sides of the comparison. Only the OTHER shows' commitment matters, and the
// index enforces that by construction: `SelfBookingConflict.NightIndex.init` keeps a show only
// `where show.isCommitment` (`SelfBookingConflict.swift:108`). So a Scout row can never mark another Scout
// row, and the gate was protecting against something that cannot happen while costing the warning at the
// exact moment the night is chosen.
//
// WHY THIS IS A SOURCE GUARD rather than a behavioural test. The three model functions are already
// stage-agnostic and were passing before this change; the gate lived in a SwiftUI view body, which cannot
// be evaluated in a unit test (the same reason `SelfBookingScreenWorkMirrorTests` reads the source). So the
// thing to pin is the absence of the gate, and the absence alone would be satisfied by deleting the markers
// outright, which is why the second test asserts all three still render (L283).
@Suite("Scout shows the self-booking clash, where Keep happens (#2689)")
struct ScoutShowsTheSelfBookingClashTests {

    private var queueView: String { SourceGuardHelper.source("Overture/UI/QueueView.swift") }

    // The three render-path questions. Named here rather than inline because
    // `SelfBookingScreenWorkMirrorTests.askedByTheMirror` holds the same three for the cost mirror, and two
    // hand-maintained copies of one list drift (L41). This one is asserted against that one below.
    static let renderPathMarkers = ["selfBookingNote", "selfBookingRowMarker", "selfBookingWorkableNote"]

    @Test("No self-booking marker is gated on the stage not being Scout")
    func noStageGateOnTheClashMarkers() {
        let source = queueView
        #expect(!source.isEmpty, "QueueView.swift could not be read, so this guard measured nothing")

        // Counted rather than merely absent, so a failure says how many are left rather than only that one
        // is (L11). `focusedStage == .scout` is a DIFFERENT and legitimate construct, still used for the
        // probe keys and the night dismiss menu, and this deliberately does not match it.
        //
        // Through `normalizedCode`, which strips comments FIRST. Measured the hard way while writing this:
        // the raw-text version went red on the comment in `QueueView.swift` that RECORDS the removed gate,
        // which is the same trap `SourceGuardHelper.normalizedCode`'s own header describes from #1601.
        // Prose about a rule is where the rule is most often written down, so a code matcher that reads
        // comments fires on its own documentation (L103).
        let gate = "focusedStage != .scout"
        let code = SourceGuardHelper.normalizedCode(source)
        let remaining = code.components(separatedBy: gate).count - 1
        #expect(remaining == 0, Comment(rawValue:
            "\(remaining) self-booking marker(s) in QueueView.swift are still hidden on Scout, which is "
            + "the stage Keep happens on. The index only holds commitments, so a Scout row cannot mark "
            + "another Scout row and the gate protects nothing."))
    }

    @Test("All three markers still reach the screen")
    func theMarkersStillRender() {
        let source = queueView
        #expect(!source.isEmpty, "QueueView.swift could not be read, so this guard measured nothing")

        // Without this, deleting the markers outright would satisfy the test above.
        for marker in Self.renderPathMarkers {
            #expect(source.contains("QueueModel.\(marker)"), Comment(rawValue:
                "QueueView.swift no longer calls QueueModel.\(marker), so the clash it names cannot "
                + "reach Dan on any stage. Removing the Scout gate must not remove the marker."))
        }
    }

    @Test("This list and the cost mirror's list are the same three")
    func theTwoListsAgree() {
        // Both are hand written, in different files, about the same three render-path questions. Asserting
        // they agree is what stops one being extended and the other silently not (L41, L70).
        #expect(Set(Self.renderPathMarkers) == Set(SelfBookingScreenWorkMirrorTests.askedByTheMirror),
                Comment(rawValue:
            "The render-path marker list here and the cost mirror's askedByTheMirror have diverged. "
            + "A fourth marker added to one and not the other is a question the screen asks that one of "
            + "these two guards cannot see."))
    }
}
