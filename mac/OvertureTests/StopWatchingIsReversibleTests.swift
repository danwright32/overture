import Testing
import Foundation
@testable import Overture

// #845. "Stop watching" took a calendar off the watchlist on a single click, with no confirmation and no
// undo. Nothing was destroyed (the row, its feed history, and the source id stamped on every prospect it
// ever surfaced all survive), but the UI said none of that, so a mis-click read as permanent.
//
// That is not a cosmetic worry. #802 rests on a failing source NEVER auto-deactivating, precisely so that
// removing one stays Dan's deliberate choice, and a destructive-feeling button with no way back makes him
// hesitate over the one action the design expects him to take. It is also one careless step from the
// mistake this whole area exists to prevent: "Dan removed it" and "the org asked us to stop" are
// deliberately different states, and an interface that makes stopping feel dangerous invites conflating
// them.
@Suite("Stopping a source is reversible, and now says so (#845)")
struct StopWatchingIsReversibleTests {

    // The sentence has to carry the reassurance, not just the fact. "Stopped watching Bargemusic" alone is
    // exactly as frightening as the button was.
    @Test func stoppingSaysWhatItKeptAndThatItCanBeUndone() {
        let note = ActionAck.stoppedWatching(org: "Bargemusic")

        #expect(note.contains("Bargemusic"))
        #expect(note.lowercased().contains("keeps"))
        #expect(note.lowercased().contains("any time"))
    }

    @Test func resumingNamesTheOrgSoTheUndoIsVisiblyRealRatherThanSilent() {
        #expect(ActionAck.resumedWatching(org: "Bargemusic") == "Watching Bargemusic again.")
    }

    // MARK: - The wiring (#885: these live in a SwiftUI view, where no test can reach them)

    private func sourcesView() -> String {
        SourceGuardHelper.source("Overture/UI/SourcesView.swift")
    }

    // The stop must offer the Undo in the same breath. Without this, the domain function below is a
    // perfectly good way back that nothing in the app ever calls.
    @Test func stoppingASourceOffersAnUndo() throws {
        let body = try SourceGuard.functionBody(named: "stopWatching", in: sourcesView())

        #expect(body.contains("WatchlistEditing.stopWatching(source, in: context)"))
        #expect(body.contains("ActionAck.stoppedWatching(org: source.orgName)"))
        #expect(body.contains("label: \"Undo\""))
        #expect(body.contains("resumeWatching(source)"))
    }

    // And the row keeps a way back that never expires. The banner auto-dismisses; a mis-click Dan notices
    // a minute later is still a mis-click, and before this his only route was retyping the org name and
    // the URL into the add form.
    @Test func aRemovedRowOffersAPermanentWayBack() {
        let view = sourcesView()

        guard let watchAgain = view.range(of: "Text(\"Watch again\")") else {
            Issue.record("the Removed row must offer a 'Watch again' button")
            return
        }
        // Drawn only for a source DAN removed. An org that asked him to stop is a different grade, a
        // different section, and never gets this button.
        let preceding = view[..<watchAgain.lowerBound].suffix(600)
        #expect(preceding.contains("SourceGrade(source) == .removed"))
        #expect(preceding.contains("resumeWatching(source)"))
    }

    // A refusal must never pass silently as though it worked. The sheet should never draw a resume control
    // on a refused org at all, and "should never" is exactly the claim that ends with somebody being
    // emailed who asked not to be, so the view handles the refusal rather than discarding the result.
    @Test func theSheetSaysSoRatherThanSwallowingARefusal() throws {
        let body = try SourceGuard.functionBody(named: "resumeWatching", in: sourcesView())

        #expect(body.contains("WatchlistEditing.resumeWatching(source, in: context)"))
        #expect(body.contains("case .refused"))
        #expect(body.contains("tone: .warning"))
    }

    // The sheet is a separate window on macOS, so the main view's banner cannot cover it (#285). Without
    // its own, the Undo would be drawn behind the sheet and Dan would never see it.
    @Test func theSourcesSheetCarriesItsOwnFeedbackBanner() {
        #expect(sourcesView().contains(".actionFeedbackBanner()"))
    }
}
