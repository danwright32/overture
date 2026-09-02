import Testing
import Foundation
import SwiftData

// #2691: the rule wired into the TWO controls that choose a reason and dismiss.
//
// Both paths have the identical defect and the second is easy to miss, because it lives in different
// code and takes a list of keys rather than one card. Dan's call, 2026-08-13, when that omission was put
// to him: cover it in this issue rather than a second one, so the fix cannot ship half applied.
//
// A rule with no wiring is L3: built is not wired, and wired is not proven.
@MainActor
@Suite("Dropping a night from the two dismiss controls (#2691)")
struct RunNightDropWiringTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, Inquiry.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private let now = Date(timeIntervalSince1970: 1_786_000_000)

    private func run(_ ctx: ModelContext, name: String = "Lenka Fiore's Singer Showcase",
                     nights: [String] = ["2026-08-19", "2026-09-30", "2026-10-21"]) -> Prospect {
        let p = Prospect(naturalKey: Prospect.makeNaturalKey(groupName: name,
                                                             performanceDate: nights[0],
                                                             venue: "The Green Room 42"),
                         groupName: name, discipline: "music", venue: "The Green Room 42",
                         performanceDate: nights[0], sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        p.runEndDate = nights.last
        p.runNights = nights
        ctx.insert(p)
        return p
    }

    private func item(_ p: Prospect) -> QueueItem { QueueItem(p) }

    // MARK: the card's own Dismiss menu

    @Test("a night reason on the card drops that night and leaves the run in the queue")
    func theCardDropsOneNight() throws {
        let ctx = ModelContext(try container())
        let p = run(ctx)
        let feedback = ActionFeedback()

        ProspectMutations.dismissForReason(item(p), .dateConflict, prospects: [p], context: ctx,
                                           feedback: feedback, offer: DayOffOfferRequest(), now: now)

        #expect(p.performanceDate == "2026-09-30")
        #expect(p.runNights == ["2026-09-30", "2026-10-21"])
        #expect(p.status != .dismissed, "the show is still live and still pitchable")
    }

    @Test("a show reason on the card still dismisses the whole run")
    func theCardStillDismissesTheWholeRun() throws {
        let ctx = ModelContext(try container())
        let p = run(ctx)
        let feedback = ActionFeedback()

        ProspectMutations.dismissForReason(item(p), .notAFit, prospects: [p], context: ctx,
                                           feedback: feedback, offer: DayOffOfferRequest(), now: now)

        #expect(p.status == .dismissed)
        #expect(p.runNights == ["2026-08-19", "2026-09-30", "2026-10-21"], "nothing was picked apart")
        #expect(p.showOutcome == .notAFit)
    }

    @Test("a night reason on a single-night show dismisses it, exactly as today")
    func aSingleNightShowIsStillDismissed() throws {
        let ctx = ModelContext(try container())
        let p = run(ctx, nights: ["2026-08-19"])
        let feedback = ActionFeedback()

        ProspectMutations.dismissForReason(item(p), .dateConflict, prospects: [p], context: ctx,
                                           feedback: feedback, offer: DayOffOfferRequest(), now: now)

        #expect(p.status == .dismissed)
        #expect(p.showOutcome == .dateConflict)
    }

    // "It should function no differently than any other dismiss in that regard. If today the block the
    // day off picker pops up, it should still do that for a multi-night run." (Dan, 2026-08-13.)
    @Test("the day off picker still opens on a dropped night, pre-filled with that night")
    func theDayOffPickerStillOpens() throws {
        let ctx = ModelContext(try container())
        let p = run(ctx)
        let offer = DayOffOfferRequest()

        ProspectMutations.dismissForReason(item(p), .dateConflict, prospects: [p], context: ctx,
                                           feedback: ActionFeedback(), offer: offer, now: now)

        #expect(offer.pending?.start == "2026-08-19", "the night he dropped, not the one it moved to")
    }

    // MARK: the whole-night dismiss, right-clicking a date heading in Scout

    // The path that is easy to miss. A bulk "Pitching other shows that night" on Aug 19 would otherwise
    // still archive the Fiore run's Sep 30 and Oct 21.
    @Test("a night reason applied to a whole date drops only that night from each run it touches")
    func theNightDismissDropsOnlyThatNight() throws {
        let ctx = ModelContext(try container())
        let multi = run(ctx)
        let single = run(ctx, name: "A One Night Thing", nights: ["2026-08-19"])
        let feedback = ActionFeedback()

        ProspectMutations.dismissAll([multi.naturalKey, single.naturalKey], reason: .pitchingOtherShows,
                                     dateLabel: "Aug 19", prospects: [multi, single], context: ctx,
                                     feedback: feedback, now: now)

        #expect(multi.performanceDate == "2026-09-30", "the run moved on")
        #expect(multi.status != .dismissed)
        #expect(single.status == .dismissed, "a single-night show on that date is dismissed as before")
    }

    @Test("a show reason applied to a whole date still archives every run it touches")
    func theNightDismissStillArchivesOnAShowReason() throws {
        let ctx = ModelContext(try container())
        let multi = run(ctx)
        let feedback = ActionFeedback()

        ProspectMutations.dismissAll([multi.naturalKey], reason: .notAFit, dateLabel: "Aug 19",
                                     prospects: [multi], context: ctx, feedback: feedback, now: now)

        #expect(multi.status == .dismissed)
        #expect(multi.runNights.count == 3)
    }

    // MARK: the clash badge

    // Trap 5 in the issue, and the one a mutation proved had no wiring test: `BlockedCalendar.conflict`
    // reports the earliest blocked night of the run, so once the blocked night is dropped the card must
    // stop showing Unavailable at all. If the badge survives the drop, the drop did not reach
    // `conflictKey`, and Dan is looking at a warning about a night the show no longer plays.
    @Test("dropping the blocked night clears the card's clash badge")
    func droppingTheBlockedNightClearsTheBadge() throws {
        let ctx = ModelContext(try container())
        let p = run(ctx)
        // The live block: Aug 19 is a day off, Empire Harmony Rehearsal.
        let export: DayOffEditing.Export = (bookings: [], blockedDates: ["2026-08-19"], health: .ok)
        ConflictSweep.reapply(p, export: export, in: ctx)
        #expect(p.conflictOpen, "the live card really does carry the badge")

        ProspectMutations.dismissForReason(item(p), .dateConflict, prospects: [p], context: ctx,
                                           feedback: ActionFeedback(), offer: DayOffOfferRequest(),
                                           now: now, export: export)

        #expect(p.conflictKey == nil)
        #expect(p.conflictOpen == false)
    }

    // And the same on the bulk path, because the badge is recomputed there too and a rule applied on one
    // control and not the other is the half-applied fix Dan asked this issue to prevent.
    @Test("the whole-night dismiss also clears the badge on a run it moves")
    func theNightDismissAlsoClearsTheBadge() throws {
        let ctx = ModelContext(try container())
        let p = run(ctx)
        let export: DayOffEditing.Export = (bookings: [], blockedDates: ["2026-08-19"], health: .ok)
        ConflictSweep.reapply(p, export: export, in: ctx)
        #expect(p.conflictOpen)

        ProspectMutations.dismissAll([p.naturalKey], reason: .pitchingOtherShows, dateLabel: "Aug 19",
                                     prospects: [p], context: ctx, feedback: ActionFeedback(),
                                     now: now, export: export)

        #expect(p.conflictKey == nil)
    }

    // MARK: undo

    @Test("undoing a dropped night puts the night back and the card where it was")
    func undoPutsTheNightBack() throws {
        let ctx = ModelContext(try container())
        let p = run(ctx)
        let undo = QueueUndoStack()
        let key = p.naturalKey
        ProspectMutations.dismissForReason(item(p), .dateConflict, prospects: [p], context: ctx,
                                           feedback: ActionFeedback(), offer: DayOffOfferRequest(),
                                           undo: undo, now: now)
        #expect(p.performanceDate == "2026-09-30")

        let entry = try #require(undo.takeTop())
        let outcome = QueueUndo.apply(entry, resolving: { k in k == p.naturalKey ? p : nil }, in: ctx)

        #expect(outcome.didAnything)
        #expect(p.performanceDate == "2026-08-19")
        #expect(p.runNights == ["2026-08-19", "2026-09-30", "2026-10-21"])
        #expect(p.naturalKey == key)
    }

    // The entry has to resolve by the key the row carries AFTER the drop, because that is what the row
    // is keyed on by the time Cmd+Z is pressed. Recorded before, it would look up a key nothing holds and
    // the press would silently do nothing while looking exactly like a working undo (#1415).
    @Test("the undo entry is keyed on where the drop LEFT the row")
    func theUndoEntryIsKeyedOnTheNewKey() throws {
        let ctx = ModelContext(try container())
        let p = run(ctx)
        let undo = QueueUndoStack()
        ProspectMutations.dismissForReason(item(p), .dateConflict, prospects: [p], context: ctx,
                                           feedback: ActionFeedback(), offer: DayOffOfferRequest(),
                                           undo: undo, now: now)

        let entry = try #require(undo.takeTop())

        #expect(entry.primaryRow.naturalKey == p.naturalKey)
    }
}
