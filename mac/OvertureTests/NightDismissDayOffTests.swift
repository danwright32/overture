import Testing
import Foundation
import SwiftData

// #1743: dismissing a whole night for "Date conflict" offers to block that night, through the SAME
// DayOffOffer / DayOffOfferRequest / BlockDaysSheet plumbing as the single card dismiss. Dan's spec,
// 2026-07-29: "this should function exactly like if I click dismiss and select date conflict on a single
// event. use the same plumbing." This reverses #1500's "a bulk dismiss should stay quiet" (2026-07-26).
//
// Every test injects `now` and an empty calendar export, so nothing reads Dan's real files (L2, L130).
@MainActor
@Suite("A whole-night Date conflict dismiss offers a day off (#1743)")
struct NightDismissDayOffTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self, DayOff.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private let now = Date(timeIntervalSince1970: 1_786_000_000)
    private let noExport: DayOffEditing.Export = (bookings: [], blockedDates: [], health: .ok)

    @discardableResult
    private func show(_ ctx: ModelContext, _ name: String, on date: String,
                      nights: [String] = []) -> Prospect {
        let p = Prospect(naturalKey: Prospect.makeNaturalKey(groupName: name, performanceDate: date,
                                                             venue: "The Tin Room"),
                         groupName: name, discipline: "music", venue: "The Tin Room", performanceDate: date,
                         sourceListingURL: nil, priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        if !nights.isEmpty {
            p.runNights = nights
            p.runEndDate = nights.max()
        }
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    private func dismissNight(_ shows: [Prospect], _ reason: ShowOutcome, ctx: ModelContext,
                              undo: QueueUndoStack) -> DayOffOfferRequest.Pending? {
        ProspectMutations.dismissAll(shows.map(\.naturalKey), reason: reason, dateLabel: "Nov 18",
                                     nightDate: "2026-11-18", prospects: shows, context: ctx,
                                     feedback: ActionFeedback(), undo: undo, now: now, export: noExport)
    }

    @Test("a Date conflict night dismiss on an unblocked night offers exactly that night")
    func theOfferIsThatNight() throws {
        let ctx = try context()
        let a = show(ctx, "The Lantern Cabaret", on: "2026-11-18")
        let b = show(ctx, "Orchestra Invented", on: "2026-11-18")

        let offer = try #require(dismissNight([a, b], .dateConflict, ctx: ctx, undo: QueueUndoStack()))

        #expect(offer.start == "2026-11-18")
        #expect(offer.end == "2026-11-18")
        #expect(offer.subtitle == DayOffOffer.nightPickerSubtitle(count: 2, dateLabel: "Nov 18"))
        #expect(DayOffEditing.rows(in: ctx).isEmpty, "nothing is blocked until Dan confirms in the picker")
    }

    // Dan's call, 2026-07-29: just the night he right-clicked, even when a show on it runs past it.
    @Test("a run on the night does not widen the offer past the night")
    func aRunDoesNotWidenIt() throws {
        let ctx = try context()
        let run = show(ctx, "The Lantern Cabaret", on: "2026-11-18",
                       nights: ["2026-11-18", "2026-11-19", "2026-11-20"])

        let offer = try #require(dismissNight([run], .dateConflict, ctx: ctx, undo: QueueUndoStack()))

        #expect(offer.start == "2026-11-18")
        #expect(offer.end == "2026-11-18")
    }

    @Test("a night that is already blocked offers nothing")
    func anAlreadyBlockedNightOffersNothing() throws {
        let ctx = try context()
        let a = show(ctx, "The Lantern Cabaret", on: "2026-11-18")
        a.setScoutConflict("dayOff|2026-11-18|Invented Retreat")
        try ctx.save()

        #expect(dismissNight([a], .dateConflict, ctx: ctx, undo: QueueUndoStack()) == nil)
    }

    @Test("a reason that is not about the calendar offers nothing")
    func aNonCalendarReasonOffersNothing() throws {
        let ctx = try context()
        let a = show(ctx, "The Lantern Cabaret", on: "2026-11-18")
        #expect(dismissNight([a], .notAFit, ctx: ctx, undo: QueueUndoStack()) == nil)
        let b = show(ctx, "Orchestra Invented", on: "2026-11-18")
        #expect(dismissNight([b], .pitchingOtherShows, ctx: ctx, undo: QueueUndoStack()) == nil)
    }

    @Test("the undated group is not a night and offers nothing")
    func theUndatedGroupOffersNothing() throws {
        let ctx = try context()
        let a = show(ctx, "The Lantern Cabaret", on: "2026-11-18")
        let offer = ProspectMutations.dismissAll([a.naturalKey], reason: .dateConflict, dateLabel: "Date TBD",
                                                 nightDate: "tbd", prospects: [a], context: ctx,
                                                 feedback: ActionFeedback(), undo: QueueUndoStack(),
                                                 now: now, export: noExport)
        #expect(offer == nil)
    }

    // #1473's pairing, for a night: one Cmd+Z takes back the dismissals AND the day off they led to.
    @Test("undoing the night dismiss removes the day off it led to")
    func undoTakesBackBoth() throws {
        let ctx = try context()
        let a = show(ctx, "The Lantern Cabaret", on: "2026-11-18")
        let b = show(ctx, "Orchestra Invented", on: "2026-11-18")
        let undo = QueueUndoStack()

        let offer = try #require(dismissNight([a, b], .dateConflict, ctx: ctx, undo: undo))
        #expect(ProspectMutations.blockDaysOff(start: offer.start, end: offer.end, export: noExport,
                                               context: ctx, feedback: ActionFeedback(),
                                               undo: undo, undoDismissOf: offer.dismissKey))
        #expect(DayOffEditing.rows(in: ctx).count == 1)

        let entry = try #require(undo.takeTop())
        #expect(entry.blockedDays == QueueUndoEntry.BlockedDays(start: "2026-11-18", end: "2026-11-18"))
        let byKey = Dictionary(uniqueKeysWithValues: [a, b].map { ($0.naturalKey, $0) })
        QueueUndo.apply(entry, resolving: { byKey[$0] }, in: ctx, export: noExport)

        #expect(DayOffEditing.rows(in: ctx).isEmpty, "the night is not left blocked after the undo")
        #expect(a.status != .dismissed)
        #expect(b.status != .dismissed)
    }

    // The sibling the night path exposed: "Date conflict" drops ONE night of a run (#2691), so a run
    // leads a batch as a DROP rather than a dismissal, and the block has to fold into that entry too. The
    // same is true of the single card path, which is pinned below.
    @Test("the block folds into the undo even when the night's first row is a run that dropped the night")
    func aDroppedRunStillCarriesTheBlock() throws {
        let ctx = try context()
        let run = show(ctx, "The Lantern Cabaret", on: "2026-11-18", nights: ["2026-11-18", "2026-11-25"])
        let undo = QueueUndoStack()

        let offer = try #require(dismissNight([run], .dateConflict, ctx: ctx, undo: undo))
        #expect(run.performanceDate == "2026-11-25", "the run dropped the night rather than going")
        #expect(ProspectMutations.blockDaysOff(start: offer.start, end: offer.end, export: noExport,
                                               context: ctx, feedback: ActionFeedback(),
                                               undo: undo, undoDismissOf: offer.dismissKey))
        #expect(undo.entries.last?.blockedDays != nil)
    }

    @Test("a single card that drops a night of a run also carries its block into the undo")
    func theSingleCardDropCarriesTheBlock() throws {
        let ctx = try context()
        let run = show(ctx, "The Lantern Cabaret", on: "2026-11-18", nights: ["2026-11-18", "2026-11-25"])
        let undo = QueueUndoStack()
        let request = DayOffOfferRequest()

        ProspectMutations.dismissForReason(QueueItem(run), .dateConflict, prospects: [run], context: ctx,
                                           feedback: ActionFeedback(), offer: request, undo: undo,
                                           now: now, export: noExport)
        let offer = try #require(request.pending)
        #expect(ProspectMutations.blockDaysOff(start: offer.start, end: offer.end, export: noExport,
                                               context: ctx, feedback: ActionFeedback(),
                                               undo: undo, undoDismissOf: offer.dismissKey))
        #expect(undo.entries.last?.blockedDays != nil)
    }

    // THE HAZARD THE MUTATION TESTS CANNOT SEE (the issue's own "risk the tests will not catch"). The
    // confirmation closes in the same statement that performs the dismissal, and a second sheet asked for
    // in that tick silently never appears. So the offer is held and raised from the confirmation's
    // onDismiss. Pinned by source, since no test here can present a sheet; that the picker really appears
    // is checked in the running app.
    @Test("the night offer is raised after the confirmation closes, never in the same tick")
    func theOfferWaitsForTheConfirmationToClose() {
        let sheets = SourceGuardHelper.source("Overture/UI/QueueSheets.swift")
        let queue = SourceGuardHelper.source("Overture/UI/QueueView.swift")
        #expect(!sheets.isEmpty && !queue.isEmpty)
        #expect(sheets.contains(".sheet(item: $sheets.pendingNightDismiss, onDismiss: {"))
        let onDismiss = sheets.components(separatedBy: ".sheet(item: $sheets.pendingNightDismiss, onDismiss: {")
            .dropFirst().first?.prefix(700) ?? ""
        #expect(onDismiss.contains("dayOffOffer.request(offer)"))
        #expect(sheets.contains("dayOffAfterNightDismiss = onDismissNight(pending, pending.keys)"))
        #expect(queue.contains("nightDate: pending.date"))
        // Nothing in the queue raises the night's offer directly.
        #expect(!queue.contains("dayOffOffer.request("))
    }

    // The decision this reverses must not survive as a comment asserting it (L32, L252).
    @Test("the superseded #1500 note is gone from dismissAll")
    func theOldNoteIsGone() {
        let source = SourceGuardHelper.source("Overture/UI/ProspectMutations.swift")
        #expect(!source.isEmpty)
        #expect(!source.contains("a bulk dismiss should stay quiet"))
    }
}
