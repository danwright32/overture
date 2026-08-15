import Testing
import Foundation
import SwiftData

// #2754: dropping a run night re-keys the row IN PLACE, and the key it moves to can already be taken.
//
// MEASURED on the live Release store 2026-08-15: 8 of 98 multi-night runs collide this way, because a
// weekly series is stored BOTH as a run carrying every night AND as separate cards for individual
// nights. `Gross Prophets: A Comedy Musical` at Asylum NYC opens 2026-10-02 and would move to
// 2026-10-03, which a separate stored card already holds.
//
// `Prospect.naturalKey` is `@Attribute(.unique)`, so writing a key another row holds either throws on
// save (the dismiss silently fails, leaving the row half-mutated in memory) or merges the two rows and
// destroys one card's keep/dismiss history, its contacts and its outreach record. Neither is acceptable
// (L5: never destroy good state before its replacement is verified).
//
// Every test injects `now` (L130) and builds the fixture from the live shape above (L48).
@MainActor
@Suite("A run night drop must not land on another card's key (#2754)")
struct RunNightDropKeyCollisionTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, Inquiry.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private let now = Date(timeIntervalSince1970: 1_786_000_000)

    private func card(_ ctx: ModelContext, night: String, nights: [String]? = nil) -> Prospect {
        let group = "Gross Prophets: A Comedy Musical"
        let venue = "Asylum NYC"
        let p = Prospect(naturalKey: Prospect.makeNaturalKey(groupName: group, performanceDate: night,
                                                             venue: venue),
                         groupName: group, discipline: "theater", venue: venue, performanceDate: night,
                         sourceListingURL: nil, websiteURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 7, tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil)
        if let nights {
            p.runNights = nights
            p.runEndDate = nights.max()
        }
        ctx.insert(p)
        return p
    }

    // MARK: the collision

    // The live shape: the run (Oct 2 and Oct 3) beside a separate card for Oct 3 alone.
    @Test("dropping a night whose next opening is another card's date refuses and writes nothing")
    func refusesWhenTheKeyIsTaken() throws {
        let ctx = ModelContext(try container())
        let run = card(ctx, night: "2026-10-02", nights: ["2026-10-02", "2026-10-03"])
        let separate = card(ctx, night: "2026-10-03")
        try ctx.save()
        let runKeyBefore = run.naturalKey

        let outcome = run.dropNight("2026-10-02", reason: .dateConflict, now: now, in: ctx)

        #expect(outcome == .cannotMove(to: "2026-10-03"))
        // Nothing is half-written: a refusal that had already emptied `runNights` would leave the row
        // describing a run it no longer carries even though the dismiss visibly did nothing.
        #expect(run.naturalKey == runKeyBefore)
        #expect(run.performanceDate == "2026-10-02")
        #expect(run.runNights == ["2026-10-02", "2026-10-03"])
        #expect(run.droppedRunNights.isEmpty)
        // And the OTHER card is still its own row with its own identity, which is the data-safety half:
        // a merge would have taken one of these two away along with everything only it knew.
        try ctx.save()
        let rows = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(rows.count == 2)
        #expect(separate.performanceDate == "2026-10-03")
        #expect(separate.runNights.isEmpty)
    }

    // The ordinary path is unchanged: a run whose next night nobody else holds still moves.
    @Test("dropping a night whose next opening is free still moves the card")
    func movesWhenTheKeyIsFree() throws {
        let ctx = ModelContext(try container())
        let run = card(ctx, night: "2026-10-02", nights: ["2026-10-02", "2026-10-03"])
        try ctx.save()

        let outcome = run.dropNight("2026-10-02", reason: .dateConflict, now: now, in: ctx)

        #expect(outcome == .moved(to: "2026-10-03"))
        #expect(run.performanceDate == "2026-10-03")
        #expect(run.naturalKey == Prospect.makeNaturalKey(groupName: run.groupName,
                                                          performanceDate: "2026-10-03",
                                                          venue: run.venue))
        try ctx.save()
    }

    // A row that holds the candidate key is only in the way when it is a DIFFERENT row. The run itself
    // already holds its own key, and asking the store the question naively answers "taken" for it.
    @Test("the row's own stored key does not block its own drop")
    func ownKeyDoesNotBlockTheDrop() throws {
        let ctx = ModelContext(try container())
        let run = card(ctx, night: "2026-10-02", nights: ["2026-10-02", "2026-10-03"])
        try ctx.save()

        #expect(run.dropNight("2026-10-02", reason: .tooSoon, now: now, in: ctx) == .moved(to: "2026-10-03"))
    }

    // MARK: a store that cannot answer

    // The refusal has to fail closed, and it has to say so in its own words. Driven through the lookup
    // seam because a healthy in-memory store never throws, so nothing else can reach this branch, and a
    // test that only ever asks a working store proves nothing about the one that matters (L140).
    struct StoreUnreadable: Error {}

    @Test("a store that cannot answer refuses the drop rather than assuming the night is free")
    func anUnreadableStoreRefuses() throws {
        let ctx = ModelContext(try container())
        let run = card(ctx, night: "2026-10-02", nights: ["2026-10-02", "2026-10-03"])
        try ctx.save()

        let outcome = run.dropNight("2026-10-02", reason: .dateConflict, now: now,
                                    lookup: { _ in throw StoreUnreadable() })

        // NOT `.cannotMove`: nothing was read, so there is no date to name.
        #expect(outcome == .cannotCheck)
        #expect(run.runNights == ["2026-10-02", "2026-10-03"])
        #expect(run.performanceDate == "2026-10-02")
        #expect(run.droppedRunNights.isEmpty)
    }

    @Test("a store that cannot answer refuses the undo too")
    func anUnreadableStoreRefusesTheUndo() throws {
        let ctx = ModelContext(try container())
        let run = card(ctx, night: "2026-10-02", nights: ["2026-10-02", "2026-10-03"])
        try ctx.save()
        _ = run.dropNight("2026-10-02", reason: .dateConflict, now: now, in: ctx)

        #expect(run.restoreNight("2026-10-02", lookup: { _ in throw StoreUnreadable() }) == false)
        #expect(run.performanceDate == "2026-10-03")
        #expect(DroppedNight.all(on: run).map(\.night) == ["2026-10-02"])
    }

    // The two refusals must not share a sentence: one names a card that was found, the other admits
    // nothing was read. Naming a date here would send Dan looking for a card that does not exist.
    @Test("the unreadable refusal says what it measured, which is nothing")
    func theUnreadableRefusalNamesNoDate() {
        let taken = ActionAck.runNightKeyTaken(org: "Gross Prophets", night: "2026-10-03")
        let failed = ActionAck.runNightCheckFailed(org: "Gross Prophets")

        #expect(taken.contains("Oct 3"))
        #expect(failed.contains("Oct 3") == false, "no date was read, so none may be claimed: \(failed)")
        #expect(failed != taken)
    }

    // MARK: the same defect on the way back (L30: the class, not the instance)

    // Cmd+Z re-keys the row onto the night it dropped, and that key can be taken too: the feed still
    // lists the dropped night, so a scout run between the drop and the undo can mint a card on it.
    @Test("undoing a drop refuses when the night it would move back to is another card's date")
    func restoreRefusesWhenTheOldKeyIsTaken() throws {
        let ctx = ModelContext(try container())
        let run = card(ctx, night: "2026-10-02", nights: ["2026-10-02", "2026-10-03"])
        try ctx.save()
        #expect(run.dropNight("2026-10-02", reason: .dateConflict, now: now, in: ctx) == .moved(to: "2026-10-03"))
        try ctx.save()
        // The scout mints a separate card for Oct 2 while the drop stands.
        _ = card(ctx, night: "2026-10-02")
        try ctx.save()

        #expect(run.restoreNight("2026-10-02", in: ctx) == false)

        // The drop stands rather than being half-undone: the night stays dropped and the key stays put.
        #expect(run.performanceDate == "2026-10-03")
        #expect(run.runNights == ["2026-10-03"])
        #expect(DroppedNight.all(on: run).map(\.night) == ["2026-10-02"])
        try ctx.save()
        #expect(try ctx.fetch(FetchDescriptor<Prospect>()).count == 2)
    }

    @Test("undoing a drop still puts the night back when nobody took its date")
    func restoreStillWorksWhenTheOldKeyIsFree() throws {
        let ctx = ModelContext(try container())
        let run = card(ctx, night: "2026-10-02", nights: ["2026-10-02", "2026-10-03"])
        try ctx.save()
        _ = run.dropNight("2026-10-02", reason: .dateConflict, now: now, in: ctx)
        try ctx.save()

        #expect(run.restoreNight("2026-10-02", in: ctx) == true)

        #expect(run.performanceDate == "2026-10-02")
        #expect(run.runNights == ["2026-10-02", "2026-10-03"])
        #expect(DroppedNight.all(on: run).isEmpty)
        try ctx.save()
    }

    // The undo banner may not claim a row came back that could not (L12: report what verifiably
    // happened). A blocked night is the same situation as a row that moved on under Dan: not restored,
    // and counted as not restored.
    @Test("an undo whose night cannot come back is reported as not restored")
    func undoReportsTheRowAsNotRestored() throws {
        let ctx = ModelContext(try container())
        let run = card(ctx, night: "2026-10-02", nights: ["2026-10-02", "2026-10-03"])
        try ctx.save()
        let priorStatus = run.status
        _ = run.dropNight("2026-10-02", reason: .dateConflict, now: now, in: ctx)
        try ctx.save()
        _ = card(ctx, night: "2026-10-02")
        try ctx.save()

        let entry = QueueUndoEntry(recording: "Dismiss", on: run, priorStatus: priorStatus,
                                   priorShowOutcomeRaw: nil, priorDismissedAt: nil,
                                   priorConflictClearedKey: nil, droppedNight: "2026-10-02")
        let outcome = QueueUndo.apply(entry, resolving: { _ in run }, in: ctx,
                                      export: (bookings: [], blockedDates: []))

        #expect(outcome.restored == 0)
        #expect(outcome.didAnything == false)
        #expect(run.performanceDate == "2026-10-03")
    }

    // MARK: wired into both dismiss controls (L3: built is not wired)

    // The refusal must not fall through to the ordinary dismiss, which would archive the whole run: that
    // is the #2691 defect, arriving on the one path where Dan can see no reason for it.
    @Test("the card's Dismiss menu leaves the run alone and says which date is in the way")
    func theCardSaysWhyItRefused() throws {
        let ctx = ModelContext(try container())
        let run = card(ctx, night: "2026-10-02", nights: ["2026-10-02", "2026-10-03"])
        _ = card(ctx, night: "2026-10-03")
        try ctx.save()
        let feedback = ActionFeedback()

        ProspectMutations.dismissForReason(QueueItem(run), .tooSoon, prospects: [run], context: ctx,
                                           feedback: feedback, offer: DayOffOfferRequest(), now: now)

        #expect(run.status != .dismissed, "the whole run was not archived")
        #expect(run.runNights == ["2026-10-02", "2026-10-03"])
        #expect(run.performanceDate == "2026-10-02")
        #expect(feedback.message?.contains("Oct 3") == true,
                "the date in the way is named: \(feedback.message ?? "no message at all")")
        #expect(feedback.tone == .warning)
    }

    // The whole-night dismiss is the path where the run is one row among several, so the count Dan reads
    // has to exclude it and the banner has to say a run was left behind.
    @Test("a whole-night dismiss counts only what it dismissed and reports the run it kept")
    func theNightDismissCountsHonestly() throws {
        let ctx = ModelContext(try container())
        let run = card(ctx, night: "2026-10-02", nights: ["2026-10-02", "2026-10-03"])
        _ = card(ctx, night: "2026-10-03")
        let single = Prospect(naturalKey: Prospect.makeNaturalKey(groupName: "Some Other Show",
                                                                   performanceDate: "2026-10-02",
                                                                   venue: "Joe's Pub"),
                              groupName: "Some Other Show", discipline: "music", venue: "Joe's Pub",
                              performanceDate: "2026-10-02", sourceListingURL: nil, websiteURL: nil,
                              priorRelationship: "none", production: "self", profile: "strong",
                              coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                              matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        ctx.insert(single)
        try ctx.save()
        let feedback = ActionFeedback()

        ProspectMutations.dismissAll([run.naturalKey, single.naturalKey], reason: .pitchingOtherShows,
                                     dateLabel: "Oct 2", prospects: [run, single], context: ctx,
                                     feedback: feedback, now: now)

        #expect(single.status == .dismissed, "the ordinary show on that night still goes")
        #expect(run.status != .dismissed)
        #expect(run.runNights == ["2026-10-02", "2026-10-03"])
        // "1 show" and not "2 shows": the run is not among what was dismissed.
        #expect(feedback.message?.contains("The show on Oct 2 is dismissed") == true,
                "counted only what went: \(feedback.message ?? "no message at all")")
        #expect(feedback.message?.contains("left alone") == true)
    }
}
