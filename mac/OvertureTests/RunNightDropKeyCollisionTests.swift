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
    //
    // #2997 changed what HAPPENS here (the night is released and the run closes, rather than the drop
    // being refused). What must never change is the reason #2754 exists: the key is not written onto a
    // row that already holds it, so both cards survive with everything only they knew. That is what this
    // asserts, deliberately in terms of the STORE rather than of the outcome value, so a later change to
    // the answer cannot quietly take the safety with it (L63).
    @Test("a drop onto a date another card holds never merges the two rows")
    func neverMergesTwoRows() throws {
        let ctx = ModelContext(try container())
        let run = card(ctx, night: "2026-10-02", nights: ["2026-10-02", "2026-10-03"])
        let separate = card(ctx, night: "2026-10-03")
        try ctx.save()
        let runKeyBefore = run.naturalKey
        let separateKeyBefore = separate.naturalKey

        _ = run.dropNight("2026-10-02", reason: .dateConflict, now: now, in: ctx)
        try ctx.save()

        let rows = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(rows.count == 2, "a merge would have taken one of these away")
        #expect(run.naturalKey == runKeyBefore, "the run did not take the other card's identity")
        #expect(separate.naturalKey == separateKeyBefore)
        #expect(separate.performanceDate == "2026-10-03")
        #expect(separate.runNights.isEmpty)
        #expect(separate.status != .dismissed, "the card the show still lives on is untouched")
    }

    // The ordinary path is unchanged: a run whose next night nobody else holds still moves.
    @Test("dropping a night whose next opening is free still moves the card")
    func movesWhenTheKeyIsFree() throws {
        let ctx = ModelContext(try container())
        let run = card(ctx, night: "2026-10-02", nights: ["2026-10-02", "2026-10-03"])
        try ctx.save()

        let outcome = run.dropNight("2026-10-02", reason: .dateConflict, now: now, in: ctx)

        #expect(outcome == .moved(to: "2026-10-03", releasing: []))
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

        #expect(run.dropNight("2026-10-02", reason: .tooSoon, now: now, in: ctx) == .moved(to: "2026-10-03", releasing: []))
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

        #expect(run.restoreNights(["2026-10-02"], lookup: { _ in throw StoreUnreadable() }) == false)
        #expect(run.performanceDate == "2026-10-03")
        #expect(DroppedNight.all(on: run).map(\.night) == ["2026-10-02"])
    }

    // The two outcomes must not share a sentence: one describes cards that were FOUND, the other admits
    // nothing was read. Claiming anything about another card here would send Dan looking for one that
    // nobody saw (L11).
    @Test("the unreadable refusal says what it measured, which is nothing")
    func theUnreadableRefusalClaimsNothing() {
        let closed = ActionAck.runClosedAsCovered(org: "Gross Prophets", night: "2026-10-02",
                                                   reason: .dateConflict)
        let failed = ActionAck.runNightCheckFailed(org: "Gross Prophets")

        #expect(closed.contains("own card"))
        #expect(failed.contains("own card") == false,
                "no card was read, so none may be claimed: \(failed)")
        #expect(failed != closed)
    }

    // MARK: the same defect on the way back (L30: the class, not the instance)

    // Cmd+Z re-keys the row onto the night it dropped, and that key can be taken too: the feed still
    // lists the dropped night, so a scout run between the drop and the undo can mint a card on it.
    @Test("undoing a drop refuses when the night it would move back to is another card's date")
    func restoreRefusesWhenTheOldKeyIsTaken() throws {
        let ctx = ModelContext(try container())
        let run = card(ctx, night: "2026-10-02", nights: ["2026-10-02", "2026-10-03"])
        try ctx.save()
        #expect(run.dropNight("2026-10-02", reason: .dateConflict, now: now, in: ctx) == .moved(to: "2026-10-03", releasing: []))
        try ctx.save()
        // The scout mints a separate card for Oct 2 while the drop stands.
        _ = card(ctx, night: "2026-10-02")
        try ctx.save()

        #expect(run.restoreNights(["2026-10-02"], in: ctx) == false)

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

        #expect(run.restoreNights(["2026-10-02"], in: ctx) == true)

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
                                   priorConflictClearedKey: nil, droppedNights: ["2026-10-02"])
        let outcome = QueueUndo.apply(entry, resolving: { _ in run }, in: ctx,
                                      export: (bookings: [], blockedDates: []))

        #expect(outcome.restored == 0)
        #expect(outcome.didAnything == false)
        #expect(run.performanceDate == "2026-10-03")
    }

    // MARK: wired into both dismiss controls (L3: built is not wired)

    // A run that keeps nights of its own must never be archived whole: that is the #2691 defect, and it
    // is the case #2997's walk exists to protect, so it is pinned on this path too.
    @Test("the card's Dismiss menu never archives a run that still has nights of its own")
    func theCardKeepsARunThatHasNightsLeft() throws {
        let ctx = ModelContext(try container())
        let run = card(ctx, night: "2026-10-02", nights: ["2026-10-02", "2026-10-03", "2026-10-04"])
        _ = card(ctx, night: "2026-10-03")
        try ctx.save()
        let feedback = ActionFeedback()

        ProspectMutations.dismissForReason(QueueItem(run), .tooSoon, prospects: [run], context: ctx,
                                           feedback: feedback, offer: DayOffOfferRequest(), now: now)

        #expect(run.status != .dismissed, "the whole run was not archived")
        #expect(run.runNights == ["2026-10-04"])
        #expect(run.performanceDate == "2026-10-04")
        #expect(feedback.message?.contains("Oct 4") == true,
                "says where the run now opens: \(feedback.message ?? "no message at all")")
    }

    // The whole-night dismiss is the path where the run is one row among several, and the count Dan reads
    // has to be the rows that ACTUALLY went (L12). A closed run is among them, and is named besides.
    @Test("a whole-night dismiss counts the closed run and says it carries another reason")
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

        #expect(single.status == .dismissed)
        #expect(run.status == .dismissed)
        #expect(run.showOutcome == .duplicate, "closed for what it is, not for the reason Dan picked")
        let said = feedback.message ?? "no message at all"
        #expect(said.contains("2 shows on Oct 2 are dismissed"), "counted both: \(said)")
        #expect(said.contains("closed as a duplicate"), "named the odd one out: \(said)")
    }
}
