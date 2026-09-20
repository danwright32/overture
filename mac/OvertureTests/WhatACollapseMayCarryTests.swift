import Testing
import Foundation
import SwiftData

// Two decisions Dan made on 2026-09-20 about what a collapse may carry, which are one question asked at
// the two ends of the app: the launch MERGE (#3135) and the ingest RE-KEY (#4074).
//
// #3135, the merge. A survivor never inherits a loser's `showOutcomeRaw`. Measured before deciding: the
// at-risk shape that issue describes (exactly one member carrying an outcome field, no member carrying a
// record) exists in ZERO groups of the live store, in every population. What DOES exist is members
// disagreeing: two future groups hold an undecided row beside dismissed ones, and two hold members that
// disagree about the reason itself. In every one of those the survivor is the undecided row, because
// `preferringASecondLook` hands it the group on purpose (#2001, Dan 2026-08-03: "I may have made a
// decision based on insufficient information. so give me another chance to look at it"). Carrying a
// dismissal onto that row would close the show again in the same breath the second look was granted.
//
// #4074, the re-key. Where more than one stored row sharing a concert id carries outreach history, the arm
// declines rather than picking one. A duplicate card staying up one more day is recoverable; a dismissal
// re-keyed onto a different show is the #797 failure and is not.
@MainActor
@Suite("What a collapse may carry (#3135, #4074)")
struct WhatACollapseMayCarryTests {

    private func container() throws -> ModelContainer {
        let schema = Schema([Prospect.self, Recipient.self])
        return try ModelContainer(for: schema,
                                  configurations: [ModelConfiguration(schema: schema,
                                                                      isStoredInMemoryOnly: true)])
    }

    @discardableResult
    private func row(_ ctx: ModelContext, _ title: String, opens: String, ingested: Double,
                     outcome: ShowOutcome? = nil, status: ReviewStatus = .new) -> Prospect {
        let p = Prospect(naturalKey: "\(title.lowercased())|\(opens)|asylum nyc",
                         groupName: title, discipline: "theater", venue: "Asylum NYC",
                         performanceDate: opens, sourceListingURL: nil,
                         priorRelationship: "none", production: "unknown", profile: "unknown",
                         coverage: "unknown", fitScore: 3, tier: "medium", fitReason: "",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         ingestedAt: Date(timeIntervalSince1970: ingested),
                         runEndDate: nil, partOfRelatedRun: false, runSourceURLs: [], runNights: [opens])
        p.showOutcomeRaw = outcome?.rawValue
        p.status = status
        ctx.insert(p)
        return p
    }

