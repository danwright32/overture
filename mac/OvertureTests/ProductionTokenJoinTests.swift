import Testing
import Foundation
import SwiftData

// #4029: two rows of ONE production that share the venue's own opaque production token, and share no
// URL at all, must be recognised as one show at ingest.
//
// `ShowLink` already reads that token and groups on it for DISPLAY, because it was measured to be stable
// across every night of a run and to carry none of the title (`ShowLink.swift`, `ProductionToken`). No
// arm of the ingest match chain reads it, so the app tells Dan two rows are one show while still minting
// the second one.
//
// MEASURED ON THE LIVE STORE 2026-09-20, over a WAL inclusive clone of 1,275 rows. 230 rows carry a
// venuetix token and 228 tokens are distinct, so exactly two pairs share one while holding disjoint URL
// sets. Both pairs carry identical folded titles and folded venues, and ShowLink's poisoned token rule
// (a token appearing under more than one folded title at one venue) discards NOTHING over the whole
// store. That is the licence for letting this re-key a row: the would-have-matched report is two pairs
// and both are one production.
//
// | show | pks (first seen) | shared token |
// | Nihao Broadway | 397 (2026-07-22), 1114 (2026-08-19) | zGbL9oImamvWwHF3ti5i |
// | Operation Mincemeat: Mission Recast | 491 (2026-07-22), 1371 (2026-09-03) | GWKuL2pmNJBPIkIkHB0h |
//
// The fixture is the Nihao pair, because it is the one that already cost something: pk 397 was dismissed
// `pitchingOtherShows` for its night, the second row was minted, and Dan PITCHED it (pk 1114, contacted).
//
// It drives the real ingest (`ScoutService.apply`) rather than any arm directly, for the reason
// `RunURLRecognitionTests` gives: what is being asked is what the PIPELINE does. #3766 is the standing
// warning against asking it of an arm, since `upsertTarget` short circuits on `storedByKey` and an arm
// below it never runs when the incoming row holds its own key.
@MainActor
@Suite("A shared production token is one show at ingest (#4029)")
struct ProductionTokenJoinTests {

    private static let venue = "The Green Room 42"
    private static let token = "zGbL9oImamvWwHF3ti5i"
    private static let host = "https://thegreenroom42.venuetix.com/showdetails/"

    // The two rows exactly as the live store holds them: one token, two per performance segments, and a
    // trailing exclamation mark on the later title that the natural key's own fold removes.
    private static let storedTitle = "Nihao Broadway"
    private static let storedNight = "2026-09-11"
    private static let storedURL = host + token + "/5oHZXAxwUToPOZdBXMNY"

    private static let incomingTitle = "Nihao Broadway!"
    private static let incomingNight = "2026-09-29"
    private static let incomingURL = host + token + "/zJ35Qa2LPGbqLyShab5f"

    private func container() throws -> ModelContainer {
        let schema = Schema([Prospect.self, Recipient.self])
        return try ModelContainer(for: schema,
                                  configurations: [ModelConfiguration(schema: schema,
                                                                      isStoredInMemoryOnly: true)])
    }

    @discardableResult
    private func storedRow(in context: ModelContext) -> Prospect {
        let key = Prospect.makeNaturalKey(groupName: Self.storedTitle,
                                          performanceDate: Self.storedNight,
                                          venue: Self.venue)
        let p = Prospect(naturalKey: key, groupName: Self.storedTitle, discipline: "music",
                         venue: Self.venue, performanceDate: Self.storedNight,
                         sourceListingURL: Self.storedURL, priorRelationship: "none",
                         production: "unknown", profile: "unknown", coverage: "unknown",
                         fitScore: 3, tier: "medium", fitReason: "",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         runEndDate: nil, partOfRelatedRun: false, runSourceURLs: [Self.storedURL],
                         runNights: [Self.storedNight])
        context.insert(p)
        return p
    }

    private func incomingEvents() -> [ExtractedEvent] {
        [ExtractedEvent(title: Self.incomingTitle, presenter: "The Green Room 42", venue: Self.venue,
                        performanceDate: Self.incomingNight, sourceUrl: Self.incomingURL)]
    }

    private func ingest(into ctx: ModelContext) {
        _ = ScoutService.apply(events: incomingEvents(), clients: [], history: [],
                               blocked: .empty, today: "2026-08-19",
                               sourceIds: ["thegreenroom42-venuetix-com"], into: ctx)
    }

    // THE CLAIM.
    @Test func aNightSharingOnlyTheProductionTokenDoesNotMintASecondRow() throws {
        let ctx = ModelContext(try container())
        storedRow(in: ctx)
        try ctx.save()

        ingest(into: ctx)
        try ctx.save()

        let rows = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(rows.count == 1,
                """
                one production is stored \(rows.count) times though both rows carry the venue's own \
                production token \(Self.token) (#4029): \(rows.map(\.naturalKey).sorted())
                """)
    }

