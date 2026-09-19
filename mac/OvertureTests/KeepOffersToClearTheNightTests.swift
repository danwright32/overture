import Testing
import Foundation
import SwiftData

// #1819: after a Keep, offer to dismiss the other untriaged shows on that night.
//
// Dan, 2026-07-30: "When I keep a show on a given night, it should offer to dismiss all other shows on that
// night, if there are any." His calls on the open questions: the reason is always "Pitching other shows
// that night" with no choice on the sheet (2026-08-10, 2026-08-18), and one undo takes back only the
// dismissals, leaving the Keep standing (2026-08-18).
//
// Every name below is invented, and every test injects `now` and an empty calendar export.
@MainActor
@Suite("A Keep offers to clear the rest of the night (#1819)")
struct KeepOffersToClearTheNightTests {

    private func row(_ key: String, _ date: String = "2026-11-18", status: ReviewStatus = .new,
                     runEnd: String? = nil, discipline: String = "music") -> QueueScopeRow {
        var r = QueueScopeRow(id: key, groupName: key, discipline: discipline, venue: "The Tin Room",
                              performanceDate: date)
        r.status = status
        r.runEndDate = runEnd
        return r
    }

    private func offer(_ kept: String, _ rows: [QueueScopeRow]) -> NightDismiss? {
        QueueModel.nightClearAfterKeep(keptKey: kept, rows: rows, date: "2026-11-18", dateLabel: "Nov 18")
    }

    // MARK: who the offer covers

    @Test("a night holding only the kept show offers nothing")
    func aLoneShowIsSilent() {
        #expect(offer("kept", [row("kept")]) == nil)
    }

    @Test("the kept show is never in the batch, and the others are")
    func theKeptShowIsNeverInIt() throws {
        let found = try #require(offer("kept", [row("kept"), row("Quill Ensemble"), row("Moss Dance")]))
        #expect(!found.keys.contains("kept"))
        #expect(Set(found.keys) == ["Quill Ensemble", "Moss Dance"])
    }

