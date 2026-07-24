import Testing
import Foundation
import SwiftData
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

    // MARK: - The wiring

    private func sourcesView() -> String {
        SourceGuardHelper.source("Overture/UI/SourcesView.swift")
    }

    // #1417: this was a source scan, because the stop lived inside a SwiftUI view where no test could
    // reach it (#885). It lives in WatchlistMutations now, so the claim is checked by running it: the
    // source really is stopped, the Undo really is offered, and taking it really does put the source back.
    @MainActor
    private func watchedSource(refused: Bool = false, active: Bool = true) throws -> (ModelContext, WatchedSource) {
        let ctx = ModelContext(try ModelContainer(
            for: Schema([WatchedSource.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
        let s = WatchedSource(sourceId: "s1", orgName: "Bargemusic",
                              listingsURL: "https://bargemusic.org/events", kind: .html)
        s.isActive = active
        if !active { s.inactiveReason = refused ? .orgRefusal : .removedByDan }
        ctx.insert(s)
        return (ctx, s)
    }

    @MainActor
    @Test func stoppingASourceOffersAnUndoThatPutsItBack() throws {
        let (ctx, source) = try watchedSource()
        let feedback = ActionFeedback()

        WatchlistMutations.stopWatching(source, context: ctx, feedback: feedback)

        #expect(!source.isActive)
        #expect(source.inactiveReason == .removedByDan)
        #expect(feedback.message == ActionAck.stoppedWatching(org: "Bargemusic"))
        let undo = try #require(feedback.action)
        #expect(undo.label == "Undo")

        undo.perform()

        #expect(source.isActive)
        #expect(source.inactiveReason == nil)
        #expect(feedback.message == ActionAck.resumedWatching(org: "Bargemusic"))
    }

    // And the row keeps a way back that never expires. The banner auto-dismisses; a mis-click Dan notices
    // a minute later is still a mis-click, and before this his only route was retyping the org name and
    // the URL into the add form.
    @Test func aRemovedRowOffersAPermanentWayBack() {
        let view = sourcesView()

        // #1451: anchored on the words, not on the button that carries them. This used to look for
        // `Text("Watch again")`, the sheet's own hand-built copy of the capsule idiom, so moving that
        // styling onto the shared OVCapsuleButton reddened a test about a way back that had not moved.
        guard let watchAgain = view.range(of: "\"Watch again\"") else {
            Issue.record("the Removed row must offer a 'Watch again' button")
            return
        }
        // Drawn only for a source DAN removed. An org that asked him to stop is a different grade, a
        // different section, and never gets this button.
        #expect(view[..<watchAgain.lowerBound].suffix(600).contains("SourceGrade(source) == .removed"))
        // And it is the way BACK: the label alone would be satisfied by a button that did nothing.
        #expect(view[watchAgain.upperBound...].prefix(200).contains("resumeWatching(source)"))
    }

    // A refusal must never pass silently as though it worked. The sheet should never draw a resume control
    // on a refused org at all, and "should never" is exactly the claim that ends with somebody being
    // emailed who asked not to be, so the view handles the refusal rather than discarding the result.
    @MainActor
    @Test func theSheetSaysSoRatherThanSwallowingARefusal() throws {
        let (ctx, source) = try watchedSource(refused: true, active: false)
        let feedback = ActionFeedback()

        WatchlistMutations.resumeWatching(source, context: ctx, feedback: feedback)

        // The org that asked to stop stays off the watchlist, and Dan is told why rather than being
        // shown a confirmation for something that did not happen.
        #expect(!source.isActive)
        #expect(source.inactiveReason == .orgRefusal)
        #expect(feedback.message == WatchlistEditing.resumeRefusedMessage(orgName: "Bargemusic"))
        #expect(feedback.tone == .warning)
    }

    // The sheet is a separate window on macOS, so the main view's banner cannot cover it (#285). Without
    // its own, the Undo would be drawn behind the sheet and Dan would never see it.
    @Test func theSourcesSheetCarriesItsOwnFeedbackBanner() {
        #expect(sourcesView().contains(".actionFeedbackBanner()"))
    }
}