    // #3135. The survivor is the undecided row, and it must come out of the merge still undecided.
    @Test func theSurvivorNeverInheritsALosersDismissalReason() throws {
        let ctx = ModelContext(try container())
        let refused = row(ctx, "Gross Prophets", opens: "2026-10-02", ingested: 1_000,
                          outcome: .dontWantToShoot, status: .dismissed)
        let undecided = row(ctx, "Gross Prophets", opens: "2026-10-02", ingested: 2_000)
        SurvivorInheritance.carry(onto: undecided, from: [undecided, refused])

        #expect(undecided.showOutcomeRaw == nil,
                """
                the survivor came out of the merge carrying a refusal it never had, so #2001's second \
                look was granted and taken away in one write
                """)
        #expect(undecided.status == .new, "the survivor's own stage moved")
    }

    // The other direction, which is the one that makes the rule a rule rather than an accident of which
    // row won: a survivor that HAS an outcome keeps its own, and a loser's different one does not overwrite
    // it either.
    @Test func aSurvivorKeepsItsOwnOutcomeRatherThanALosers() throws {
        let ctx = ModelContext(try container())
        let survivor = row(ctx, "The Passion of Mr. Cardboard", opens: "2026-07-23", ingested: 2_000,
                           outcome: .tooSoon, status: .dismissed)
        let loser = row(ctx, "The Passion of Mr. Cardboard", opens: "2026-07-24", ingested: 1_000,
                        outcome: .wentBy, status: .dismissed)
        SurvivorInheritance.carry(onto: survivor, from: [survivor, loser])

        #expect(survivor.showOutcome == .tooSoon,
                "the survivor's own recorded reason was replaced by the deleted row's")
    }

    // The guard that makes the decision durable rather than a fact about today's code: no carry site may
    // start writing the three fields #3135 named. Derived from the source so a fourth carry site added
    // later is covered by it too (L96).
    @Test func noSurvivorCarrySiteWritesAnOutcomeField() {
        let carrySites = AppSourceWalk.appFiles().filter {
            $0.name.hasSuffix("SurvivorInheritance.swift") || $0.name.hasSuffix("NaturalKeyVenueMigration.swift")
        }
        #expect(carrySites.count == 2, "expected both carry sites, found \(carrySites.map(\.name))")
        for file in carrySites {
            for field in ["showOutcomeRaw =", "showOutcome =", "outreachStoodDownAt =",
                          "rejectedBookingIdsRaw ="] {
                #expect(!file.text.contains("survivor.\(field)"),
                        """
                        \(file.name) writes \(field) onto a survivor. #3135 decided that never happens: \
                        the survivor of a group with a disagreement is the UNDECIDED row, and moving a \
                        dismissal onto it undoes the second look #2001 exists to give.
                        """)
            }
        }
    }

    // #4074, driven through the real `ScoutService.apply` rather than the private arm, so it asserts what
    // the PIPELINE does (L3, and this milestone's own record of fixes aimed at functions that never run).

    private static let venue = "SoHo Playhouse"
    private static let seriesId = "1281174"

    private func ingestContext() throws -> ModelContext {
        let schema = Schema([Prospect.self, Recipient.self])
        return ModelContext(try ModelContainer(for: schema,
                            configurations: [ModelConfiguration(schema: schema,
                                                                isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func storedConcert(_ ctx: ModelContext, title: String, night: String,
                               runEnd: String? = nil, dismissedAs outcome: ShowOutcome?) -> Prospect {
        let key = Prospect.makeNaturalKey(groupName: title, performanceDate: night, venue: Self.venue)
        let p = Prospect(naturalKey: key, groupName: title, discipline: "theater", venue: Self.venue,
                         performanceDate: night, sourceListingURL: nil,
                         priorRelationship: "none", production: "unknown", profile: "unknown",
                         coverage: "unknown", fitScore: 3, tier: "medium", fitReason: "",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         runEndDate: runEnd, partOfRelatedRun: runEnd != nil, runSourceURLs: [],
                         runNights: [night])
        p.seriesId = Self.seriesId
        if let outcome {
            p.showOutcomeRaw = outcome.rawValue
            p.status = .dismissed
        }
        ctx.insert(p)
        return p
    }

    // THE CLAIM. Two stored rows share one concert id and BOTH carry history. The incoming listing must
    // re-key neither of them, because which one it took would be whichever the store returned first.
    @Test func anIngestWithTwoHistoryCarryingCandidatesReKeysNeither() throws {
        let ctx = try ingestContext()
        // Both runs must COVER the incoming night, or the arm's corroboration refuses them before the
        // pick is reached and this test would pass without the guard existing (L159).
        let first = storedConcert(ctx, title: "The Passion of Mr. Cardboard", night: "2026-11-03",
                                  runEnd: "2026-11-08", dismissedAs: .tooSoon)
        let second = storedConcert(ctx, title: "The Passion of Mr. Cardboard", night: "2026-11-04",
                                   runEnd: "2026-11-09", dismissedAs: .wentBy)
        let keysBefore = Set([first.naturalKey, second.naturalKey])
        try ctx.save()

        let incoming = ExtractedEvent(title: "The Passion of Mr. Cardboard", presenter: "SoHo Playhouse",
                                      venue: Self.venue, performanceDate: "2026-11-05",
                                      sourceUrl: "https://example.test/cardboard", seriesId: Self.seriesId)
        _ = ScoutService.apply(events: [incoming], clients: [], history: [], blocked: .empty,
                               today: "2026-10-01", sourceIds: ["sohoplayhouse-com"], into: ctx)
        try ctx.save()

        let rows = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(Set(rows.map(\.naturalKey)).isSuperset(of: keysBefore),
                """
                a stored row was re-keyed onto the incoming show even though two rows carried history: \
                \(rows.map(\.naturalKey).sorted())
                """)
        #expect(rows.count == 3,
                """
                the refusal leaves the incoming listing to insert its own row, which is the duplicate \
                card Dan can see and merge: got \(rows.count) row(s)
                """)
        #expect(rows.filter { $0.status == .dismissed }.count == 2,
                "neither dismissal may move onto the incoming show (#797)")
    }

    // WHAT MUST NOT BREAK. One candidate carrying history is not a conflict, and that row is exactly the
    // one the arm exists to recognise. A refusal here would mint a duplicate on every ordinary re-scout of
    // a show Dan has touched, which is the far commoner case (L104).
    @Test func aSingleHistoryCarryingCandidateIsStillReKeyed() throws {
        let ctx = try ingestContext()
        let only = storedConcert(ctx, title: "The Passion of Mr. Cardboard", night: "2026-11-03",
                                 runEnd: "2026-11-08", dismissedAs: .tooSoon)
        let keyBefore = only.naturalKey
        try ctx.save()

        let incoming = ExtractedEvent(title: "The Passion of Mr. Cardboard", presenter: "SoHo Playhouse",
                                      venue: Self.venue, performanceDate: "2026-11-05",
                                      sourceUrl: "https://example.test/cardboard", seriesId: Self.seriesId)
        _ = ScoutService.apply(events: [incoming], clients: [], history: [], blocked: .empty,
                               today: "2026-10-01", sourceIds: ["sohoplayhouse-com"], into: ctx)
        try ctx.save()

        let rows = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(rows.count == 1, "one show, one row: got \(rows.map(\.groupName))")
        #expect(rows.first?.naturalKey != keyBefore,
                "the single candidate must still be re-keyed onto the night the feed now lists")
    }
}
