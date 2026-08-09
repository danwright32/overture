import Testing
import Foundation

// #1586: the comments explaining the reachability signal must name the stage Dan actually triages on.
//
// Four of them placed the signal "at Review, before the keep/dismiss decision". That was true when #1145
// was written. Since #1134's stage-only navigation, keep/dismiss happens on Scout (`status == .new`,
// `StageNavigation.matches(.scout,)`, with `OpenForDecision` as the one definition of a show still
// awaiting his decision) and `.review` means `status == .drafted`, a show whose email is already written.
//
// This is guarded rather than merely corrected because the cost was measured: reading those comments as
// live behaviour is what made a pass over this code conclude the feature worked as designed, and it hid
// #1585 (the check never surfacing where triage happens) for several days.
//
// Each guard asserts BOTH directions. Banning the stale phrase alone would be satisfied by deleting the
// comment, which is the same loss of the explanation by another route, so each region must also still
// name the stage it happens on.
@Suite("The reachability comments name the stage triage happens on (#1586)")
struct ReachabilityStageCommentTests {

    private func reachabilitySource() -> String {
        SourceGuardHelper.source("Overture/Domain/Reachability.swift")
    }

    // #2311: a guard reading source text passes just as happily when it read nothing at all, so every
    // region below is proved present before it is judged.
    @Test func theGuardIsActuallyReadingTheseFiles() {
        #expect(reachabilitySource().contains("enum Reachability"),
                "Reachability.swift did not read as itself, so every guard below is inspecting nothing")
        #expect(rowFlagComment() != nil,
                "the reachability flag comment in ProspectRowView.swift was not found")
        #expect(presenterFieldComment() != nil,
                "the presenter field comment in QueueView+Model.swift was not found")
        #expect(badgeComment() != nil,
                "the reachabilityBadge comment in QueueView+Model.swift was not found")
    }

    @Test func reachabilityDoesNotPlaceTheSignalAtReview() {
        let source = reachabilitySource()
        #expect(!source.contains("at Review"),
                "Reachability.swift still places the signal at Review; keep/dismiss happens on Scout")
        #expect(!source.contains("Review row"),
                "Reachability.swift still calls the triage row a Review row")
    }

    @Test func reachabilityNamesTheTriageStage() {
        #expect(reachabilitySource().contains("Scout"),
                "Reachability.swift explains where the signal is read without naming Scout")
    }

    // The comment on the view that renders the note.
    private func rowFlagComment() -> String? {
        SourceGuardHelper.between("// #1145/#1308: the reachability note",
                                  and: "@ViewBuilder private var reachabilityFlag",
                                  in: SourceGuardHelper.source("Overture/UI/ProspectRowView.swift"))
    }

    @Test func theRenderedNoteIsExplainedAgainstScout() {
        let comment = rowFlagComment() ?? ""
        #expect(!comment.contains("at Review"),
                "the reachability note's comment still says it is read at Review")
        #expect(comment.contains("Scout"),
                "the reachability note's comment does not say which stage it is read on")
    }

    // The comment on the field the free heuristic reads.
    private func presenterFieldComment() -> String? {
        SourceGuardHelper.between("// #1145: the presenting org",
                                  and: "var presenter: String?",
                                  in: SourceGuardHelper.source("Overture/UI/QueueView+Model.swift"))
    }

    @Test func thePresenterFieldIsExplainedAgainstScout() {
        let comment = presenterFieldComment() ?? ""
        #expect(!comment.contains("at Review"),
                "the presenter field's comment still places the heuristic at Review")
        #expect(comment.contains("Scout"),
                "the presenter field's comment does not say which stage the heuristic is read on")
    }

    // The comment on the model function that decides the badge.
    private func badgeComment() -> String? {
        SourceGuardHelper.between("// #1145/#1308: the reachability badge",
                                  and: "func reachabilityBadge",
                                  in: SourceGuardHelper.source("Overture/UI/QueueView+Model.swift"))
    }

    @Test func theBadgeIsExplainedAgainstScout() {
        let comment = badgeComment() ?? ""
        #expect(!comment.contains("Review row"),
                "the badge's comment still calls the row it appears on a Review row")
        #expect(!comment.contains("Review-time"),
                "the badge's comment still calls the decision a Review-time one")
        #expect(comment.contains("Scout") || comment.contains("triage"),
                "the badge's comment does not say when the decision it aids is made")
    }

    // The rename itself is recorded, so the older issue text (#1145, #1308, #1336) that says "Review"
    // is not read literally by whoever follows those references next.
    @Test func theStageRenameIsRecordedWhereTheRuleLives() {
        #expect(reachabilitySource().contains("#1586"),
                "Reachability.swift does not record that the stage this signal is read on was renamed")
    }
}
