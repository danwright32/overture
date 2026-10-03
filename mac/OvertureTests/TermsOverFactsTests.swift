import Testing
import Foundation
import SwiftData

// #4357 (plan v7 Phase 3, oracle part two on fixtures): each ported term answers the same over live models
// as over the same rows extracted to `RowFacts`. The live store and 4x corpus arm is
// `TermsOverFactsLiveStoreTests`; the per-term behaviour stays in each term's own suite, which also calls
// `TermsOverFacts.findings` on its own fixtures.
//
// The fixture is built so EVERY arm of the three terms is exercised, with a positive control for each
// (L159): a comparison that can never see a difference would pass a fixture where every term answers
// nothing, so the test first asserts each term DID answer something here.
@MainActor
@Suite("Every ported queue term answers the same over facts as over models (#4357)")
struct TermsOverFactsTests {
    private let asOf = "2026-09-20"

    private func context() throws -> ModelContext {
        // `OrgReachabilityAnswer` is named because the T5 tests insert one; leaving it to be reached through
        // the schema's relationships would make the fixture depend on how SwiftData resolves an unnamed type.
        ModelContext(try TestModelContainer.inMemory([Prospect.self, Recipient.self, OrgReachabilityAnswer.self]))
    }

    @discardableResult
    private func row(_ ctx: ModelContext, key: String, title: String, venue: String?, opens: String?,
                     runEnd: String? = nil, missed: Int = 0, listing: String? = nil,
                     scoutTitle: String? = nil, nights: [String]? = nil) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: title, discipline: "theater", venue: venue,
                         performanceDate: opens, sourceListingURL: listing, priorRelationship: "none",
                         production: "unknown", profile: "unknown", coverage: "unknown", fitScore: 3,
                         tier: "medium", fitReason: "", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil,
                         runEndDate: runEnd, partOfRelatedRun: runEnd != nil,
                         runSourceURLs: [], runNights: nights ?? opens.map { [$0] } ?? [])
        p.missedScoutCount = missed
        p.scoutGroupName = scoutTitle
        ctx.insert(p)
        return p
    }

    // Invented names throughout (L155, L222).
    private func seed(_ ctx: ModelContext) throws -> [Prospect] {
        // T3: a source-wide break of three flagged rows on one count, one of them with a live twin (T2).
        let hall = "Harrowgate Hall"
        row(ctx, key: "lantern|2026-10-03", title: "Lantern Parade", venue: hall, opens: "2026-10-03", missed: 4)
        row(ctx, key: "ninefold|2026-10-10", title: "Ninefold Quartet", venue: hall, opens: "2026-10-10", missed: 4)
        row(ctx, key: "copper|2026-10-17", title: "Copper Moth Revue", venue: hall, opens: "2026-10-17", missed: 4)
        row(ctx, key: "lantern live|2026-10-02", title: "Lantern Parade", venue: hall, opens: "2026-10-02",
            runEnd: "2026-10-06")
        // T2: a venueless flagged row and a venueless live twin, the `""` room both sides.
        row(ctx, key: "drift|2026-11-01", title: "Driftwood Choir", venue: nil, opens: "2026-11-01", missed: 3)
        row(ctx, key: "drift live|2026-11-01", title: "Driftwood Choir", venue: nil, opens: "2026-11-01")
        // T1: three rows of one show at one room, one renamed on its display title but not its scout one,
        // joined through overlapping nights; one stopped being listed, so the collapse fronts the others.
        row(ctx, key: "saltmarsh a", title: "Saltmarsh Suite", venue: "Quillon Room", opens: "2026-12-04",
            runEnd: "2026-12-06", nights: ["2026-12-04", "2026-12-05", "2026-12-06"])
        row(ctx, key: "saltmarsh b", title: "Saltmarsh Suite, Renamed By Hand", venue: "Quillon Room",
            opens: "2026-12-05", scoutTitle: "Saltmarsh Suite")
        row(ctx, key: "saltmarsh c", title: "Saltmarsh Suite", venue: "Quillon Room", opens: "2026-12-06",
            missed: 1)
        return try ctx.fetch(FetchDescriptor<Prospect>())
    }

    @Test func eachTermAnswersTheSameOverFactsAsOverModels() throws {
        let ctx = try context()
        let all = try seed(ctx)
        // Positive controls: every term answered something in this fixture.
        #expect(!ShowLink.group(all.map(ShowLink.Row.init)).isEmpty, "the fixture forms no ShowLink group")
        #expect(!ShowLink.collapse(all.map(ShowLink.Row.init), drawn: ["saltmarsh a", "saltmarsh b"]).hidden.isEmpty,
                "the fixture hides no row in the collapse")
        #expect(ContradictedCancellation.contradictedKeys(among: all).count == 2,
                "the fixture should contradict exactly the twinned hall row and the venueless one")
        #expect(FeedBreakEvent.events(among: all, asOf: asOf).first?.coveredByAnotherCard == 1,
                "the fixture's feed break should count one member covered by another card")

        let findings = TermsOverFacts.findings(all, asOf: asOf, drawn: ["saltmarsh a", "saltmarsh b"])
        #expect(findings.isEmpty, Comment(rawValue: findings.joined(separator: "\n")))
    }

    // The comparison can see a retained row that went stale: facts taken BEFORE a flagged row came back
    // into the feed disagree with the models after it, in T2, T3 and the collapse.
    @Test func theComparisonSeesARowThatChangedAfterItWasExtracted() throws {
        let ctx = try context()
        let all = try seed(ctx)
        let stale = all.map(RowFacts.extract)
        let flagged = try #require(all.first { $0.naturalKey == "lantern|2026-10-03" })
        flagged.missedScoutCount = 0
        let findings = TermsOverFacts.findings(all, facts: stale, asOf: asOf)
        #expect(findings.contains { $0.hasPrefix("ContradictedCancellation.contradictedKeys") },
                "a row that stopped being flagged was not seen by the contradiction comparison")
        #expect(findings.contains { $0.hasPrefix("FeedBreakEvent.events") },
                "a row that left a feed break was not seen by the event comparison")
        #expect(findings.contains { $0.hasPrefix("disappearedFromFeed") },
                "the flag itself was not compared")
        #expect(!findings.contains { $0.contains("Lantern") || $0.contains("Harrowgate") },
                "a finding named a title or a venue rather than the row's identifier")
    }

    // MARK: T4 and T5 (slice B)

    private let producer = "Wexcombe Touring Players"
    private let now = ISO8601DateFormatter().date(from: "2026-09-20T16:00:00Z") ?? Date(timeIntervalSince1970: 0)

    // On top of `seed`: a producer playing two rooms (so it qualifies and its shows inherit), one of its
    // shows carrying its own paid answer (so it must NOT inherit), a hall's own presenting brand, and a
    // presenter spelled exactly like a room. One fresh positive answer for the producer.
    private func seedProducers(_ ctx: ModelContext, _ all: [Prospect]) throws -> TermsOverFacts.Ledger {
        func row(_ key: String) throws -> Prospect { try #require(all.first { $0.naturalKey == key }) }
        try row("lantern|2026-10-03").presenter = producer      // Harrowgate Hall
        try row("saltmarsh a").presenter = producer             // Quillon Room
        let ownAnswer = try row("copper|2026-10-17")            // Harrowgate Hall, already checked itself
        ownAnswer.presenter = producer
        ownAnswer.reachabilityProbedAt = now.addingTimeInterval(-3600)
        try row("ninefold|2026-10-10").presenter = "Harrowgate Hall Presents"
        try row("saltmarsh c").presenter = "Quillon Room"
        let answer = OrgReachabilityAnswer(
            orgKey: try #require(OrgKey.stored(for: producer)), result: .emailFound,
            probedAt: now.addingTimeInterval(-86_400), sourceNaturalKey: "lantern|2026-10-03",
            sourceGroupName: "Lantern Parade", presenterName: producer,
            foundEmails: ["bookings@example.invalid"])
        ctx.insert(answer)
        return TermsOverFacts.Ledger(answers: [answer], now: now)
    }

    @Test func theProducerTablesAndTheLedgerAnswerTheSameOverFactsAsOverModels() throws {
        let ctx = try context()
        let all = try seed(ctx)
        let ledger = try seedProducers(ctx, all)
        // Positive controls: each arm of T4 and T5 answered something in this fixture (L159).
        let tables = QueueModel.ProducerTables(shows: all.map(ProducerGate.Show.init), overrides: .none)
        #expect(tables.corpus.distinctVenueCount(try #require(ProducerGate.key(producer))) == 2,
                "the producer should play two rooms")
        #expect(tables.venueBrands.contains("Harrowgate Hall Presents"), "the fixture holds no venue brand")
        #expect(tables.venueBrands.isRoomName("Quillon Room"), "the fixture holds no presenter spelled like a room")
        let inherited = QueueModel.inheritedAnswers(ledger.answers, corpus: all, overrides: .none,
                                                    refusals: .none, heldKeys: [], now: now)
        #expect(Set(inherited.keys) == ["lantern|2026-10-03", "saltmarsh a"],
                "the producer's two shows without their own answer should inherit, and only those")

        let findings = TermsOverFacts.findings(all, asOf: asOf, ledger: ledger)
        #expect(findings.isEmpty, Comment(rawValue: findings.joined(separator: "\n")))
    }

    // And the comparison can see a presenter that changed after the row was extracted: the projection, the
    // venue count and the inherited answer all move.
    @Test func theComparisonSeesAPresenterThatChangedAfterItWasExtracted() throws {
        let ctx = try context()
        let all = try seed(ctx)
        let ledger = try seedProducers(ctx, all)
        let stale = all.map(RowFacts.extract)
        try #require(all.first { $0.naturalKey == "saltmarsh a" }).presenter = "Somebody Else Entirely"
        let findings = TermsOverFacts.findings(all, facts: stale, asOf: asOf, ledger: ledger)
        #expect(findings.contains { $0.hasPrefix("ProducerGate.Show differs") },
                "a presenter that changed was not seen in the projection")
        #expect(findings.contains { $0.hasPrefix("ProducerTables.corpus venue count differs") },
                "the producer's lost room was not seen in the corpus")
        #expect(findings.contains { $0.hasPrefix("OrgAnswerLedger.inherited differs") },
                "the lost inheritance was not seen in the ledger")
        #expect(!findings.contains { $0.contains("Wexcombe") || $0.contains("Quillon") || $0.contains("Harrowgate") },
                "a finding named a presenter or a venue rather than the row's identifier")
    }

    // MARK: T6 (slice C)

    // On top of `seed`: the Lantern Parade run at Harrowgate Hall (closing 2026-10-06) tours on to another
    // room two nights later, inside the engagement gap, so its three rows form one cross-venue engagement.
    @Test func theEngagementLinkAnswersTheSameOverFactsAsOverModelsAndSeesAVenueThatMoved() throws {
        let ctx = try context()
        _ = try seed(ctx)
        row(ctx, key: "lantern tour|2026-10-08", title: "Lantern Parade", venue: "Quillon Room", opens: "2026-10-08")
        let all = try ctx.fetch(FetchDescriptor<Prospect>())
        // Positive control (L159): the touring row is linked to the hall's rows, and only through T6.
        let linked = EngagementLink.group(among: all)
        #expect(linked["lantern tour|2026-10-08"]?.count == 2,
                "the touring row should be linked to the hall's two Lantern Parade rows")
        #expect(TermsOverFacts.findings(all, asOf: asOf).isEmpty)

        // Facts taken before the touring row moved into the hall: the engagement no longer spans two rooms
        // over models, and the comparison has to say so by the row's identifier alone.
        let stale = all.map(RowFacts.extract)
        try #require(all.first { $0.naturalKey == "lantern tour|2026-10-08" }).venue = "Harrowgate Hall"
        let findings = TermsOverFacts.findings(all, facts: stale, asOf: asOf)
        #expect(findings.contains { $0.hasPrefix("EngagementLink.group members differ") },
                "a row that stopped touring was not seen by the engagement comparison")
        #expect(!findings.contains { $0.contains("Lantern") || $0.contains("Quillon") || $0.contains("Harrowgate") },
                "a finding named a title or a venue rather than the row's identifier")
    }

    // The three entry points `scope` calls hand the term EVERY row, in any order. Asked of every rotation,
    // so each row is last once and first once: a forwarder that dropped or skipped one would be invisible
    // to oracle part two (both arms share it) and to a live comparison whose dropped row joins nothing,
    // which is how a dropped last row survived the first mutation run of this slice.
    @Test func theEntryPointsHandTheTermEveryRowInAnyOrder() throws {
        let ctx = try context()
        _ = try seed(ctx)
        row(ctx, key: "lantern tour|2026-10-08", title: "Lantern Parade", venue: "Quillon Room", opens: "2026-10-08")
        let all = try ctx.fetch(FetchDescriptor<Prospect>()).sorted { $0.naturalKey < $1.naturalKey }
        let drawn: Set<String> = ["saltmarsh a", "saltmarsh b"]
        #expect(!EngagementLink.group(among: all).isEmpty && !ShowLink.group(among: all).isEmpty,
                "the fixture links nothing, so the rotations below compare empty tables")
        for start in all.indices {
            let rotated = Array(all[start...] + all[..<start])
            #expect(EngagementLink.group(among: rotated) == EngagementLink.group(rotated.map(EngagementLink.Row.init)),
                    "EngagementLink.group(among:) differs from the term with rotation \(start)")
            #expect(ShowLink.group(among: rotated) == ShowLink.group(rotated.map(ShowLink.Row.init)),
                    "ShowLink.group(among:) differs from the term with rotation \(start)")
            let viaEntry = ShowLink.collapse(among: rotated, drawn: drawn)
            let viaTerm = ShowLink.collapse(rotated.map(ShowLink.Row.init), drawn: drawn)
            #expect(viaEntry.fronts == viaTerm.fronts && viaEntry.hidden == viaTerm.hidden,
                    "ShowLink.collapse(among:) differs from the term with rotation \(start)")
            #expect(QueueModel.ProducerTables(rows: rotated, overrides: .none)
                        .corpus == QueueModel.ProducerTables(shows: rotated.map(ProducerGate.Show.init), overrides: .none).corpus,
                    "ProducerTables(rows:) differs from the shows form with rotation \(start)")
        }
    }
}
