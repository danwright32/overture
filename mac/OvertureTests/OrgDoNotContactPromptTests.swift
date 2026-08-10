import Testing
import Foundation

// #769: the prompt that asks whether a "not interested" reply meant this one show or the whole org.
//
// Tested by scanning the source, following the precedent of SendConfirmAndReconnectAlertsSharedTests
// (#631): ViewInspector cannot reach the contents of a confirmation dialog that has not been
// presented, and the properties worth protecting here are structural rather than visual.
//
// What matters is not that the dialog renders. It is that the two readings of "not interested" are
// wired to the right consequences, and that the DANGEROUS one is the one that takes a deliberate act.
// A dialog that renders beautifully and marks the wrong thing is the bug this feature exists to avoid.
@Suite("Org do-not-contact prompt (#769)")
struct OrgDoNotContactPromptTests {
    private static var draftReviewSource: String {
        let url = RepoRoot.mac
            .appendingPathComponent("Overture/UI/DraftReviewView.swift")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    // Closing a contact as "not interested" must raise the question. Without this, the refusal is
    // filed against one show and forgotten, which is the whole bug.
    @Test func aHardDeclineRaisesTheQuestion() {
        let src = Self.draftReviewSource
        // #2395: the five endings are generated from `ShowOutcome.pitched` rather than spelled out, so the
        // guard pins the CONDITION that raises the question instead of a button's literal text.
        #expect(src.contains("if outcome == .theySaidNo { askAboutWholeOrg = true }"))
        #expect(src.contains("askAboutWholeOrg = true"),
                "Marking a contact 'not interested' must ask whether the whole org is off-limits (#769).")
        #expect(src.contains("isPresented: $askAboutWholeOrg"))
    }

    // The destructive reading must be the one Dan actively chooses, and it must actually mark the org.
    @Test func onlyTheDeliberateChoiceMarksTheOrgAndItIsMarkedDestructive() {
        let src = Self.draftReviewSource
        #expect(src.contains("onSetOrgDoNotContact(true)"),
                "The 'never contact them again' choice must actually mark the org (#769).")
        #expect(src.contains("role: .destructive"),
                "Marking a whole org off-limits must read as the consequential act it is (#769).")
    }

    // The safe reading has to exist as its own option, so the dialog cannot be dismissed into the
    // dangerous one by accident. "Just this show" is the status quo, and must do nothing at all.
    @Test func theSafeReadingIsOfferedAndDoesNothing() {
        let src = Self.draftReviewSource
        #expect(src.contains("""
        Button("Just this show") { }
        """),
                "The safe reading must be offered explicitly, and must be a no-op (#769).")
    }

    // The prompt has to tell Dan what it will actually DO, not merely ask a question, and it has to
    // say the decision is reversible. A consequential prompt that hides its consequence is worse than
    // no prompt: it trains him to click through it.
    @Test func thePromptStatesTheConsequenceAndThatItCanBeUndone() {
        let src = Self.draftReviewSource
        #expect(src.contains("keep every future show from this org out of your queue"))
        #expect(src.contains("You can undo it from the row."))
    }
}
