import Testing
import Foundation
import SwiftData
@testable import Overture

// #42: surface what converts. The view groups contacted prospects by a chosen dimension
// (production / discipline / tier) and feeds them to the tested OutcomeStats tallies.
// This covers the prospect -> sample mapping that the view depends on.
@MainActor
@Suite("Outcome patterns")
struct OutcomePatternsTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func make(_ ctx: ModelContext, group: String, production: String, discipline: String,
                      tier: String, status: ReviewStatus, outcome: Outcome) -> Prospect {
        let p = Prospect(naturalKey: group, groupName: group, discipline: discipline, venue: "V",
                         performanceDate: "2026-07-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: production, profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: tier, fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: status)
        p.outcome = outcome
        // A contacted prospect is one whose pitch went out (#200): approved-in-these-tests means
        // sent, so it carries a send date. New prospects stay uncontacted (no date).
        // #963: a real send always stamps gmailMessageId alongside sentAt, so the fixture must too,
        // or it would no longer count once OutcomePatterns reads wasProvablyContacted.
        if status == .approved {
            p.sentAt = Date(timeIntervalSince1970: 1_000)
            p.gmailMessageId = "msg-\(group)"
        }
        ctx.insert(p)
        return p
    }

    // #1670 / #1648 Phase A4: the tier a pitch went out under is the only tier this report can honestly
    // group by. The live tier can move after the send (a genre correction, a performer match, and from
    // #1648 onward a contact check), so reading it here buckets a show under a tier it did not have when
    // Dan actually pitched it, and the report silently mixes two scoring bases with nothing marking the
    // change. The at-send tier is already frozen on the row; it was simply never read.
    @Test func groupsSentShowsByTheTierTheyWentOutUnderNotTheTierTheyHoldNow() throws {
        let ctx = ModelContext(try container())
        let p = make(ctx, group: "A", production: "self", discipline: "dance", tier: "high",
                     status: .approved, outcome: .booked)
        // It went out as a high fit, and something later moved it down.
        p.tierAtSend = "high"
        p.tier = "longshot"

        let all = try ctx.fetch(FetchDescriptor<Prospect>())
        let names = OutcomePatterns.rankedTallies(from: all, by: .tier).map(\.name)
        #expect(names == ["high"])
    }

    @Test func mapsProspectsToSamplesByChosenDimension() throws {
        let ctx = ModelContext(try container())
        _ = make(ctx, group: "A", production: "self", discipline: "choral", tier: "high",
                 status: .approved, outcome: .booked)
        _ = make(ctx, group: "B", production: "agency", discipline: "dance", tier: "longshot",
                 status: .new, outcome: .noResponse)
        let all = try ctx.fetch(FetchDescriptor<Prospect>())

        let byProduction = OutcomePatterns.samples(from: all, by: .production)
        #expect(Set(byProduction.map(\.dimension)) == ["self", "agency"])
        // wasContacted reflects approved/sent; the approved one counts, the .new one does not.
        #expect(byProduction.filter(\.wasContacted).count == 1)

        let byDiscipline = OutcomePatterns.samples(from: all, by: .discipline)
        #expect(Set(byDiscipline.map(\.dimension)) == ["choral", "dance"])

        // Fed through the tested tally, the self/contacted/booked one yields a booking.
        let tallies = OutcomeStats.tallyByDimension(byProduction)
        #expect(tallies["self"]?.booked == 1)
    }

    // #963: a sent timestamp is not proof of a real send (#378's lesson, extended past the Reached-out
    // queue). Every genuine send stamps a Gmail message id alongside sentAt; a staged/corrupt record with
    // only the timestamp must not count as contacted in the outreach stats either, or a future bug that
    // sets sentAt without sending would silently inflate (or deflate) a booking rate Dan reads as real.
    @Test func aSentTimestampWithoutAGmailMessageIdDoesNotCountAsContacted() throws {
        let ctx = ModelContext(try container())
        let p = Prospect(naturalKey: "k", groupName: "k", discipline: "music", venue: "V",
                         performanceDate: "2026-07-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .approved)
        p.sentAt = Date(timeIntervalSince1970: 1_000)   // a timestamp with no gmailMessageId proof
        ctx.insert(p)

        let samples = OutcomePatterns.samples(from: [p], by: .production)
        #expect(samples.allSatisfy { !$0.wasContacted })
    }

    // #4: the insight view also breaks outcomes down by coverage, profile, and venue, so Dan can
    // see the full set of factors that predict bookings before adjusting weights by hand.
    private func sent(_ ctx: ModelContext, key: String, profile: String, coverage: String, venue: String?) {
        let p = Prospect(naturalKey: key, groupName: key, discipline: "music", venue: venue,
                         performanceDate: "2026-07-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: profile,
                         coverage: coverage, fitScore: 5, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .approved)
        p.sentAt = Date(timeIntervalSince1970: 1_000)
        p.gmailMessageId = "msg-\(key)"
        ctx.insert(p)
    }

    @Test func groupsByCoverageProfileAndVenue() throws {
        let ctx = ModelContext(try container())
        sent(ctx, key: "a", profile: "strong", coverage: "likely_uncovered", venue: "Carnegie Hall")
        sent(ctx, key: "b", profile: "weak", coverage: "likely_covered", venue: "Roulette")
        let all = try ctx.fetch(FetchDescriptor<Prospect>())

        #expect(Set(OutcomePatterns.samples(from: all, by: .coverage).map(\.dimension)) == ["likely_uncovered", "likely_covered"])
        #expect(Set(OutcomePatterns.samples(from: all, by: .profile).map(\.dimension)) == ["strong", "weak"])
        #expect(Set(OutcomePatterns.samples(from: all, by: .venue).map(\.dimension)) == ["Carnegie Hall", "Roulette"])
    }

    @Test func venueDimensionHasAFallbackWhenMissing() throws {
        let ctx = ModelContext(try container())
        sent(ctx, key: "novenue", profile: "strong", coverage: "unknown", venue: nil)
        let all = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(OutcomePatterns.samples(from: all, by: .venue).map(\.dimension) == ["No venue"])
    }

    // #212: the drill-down behind the "auto-detected" count lists only the auto-detected
    // bookings for the tapped segment (not manual, not other segments, not unbooked).
    @Test func autoBookedListsOnlyAutoBookingsForThatSegment() throws {
        let ctx = ModelContext(try container())
        let a = make(ctx, group: "Choir A", production: "self", discipline: "choral", tier: "high",
                     status: .approved, outcome: .booked)
        a.outcomeSourceRaw = OutcomeSource.auto.rawValue
        let m = make(ctx, group: "Choir M", production: "self", discipline: "choral", tier: "high",
                     status: .approved, outcome: .booked)
        m.outcomeSourceRaw = OutcomeSource.manual.rawValue
        let other = make(ctx, group: "Band X", production: "agency", discipline: "band", tier: "mid",
                         status: .approved, outcome: .booked)
        other.outcomeSourceRaw = OutcomeSource.auto.rawValue
        _ = make(ctx, group: "Choir N", production: "self", discipline: "choral", tier: "high",
                 status: .approved, outcome: .noResponse)
        let all = try ctx.fetch(FetchDescriptor<Prospect>())

        let entries = OutcomePatterns.autoBookedBookings(from: all, by: .production, value: "self")
        #expect(entries.map(\.groupName) == ["Choir A"])
        #expect(entries.first?.venue == "V")
    }

    @Test func flagsLowSampleGroupsSoEarlyNoiseIsntReadAsAPattern() {
        // Under the threshold of meaningful contacts, a rate is noise (e.g. 1 of 1 = 100%).
        #expect(OutcomePatterns.isLowSample(OutcomeTally(contacted: 1, replied: 0, booked: 1, lost: 0, noResponse: 0)))
        #expect(OutcomePatterns.isLowSample(OutcomeTally(contacted: 3, replied: 1, booked: 0, lost: 0, noResponse: 2)))
        #expect(OutcomePatterns.isLowSample(OutcomeTally(contacted: 6, replied: 1, booked: 1, lost: 0, noResponse: 4)) == false)
    }

    @Test func rankedTalliesDropUncontactedGroupsAndSortByBookings() throws {
        let ctx = ModelContext(try container())
        // "self": 1 booked of 1 contacted. "agency": never contacted (.new). "band": contacted, no booking.
        _ = make(ctx, group: "A", production: "self", discipline: "choral", tier: "high", status: .approved, outcome: .booked)
        _ = make(ctx, group: "B", production: "agency", discipline: "dance", tier: "longshot", status: .new, outcome: .noResponse)
        _ = make(ctx, group: "C", production: "band", discipline: "band", tier: "mid", status: .approved, outcome: .noResponse)
        let all = try ctx.fetch(FetchDescriptor<Prospect>())

        let ranked = OutcomePatterns.rankedTallies(from: all, by: .production)
        #expect(ranked.map(\.name) == ["self", "band"])     // agency dropped (0 contacted), self first (booked)
        #expect(ranked.first?.tally.booked == 1)
    }

    @Test func aRepliedContactCountsAsRepliedInTheStats() throws {
        // Phase F: with the A3 rollup gone, the replied tally derives from a contact replying, not the
        // lead outcome (which stays noResponse).
        let ctx = ModelContext(try container())
        let p = make(ctx, group: "R", production: "self", discipline: "choral", tier: "mid",
                     status: .approved, outcome: .noResponse)
        let r = Recipient(id: "c@e.com", email: "c@e.com", provenance: .act)
        r.sendState = .sent
        r.replied = true
        p.setRecipients([r])
        let samples = OutcomePatterns.samples(from: try ctx.fetch(FetchDescriptor<Prospect>()), by: .production)
        #expect(samples.first?.outcome == .replied)
    }
}