    // The join must be ADDITIVE on nights. `apply` REPLACES the stored night set
    // (`ScoutService.swift`, DroppedNight.keeping), which is right for an ordinary update, where the feed
    // is authoritative and a cancelled night must drop off. It is wrong here: the incoming row is one
    // night of a production, not the whole run, so replacing would DISCARD 2026-09-11 while it is still
    // in the future. That is the half of this that destroys data rather than merely duplicating it.
    @Test func theJoinedRowKeepsBothNights() throws {
        let ctx = ModelContext(try container())
        storedRow(in: ctx)
        try ctx.save()

        ingest(into: ctx)
        try ctx.save()

        // Asked of the SURVIVING row rather than of the union over every row, because the union is
        // satisfied by the defect: two rows each holding one night carry both nights between them, so
        // that form of the question passes before this is built and proves nothing (L159).
        let rows = try ctx.fetch(FetchDescriptor<Prospect>())
        let nights = Set(rows.first?.runNights ?? [])
        #expect(nights == [Self.storedNight, Self.incomingNight],
                """
                the surviving row does not hold both nights, so the join dropped one that is still in \
                the future: \(nights.sorted()) over \(rows.count) row(s)
                """)
    }

    // L159: the precondition, asserted separately, so a pass above cannot come from a fixture in which
    // the two rows shared a URL after all and an arm that already exists did the work.
    @Test func theFixtureSharesTheTokenAndNoURL() {
        #expect(Self.storedURL != Self.incomingURL)
        #expect(Set([Self.storedURL]).isDisjoint(with: Set([Self.incomingURL])),
                "the fixture must share NO url, or matchByAnyRunURL explains the pass")
        #expect(Self.storedURL.contains(Self.token) && Self.incomingURL.contains(Self.token),
                "the fixture must share the production token, or there is nothing new to read")
    }

    // The #3766 trap, asserted rather than assumed: `upsertTarget` short circuits on `storedByKey`, so an
    // arm below it never runs when the incoming row holds its own key. If these two keys were equal the
    // claim above would pass for a reason that has nothing to do with any token.
    @Test func theTwoRowsReallyHoldDifferentNaturalKeys() {
        let stored = Prospect.makeNaturalKey(groupName: Self.storedTitle,
                                             performanceDate: Self.storedNight, venue: Self.venue)
        let incoming = Prospect.makeNaturalKey(groupName: Self.incomingTitle,
                                               performanceDate: Self.incomingNight, venue: Self.venue)
        #expect(stored != incoming,
                "the keys are equal, so storedByKey answers and no token arm is reached: \(stored)")
    }

    // MARK: what the join does to a decision Dan already made (#4052)

    private func storedRow(in context: ModelContext, dismissedFor ending: ShowOutcome,
                           nights: [String] = [ProductionTokenJoinTests.storedNight]) -> Prospect {
        let p = storedRow(in: context)
        p.runNights = nights
        p.performanceDate = nights.first
        p.runEndDate = nights.count > 1 ? nights.last : nil
        p.naturalKey = Prospect.makeNaturalKey(groupName: p.groupName,
                                               performanceDate: p.performanceDate, venue: p.venue)
        p.markDismissed(reason: ending)
        return p
    }

    // THE CLAIM #4052 exists for, and the live case: a night Dan spent on another show does not decide
    // the nights he has not spent.
    @Test func aNightSpecificDismissalIsReopenedByTheNewNight() throws {
        let ctx = ModelContext(try container())
        storedRow(in: ctx, dismissedFor: .pitchingOtherShows)
        try ctx.save()

        ingest(into: ctx)
        try ctx.save()

        let rows = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(rows.count == 1)
        #expect(rows.first?.status == .new,
                "a show dismissed for the night it clashed with stayed dismissed when a free night arrived")
        #expect(rows.first?.showOutcome == nil, "the ending outlived the dismissal it belonged to")
        #expect(rows.first?.dismissedAt == nil, "a live show keeps an exit date, so it counts as a drop-off")
    }

    // The other half of Dan's rule, and the one that must never soften: a judgement about the show is not
    // reconsidered because the show plays again.
    @Test func aJudgementAboutTheShowSurvivesTheNewNight() throws {
        let ctx = ModelContext(try container())
        storedRow(in: ctx, dismissedFor: .dontWantToShoot)
        try ctx.save()

        ingest(into: ctx)
        try ctx.save()

        let rows = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(rows.count == 1)
        #expect(rows.first?.status == .dismissed,
                "a show Dan does not want to shoot came back because it plays another night")
        #expect(rows.first?.showOutcome == .dontWantToShoot, "the ending was cleared with the dismissal")
    }

    // A re-read that brings no night the row does not already hold must change nothing. Without this the
    // arm would undo a decision on every sweep, which is the mirror of L92: a decision undone by an event
    // that did not happen. The key still differs, so the token arm is genuinely the one answering.
    @Test func aReReadCarryingNoNewNightDoesNotReopenAnything() throws {
        let ctx = ModelContext(try container())
        storedRow(in: ctx, dismissedFor: .pitchingOtherShows,
                  nights: [Self.storedNight, Self.incomingNight])
        try ctx.save()

        ingest(into: ctx)
        try ctx.save()

        let rows = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(rows.count == 1)
        #expect(rows.first?.status == .dismissed,
                "a sweep that told the row nothing new undid a decision Dan had made")
    }
}