    @Test("a show already kept, drafted or sent on the night is left alone")
    func onlyUntriagedShows() throws {
        let found = try #require(offer("kept", [row("kept"), row("Quill Ensemble"),
                                                row("Harbor Choir", status: .queued),
                                                row("Moss Dance", status: .drafted),
                                                row("Lantern Opera", status: .contacted)]))
        #expect(found.keys == ["Quill Ensemble"])
    }

    @Test("the reason is Pitching other shows that night, never Date conflict")
    func theReasonIsTheOneNightOne() throws {
        let found = try #require(offer("kept", [row("kept"), row("Quill Ensemble")]))
        #expect(found.reason == .pitchingOtherShows)
        #expect(found.origin == .afterKeep)
    }

    // Requirement 7, answered through `BulkDismiss.offersChoice` rather than restated: the reason drops
    // only this night of a run (#2691), which IS the narrower choice, so there is no second button.
    @Test("a run on the night is named, and gets no second button because the reason already spares it")
    func aRunIsNamedWithNoSecondButton() throws {
        let found = try #require(offer("kept", [row("kept"), row("Quill Ensemble"),
                                                row("Harbor Choir", runEnd: "2026-11-25")]))
        #expect(found.runs == ["Harbor Choir"])
        #expect(found.offersChoice == false)
    }

    @Test("an ungenred show is held back, exactly as the right-click holds it")
    func theGenreGateApplies() throws {
        let found = try #require(offer("kept", [row("kept"), row("Quill Ensemble"),
                                                row("Unread Show", discipline: "")]))
        #expect(found.keys == ["Quill Ensemble"])
        #expect(found.heldBack == 1)
    }

    @Test("the undated group is not a night and offers nothing")
    func theUndatedGroupIsSilent() {
        #expect(QueueModel.nightClearAfterKeep(keptKey: "kept", rows: [row("kept"), row("Quill Ensemble")],
                                               date: "tbd", dateLabel: "Date TBD") == nil)
    }

    // Requirement 6: declining is normal and the offer comes back on the next Keep.
    @Test("a second Keep on the same night offers again over what is still untriaged")
    func theOfferComesBack() throws {
        let rows = [row("kept"), row("second"), row("Quill Ensemble")]
        _ = try #require(offer("kept", rows))
        let again = try #require(offer("second", [row("kept", status: .queued), row("second"),
                                                  row("Quill Ensemble")]))
        #expect(again.keys == ["Quill Ensemble"])
    }

    @Test("the title names the OTHER shows")
    func theTitle() throws {
        let one = try #require(offer("kept", [row("kept"), row("Quill Ensemble")]))
        #expect(one.title == "Dismiss the other show on Nov 18?")
        let two = try #require(offer("kept", [row("kept"), row("Quill Ensemble"), row("Moss Dance")]))
        #expect(two.title == "Dismiss the other 2 shows on Nov 18?")
    }

    // MARK: one undo restores only the dismissals (Dan, 2026-08-18)

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self, DayOff.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private func show(_ ctx: ModelContext, _ name: String) -> Prospect {
        let p = Prospect(naturalKey: Prospect.makeNaturalKey(groupName: name, performanceDate: "2026-11-18",
                                                             venue: "The Tin Room"),
                         groupName: name, discipline: "music", venue: "The Tin Room",
                         performanceDate: "2026-11-18", sourceListingURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered", fitScore: 7,
                         tier: "high", fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil)
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    // The guard the 2026-08-18 comment names: assert BOTH halves in one fixture, because a test that only
    // checks the dismissals came back passes just as happily if the Keep was reverted too.
    @Test("one undo brings the other shows back and leaves the Keep standing")
    func undoTakesBackOnlyTheDismissals() throws {
        let ctx = try context()
        let kept = show(ctx, "Lantern Opera")
        let other = show(ctx, "Quill Ensemble")
        let undo = QueueUndoStack()
        let all = [kept, other]
        let export: DayOffEditing.Export = (bookings: [], blockedDates: [], health: .ok)

        ProspectMutations.setStatus(QueueItem(kept), .queued, nil, prospects: all, context: ctx,
                                    feedback: ActionFeedback(), undo: undo, undoLabel: "Keep")
        let found = try #require(QueueModel.nightClearAfterKeep(
            keptKey: kept.naturalKey, rows: all.map { QueueScopeRow(QueueItem($0)) },
            date: "2026-11-18", dateLabel: "Nov 18"))
        ProspectMutations.dismissAll(found.keys, reason: found.reason, dateLabel: found.dateLabel,
                                     nightDate: found.date, prospects: all, context: ctx,
                                     feedback: ActionFeedback(), undo: undo,
                                     now: Date(timeIntervalSince1970: 1_786_000_000), export: export)
        #expect(other.status == .dismissed)
        #expect(other.showOutcome == .pitchingOtherShows)

        let entry = try #require(undo.takeTop())
        let byKey = Dictionary(uniqueKeysWithValues: all.map { ($0.naturalKey, $0) })
        QueueUndo.apply(entry, resolving: { byKey[$0] }, in: ctx, export: export)

        #expect(other.status == .new, "the other show is back, untriaged")
        #expect(kept.status == .queued, "and the Keep is still standing")
    }

    // MARK: wiring (L3: built is not wired)

    @Test("a Keep that landed calls the caller back, and Scout raises the offer from it")
    func theKeepIsWired() {
        let factory = SourceGuardHelper.source("Overture/UI/ProspectRowFactory.swift")
        let queue = SourceGuardHelper.source("Overture/UI/QueueView.swift")
        #expect(!factory.isEmpty && !queue.isEmpty)
        #expect(factory.contains("status == .queued { onKept?() }"))
        #expect(SourceGuardHelper.containsCode(
            "onKept: focusedStage == .scout ? { if let offer = QueueModel.nightClearAfterKeep(", in: queue))
        #expect(SourceGuardHelper.containsCode("sheets.pendingNightDismiss = offer", in: queue))
    }
}
