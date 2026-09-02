import Testing
import Foundation
import SwiftData

// #2997: a night that already has its OWN card is not this run card's to carry.
//
// #2754 made a drop refuse when the night the run would move to is a night another card holds. That
// kept the store safe and left Dan with a dead control: on a card in that shape, all four of the
// one-night dismiss reasons are refused every time and there is no reason he can act on. Found live
// 2026-08-19 on `Fresh Out The Box` at The Players Theatre (row 1010, nights Aug 28 and Oct 2) with a
// separate card (row 638) holding Oct 2.
//
// MEASURED on the live Release store the same day, over 936 rows and 100 multi-night runs: 9 runs land
// on a taken key, and they are NOT one shape. Six carry nothing that is not already on another card
// (Fresh Out The Box among them). Three carry both, and one of those, `America, Who Hurt You?`, has 15
// remaining nights of which only 1 has a twin. So closing every such run as redundant would have thrown
// away 14 nights Dan wants, which is why the rule releases nights rather than closing runs (L101: the
// case a fixture makes easy is not the case that ships).
//
// The rule: release the leading nights another card already holds, because the show is still in the
// queue on those cards, then either land on a free opening or, if nothing of this row's own is left,
// hand the caller a run that holds nothing and let it close the card.
//
// Every test injects `now` (L130) and builds its fixture from one of the two live shapes above (L48).
@MainActor
@Suite("A run night drop releases nights another card already holds (#2997)")
struct RunNightDropCoveredNightTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, Inquiry.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private let now = Date(timeIntervalSince1970: 1_786_000_000)

    private func card(_ ctx: ModelContext, group: String, venue: String, night: String,
                      nights: [String]? = nil) -> Prospect {
        let p = Prospect(naturalKey: Prospect.makeNaturalKey(groupName: group, performanceDate: night,
                                                             venue: venue),
                         groupName: group, discipline: "comedy", venue: venue, performanceDate: night,
                         sourceListingURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 3, tier: "long_shot", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil)
        if let nights {
            p.runNights = nights
            p.runEndDate = nights.max()
        }
        ctx.insert(p)
        return p
    }

    // The live shape Dan hit: two nights, and the second one has its own card.
    private func freshOutTheBox(_ ctx: ModelContext) -> (run: Prospect, separate: Prospect) {
        let group = "Fresh Out The Box"
        let venue = "The Players Theatre"
        let run = card(ctx, group: group, venue: venue, night: "2026-08-28",
                       nights: ["2026-08-28", "2026-10-02"])
        let separate = card(ctx, group: group, venue: venue, night: "2026-10-02")
        return (run, separate)
    }

    // The other live shape: a long run where only ONE of the remaining nights has a twin card. Closing
    // this row would take the other nights with it, so the drop must land rather than close.
    private func americaWhoHurtYou(_ ctx: ModelContext) -> (run: Prospect, separate: Prospect) {
        let group = "America, Who Hurt You?"
        let venue = "The Tank"
        let run = card(ctx, group: group, venue: venue, night: "2026-09-10",
                       nights: ["2026-09-10", "2026-09-11", "2026-09-12", "2026-09-13"])
        let separate = card(ctx, group: group, venue: venue, night: "2026-09-11")
        return (run, separate)
    }

    // MARK: nothing of its own left

    @Test("a run whose only other night is on its own card reports that it is fully covered")
    func fullyCoveredRunReportsItself() throws {
        let ctx = ModelContext(try container())
        let (run, _) = freshOutTheBox(ctx)
        try ctx.save()

        let outcome = run.dropNight("2026-08-28", reason: .dateConflict, now: now, in: ctx)

        #expect(outcome == .fullyCovered(releasing: ["2026-10-02"]))
    }

    @Test("the fully covered run gives up every night and keeps its own key")
    func fullyCoveredRunGivesUpItsNights() throws {
        let ctx = ModelContext(try container())
        let (run, separate) = freshOutTheBox(ctx)
        try ctx.save()
        let keyBefore = run.naturalKey

        _ = run.dropNight("2026-08-28", reason: .dateConflict, now: now, in: ctx)

        #expect(run.runNights.isEmpty)
        // The key does NOT move, because there is nowhere free to move it to. Moving it onto Oct 2 is
        // the collision #2754 exists to prevent, and it would merge this row into the other card.
        #expect(run.naturalKey == keyBefore)
        #expect(run.performanceDate == "2026-08-28")
        // The other card is untouched: it is where the show still lives.
        #expect(separate.performanceDate == "2026-10-02")
        try ctx.save()
        #expect(try ctx.fetch(FetchDescriptor<Prospect>()).count == 2)
    }

    // Dan's reason is recorded against HIS night and against nothing else. Recording it against Oct 2
    // as well is the #2691 defect: he never said the date conflict was about Oct 2, and #16 reads these.
    @Test("Dan's reason is recorded on his night and the released night is recorded as a duplicate")
    func eachNightKeepsItsOwnReason() throws {
        let ctx = ModelContext(try container())
        let (run, _) = freshOutTheBox(ctx)
        try ctx.save()

        _ = run.dropNight("2026-08-28", reason: .dateConflict, now: now, in: ctx)

        let dropped = DroppedNight.all(on: run).sorted { $0.night < $1.night }
        #expect(dropped.map(\.night) == ["2026-08-28", "2026-10-02"])
        #expect(dropped.first?.reason == .dateConflict)
        #expect(dropped.last?.reason == .duplicate)
    }

    // MARK: nights of its own left

    @Test("a run with nights of its own skips the covered night and lands on the next free one")
    func partiallyCoveredRunStillMoves() throws {
        let ctx = ModelContext(try container())
        let (run, _) = americaWhoHurtYou(ctx)
        try ctx.save()

        let outcome = run.dropNight("2026-09-10", reason: .pitchingOtherShows, now: now, in: ctx)

        #expect(outcome == .moved(to: "2026-09-12", releasing: ["2026-09-11"]))
        #expect(run.performanceDate == "2026-09-12")
        #expect(run.runNights == ["2026-09-12", "2026-09-13"])
        #expect(run.runEndDate == "2026-09-13")
        #expect(run.naturalKey == Prospect.makeNaturalKey(groupName: run.groupName,
                                                          performanceDate: "2026-09-12",
                                                          venue: run.venue))
    }

    // The nights it keeps are the whole point: this is the case that a close-the-run fix would lose.
    @Test("a partially covered run is never closed, because the nights it keeps are Dan's")
    func partiallyCoveredRunIsNotClosed() throws {
        let ctx = ModelContext(try container())
        let (run, _) = americaWhoHurtYou(ctx)
        try ctx.save()
        let feedback = ActionFeedback()

        ProspectMutations.dismissForReason(QueueItem(run), .pitchingOtherShows, prospects: [run],
                                           context: ctx, feedback: feedback,
                                           offer: DayOffOfferRequest(), now: now)

        #expect(run.status != .dismissed)
        #expect(run.runNights == ["2026-09-12", "2026-09-13"])
    }

    // A run with no covered nights at all takes exactly the path it always did, releasing nothing.
    @Test("a run whose next night nobody holds moves with nothing released")
    func uncoveredRunReleasesNothing() throws {
        let ctx = ModelContext(try container())
        let run = card(ctx, group: "Ordinary Run", venue: "The Tank", night: "2026-09-10",
                       nights: ["2026-09-10", "2026-09-11"])
        try ctx.save()

        #expect(run.dropNight("2026-09-10", reason: .tooSoon, now: now, in: ctx)
                == .moved(to: "2026-09-11", releasing: []))
        #expect(DroppedNight.all(on: run).map(\.night) == ["2026-09-10"])
    }

    // MARK: a store that cannot answer

    struct StoreUnreadable: Error {}

    // Every night is settled by lookups BEFORE the first write, so a read that fails part way through
    // the walk leaves the row exactly as it was rather than half released (L105, L5).
    @Test("a store that cannot answer refuses and writes nothing, even mid walk")
    func anUnreadableStoreRefusesTheWholeWalk() throws {
        let ctx = ModelContext(try container())
        let (run, _) = freshOutTheBox(ctx)
        try ctx.save()

        let outcome = run.dropNight("2026-08-28", reason: .dateConflict, now: now,
                                    lookup: { _ in throw StoreUnreadable() })

        #expect(outcome == .cannotCheck)
        #expect(run.runNights == ["2026-08-28", "2026-10-02"])
        #expect(run.performanceDate == "2026-08-28")
        #expect(run.droppedRunNights.isEmpty)
    }

    // The second lookup is the one the walk only reaches after the first said "taken", so a failure
    // there is the case a single-lookup test can never produce (L151).
    @Test("a read that fails only on the second night still refuses and writes nothing")
    func aLateReadFailureRefuses() throws {
        let ctx = ModelContext(try container())
        let (run, _) = americaWhoHurtYou(ctx)
        try ctx.save()
        let taken = Prospect.makeNaturalKey(groupName: run.groupName, performanceDate: "2026-09-11",
                                            venue: run.venue)

        let outcome = run.dropNight("2026-09-10", reason: .dateConflict, now: now, lookup: { key in
            if key == taken { return self.card(ctx, group: "x", venue: "y", night: "z") }
            throw StoreUnreadable()
        })

        #expect(outcome == .cannotCheck)
        #expect(run.runNights == ["2026-09-10", "2026-09-11", "2026-09-12", "2026-09-13"])
        #expect(run.droppedRunNights.isEmpty)
    }

    // MARK: wired into the card's Dismiss menu (L3: built is not wired)

    @Test("the card's Dismiss menu closes a fully covered run as a duplicate")
    func theCardClosesTheCoveredRun() throws {
        let ctx = ModelContext(try container())
        let (run, separate) = freshOutTheBox(ctx)
        try ctx.save()
        let feedback = ActionFeedback()

        ProspectMutations.dismissForReason(QueueItem(run), .dateConflict, prospects: [run], context: ctx,
                                           feedback: feedback, offer: DayOffOfferRequest(), now: now)

        #expect(run.status == .dismissed)
        // Dan's words for HIS night are on the night. The CARD is closed for what the card is.
        #expect(run.showOutcome == .duplicate)
        #expect(separate.status != .dismissed, "the card the show still lives on is untouched")
    }

    // The card vanishing is a bigger event than the night he asked about, so it may not be silent: a
    // press that removed the whole card and a press that dropped one night must not look identical
    // (L152).
    @Test("closing the run card says why it went and names the reason it carries")
    func theClosureSaysWhy() throws {
        let ctx = ModelContext(try container())
        let (run, _) = freshOutTheBox(ctx)
        try ctx.save()
        let feedback = ActionFeedback()

        ProspectMutations.dismissForReason(QueueItem(run), .dateConflict, prospects: [run], context: ctx,
                                           feedback: feedback, offer: DayOffOfferRequest(), now: now)

        let said = feedback.message ?? "no message at all"
        #expect(said.contains("Aug 28"), "names the night he acted on: \(said)")
        #expect(said.contains("duplicate"), "names what it is closed as, so he can find it: \(said)")
    }

    // MARK: Cmd+Z

    // The action released a night Dan never named, so the undo has to give that one back too. Restoring
    // only his night would leave Oct 2 dropped forever with nothing left that could put it back (L97).
    @Test("undoing the closure puts every released night back and reopens the card")
    func undoRestoresEveryReleasedNight() throws {
        let ctx = ModelContext(try container())
        let (run, _) = freshOutTheBox(ctx)
        try ctx.save()
        let undo = QueueUndoStack()

        ProspectMutations.dismissForReason(QueueItem(run), .dateConflict, prospects: [run], context: ctx,
                                           feedback: ActionFeedback(), offer: DayOffOfferRequest(),
                                           undo: undo, now: now)
        #expect(run.status == .dismissed)

        let entry = try #require(undo.takeTop())
        let outcome = QueueUndo.apply(entry, resolving: { _ in run }, in: ctx,
                                      export: (bookings: [], blockedDates: [], health: .ok))

        #expect(outcome.restored == 1)
        #expect(run.status != .dismissed)
        #expect(run.runNights == ["2026-08-28", "2026-10-02"])
        #expect(run.performanceDate == "2026-08-28")
        #expect(DroppedNight.all(on: run).isEmpty)
    }

    @Test("undoing a partial release puts the released night back into the run")
    func undoRestoresThePartialRelease() throws {
        let ctx = ModelContext(try container())
        let (run, _) = americaWhoHurtYou(ctx)
        try ctx.save()
        let undo = QueueUndoStack()

        ProspectMutations.dismissForReason(QueueItem(run), .tooSoon, prospects: [run], context: ctx,
                                           feedback: ActionFeedback(), offer: DayOffOfferRequest(),
                                           undo: undo, now: now)
        #expect(run.runNights == ["2026-09-12", "2026-09-13"])

        let entry = try #require(undo.takeTop())
        _ = QueueUndo.apply(entry, resolving: { _ in run }, in: ctx,
                            export: (bookings: [], blockedDates: [], health: .ok))

        #expect(run.runNights == ["2026-09-10", "2026-09-11", "2026-09-12", "2026-09-13"])
        #expect(run.performanceDate == "2026-09-10")
        #expect(DroppedNight.all(on: run).isEmpty)
    }

    // MARK: wired into the whole-night dismiss (L30: the class, not the instance)

    @Test("a whole-night dismiss closes the covered run and counts it as dismissed")
    func theNightDismissClosesTheCoveredRun() throws {
        let ctx = ModelContext(try container())
        let (run, separate) = freshOutTheBox(ctx)
        let other = card(ctx, group: "Some Other Show", venue: "Joe's Pub", night: "2026-08-28")
        try ctx.save()
        let feedback = ActionFeedback()

        ProspectMutations.dismissAll([run.naturalKey, other.naturalKey], reason: .pitchingOtherShows,
                                     dateLabel: "Aug 28", prospects: [run, other], context: ctx,
                                     feedback: feedback, now: now)

        #expect(other.status == .dismissed)
        #expect(run.status == .dismissed)
        #expect(run.showOutcome == .duplicate)
        #expect(separate.status != .dismissed)
        #expect(feedback.message?.contains("left alone") != true,
                "nothing was left alone: \(feedback.message ?? "no message at all")")
    }
}
