import Testing
import Foundation
import SwiftData

// #4406: every pass that takes a FIRST match from the show table answers the same whatever order the table
// comes back in.
//
// #4397 measured why that matters: a fetch with no sort has no order to promise (L343), and SwiftData's is
// not even repeatable. On a context holding any unsaved change it came back in a different order on each of
// six opens of one store file, so a reader keeping the first (or the last) of two rows that tie picked a
// different row from run to run. #4397 fixed the scout landing and `LocalHistory`; these are the other
// readers whose result depends on order: a survivor chosen among rows tied on `ingestedAt`, a dictionary
// keeping the last writer per organisation, a dedupe keeping the first of two tied openers, a representative
// chosen per producer, and the shared rows every reconcile pass reads.
//
// The test for each is the same shape: the SAME rows written into two stores in opposite orders, so the bare
// table read hands the pass two different orders (asserted first, or the comparison could not see anything,
// L159), and the pass must leave the same answer in both. `UnsortedProspectFetchGuardTests` is the other
// half: it finds every unsorted read in the app and refuses one nobody has classified.
@MainActor
@Suite("A pass taking a first match from the show table does not depend on read order (#4406)")
final class ShowTableReadOrderTests {

    private let sandboxes = TemporarySandboxes()

    private static let older = Date(timeIntervalSince1970: 1_750_000_000)

    private static func show(_ key: String, group: String = "Show", venue: String = "Larkspur Hall",
                             date: String = "2026-11-04", url: String? = nil,
                             ingestedAt: Date = older) -> Prospect {
        Prospect(naturalKey: key, groupName: group, discipline: "music", venue: venue,
                 performanceDate: date, sourceListingURL: url,
                 priorRelationship: "none", production: "self", profile: "strong",
                 coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                 matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                 status: .new, ingestedAt: ingestedAt)
    }

    // The same rows, built fresh for each store, written in the order given and in the reverse of it. Saved
    // one at a time, as rows arrive in the real store: written in one save, the two stores read back in the
    // same order whichever way round they were inserted, and the comparison below saw nothing.
    private func twoStores(_ rows: [() -> Prospect]) throws -> (forward: ModelContext, reversed: ModelContext) {
        func store(_ ordered: [() -> Prospect]) throws -> ModelContext {
            let ctx = ModelContext(try TestModelContainer.inMemory(AppSchema.models))
            for make in ordered {
                ctx.insert(make())
                try ctx.save()
            }
            return ctx
        }
        let forward = try store(rows)
        let reversed = try store(rows.reversed())
        let forwardRead = try forward.fetch(FetchDescriptor<Prospect>()).map(\.naturalKey)
        let reversedRead = try reversed.fetch(FetchDescriptor<Prospect>()).map(\.naturalKey)
        #expect(forwardRead != reversedRead, Comment(rawValue:
            "both stores read back in one order, so this cannot see a pass depending on it (L159): \(forwardRead)"))
        return (forward, reversed)
    }

    // MARK: the shared rows every reconcile pass reads

    @Test func theReconcileTicksRowsAreInKeyOrderWhateverOrderTheyWereWritten() throws {
        let keys = ["k-03", "k-01", "k-02"]
        let stores = try twoStores(keys.map { key in { Self.show(key) } })
        for ctx in [stores.forward, stores.reversed] {
            let held = StoreRows.fetch(from: ctx).prospects.map(\.naturalKey)
            #expect(held == ["k-01", "k-02", "k-03"], Comment(rawValue:
                "the tick's rows are in the read's order, not key order: \(held)"))
        }
    }

    @Test func theBackgroundDueReadingNamesBookedShowsInKeyOrder() async throws {
        let keys = ["k-03", "k-01", "k-02"]
        let stores = try twoStores(keys.map { key in {
            let p = Self.show(key, group: "Show \(key)")
            p.outcome = .booked
            return p
        } })
        for ctx in [stores.forward, stores.reversed] {
            let reading = await DueReading.readInBackground(container: ctx.container, now: Self.older,
                                                            replyRunAlive: false)
            #expect(reading.booked.map(\.key) == ["k-01", "k-02", "k-03"], Comment(rawValue:
                "the away alert's booked names are in the read's order: \(reading.booked.map(\.key))"))
        }
    }

    // MARK: a dictionary keeping the last writer per organisation

    @Test func anOrganisationsAnswerNamesTheSameShowWhateverOrderTheShowsWereRead() throws {
        let keys = ["org-show-a", "org-show-b"]
        let stores = try twoStores(keys.map { key in {
            let p = Self.show(key, group: "Group \(key)")
            p.presenter = "Tenet Vocal Artists"
            return p
        } })
        var sources: [String] = []
        for ctx in [stores.forward, stores.reversed] {
            for p in try ctx.fetch(FetchDescriptor<Prospect>()) {
                p.setRecipients([Recipient(id: "hello@tenet.example", email: "hello@tenet.example",
                                           name: "Someone", provenance: .presenter)])
            }
            try ctx.save()
            OrgAnswerRecording.record(answeredKeys: Set(keys), in: ctx, now: Self.older)
            let answer = try #require(try ctx.fetch(FetchDescriptor<OrgReachabilityAnswer>()).first)
            sources.append(answer.sourceNaturalKey)
        }
        #expect(sources[0] == sources[1], Comment(rawValue:
            "the organisation's answer names a different show depending on read order: \(sources)"))
    }

    // MARK: a dedupe or a cap over rows that tie

    @Test func twoOpenersTiedOnTheirDateKeepTheSameSurvivorWhateverTheReadOrder() throws {
        let keys = ["opener-a", "opener-b"]
        let stores = try twoStores(keys.map { key in {
            let p = Self.show(key)
            p.originalDraftBody = "I photograph performing arts in New York. Rest of the note."
            p.sentAt = Self.older
            return p
        } })
        var survivors: [String] = []
        for ctx in [stores.forward, stores.reversed] {
            let url = try sandboxes.make(named: "openers").appendingPathComponent("recent-openers.json")
            try RecentOpenersService.export(from: ctx, generatedAt: "2026-10-01T00:00:00Z", url: url)
            let decoded = try JSONDecoder().decode(RecentOpeners.self, from: Data(contentsOf: url))
            survivors.append(decoded.openers.map(\.naturalKey).joined(separator: ","))
        }
        #expect(survivors[0] == survivors[1], Comment(rawValue:
            "the opener kept from two tied copies depends on read order: \(survivors)"))
    }

    @Test func voicePairsTiedOnRankAndDateKeepOneOrderWhateverTheReadOrder() throws {
        let keys = ["voice-a", "voice-b", "voice-c"]
        let stores = try twoStores(keys.map { key in {
            let p = Self.show(key)
            p.originalDraftBody = "Hello there, I photograph performing arts and would love to cover the show."
            p.sentBody = "Completely rewritten by hand: a different sentence about a different evening entirely."
            p.sentAt = Self.older
            return p
        } })
        var orders: [[String]] = []
        for ctx in [stores.forward, stores.reversed] {
            let url = try sandboxes.make(named: "voice").appendingPathComponent("voice-feedback.json")
            try VoiceFeedbackService.export(from: ctx, generatedAt: "2026-10-01T00:00:00Z", url: url)
            let decoded = try JSONDecoder().decode(VoiceFeedback.self, from: Data(contentsOf: url))
            orders.append(decoded.pairs.map(\.naturalKey))
        }
        #expect(orders[0].count == keys.count, Comment(rawValue:
            "the fixture's edits were not high signal, so no pair was exported to order: \(orders[0])"))
        #expect(orders[0] == orders[1], Comment(rawValue:
            "the voice pairs exported depend on read order: \(orders)"))
    }

    // MARK: a representative chosen per producer

    @Test func aProducersRepresentativeIsTheSameShowWhateverTheReadOrder() throws {
        let rows: [(key: String, venue: String)] = [("probe-a", "Larkspur Hall"), ("probe-b", "Zankel Hall")]
        let stores = try twoStores(rows.map { row in {
            let p = Self.show(row.key, group: "Group \(row.key)", venue: row.venue)
            p.presenter = "Tenet Vocal Artists"
            return p
        } })
        var researched: [[String]] = []
        for ctx in [stores.forward, stores.reversed] {
            let queue = PrepQueueService.buildProbeQueue(from: ctx, generatedAt: "now",
                                                         keys: Set(rows.map(\.key)))
            researched.append(queue.items.map(\.naturalKey))
        }
        #expect(researched[0].count == 1, Comment(rawValue:
            "the two shows were not grouped under one producer, so there was no representative to choose: \(researched[0])"))
        #expect(researched[0] == researched[1], Comment(rawValue:
            "the show researched for the producer depends on read order: \(researched)"))
    }

    // MARK: a survivor chosen among rows tied on ingestedAt

    private static func survivorSnapshot(_ ctx: ModelContext) throws -> [String] {
        try ctx.fetch(FetchDescriptor<Prospect>())
            .map { "\($0.naturalKey) \($0.groupName) \($0.venue ?? "") \($0.sourceListingURL ?? "") \($0.runSourceURLs)" }
            .sorted()
    }

    // Already true before #4406, and kept as the evidence for classifying this pass as order free:
    // `groupsOfOneShow` orders every group by `ingestedAt` then natural key (#3780) before any rung reads it.
    @Test func twoPristineDuplicatesTiedOnIngestedAtLeaveTheSameSurvivorWhateverTheReadOrder() throws {
        let group = "GATA Jazz Trio", date = "2026-07-18"
        let folded = Prospect.makeNaturalKey(groupName: group, performanceDate: date, venue: "The Cutting Room")
        let stores = try twoStores([
            { Self.show(folded, group: group, venue: "The Cutting Room", date: date,
                        url: "https://example.test/plain") },
            { Self.show("legacy-address-key", group: group,
                        venue: "The Cutting Room, 44 East 32nd Street, New York, NY", date: date,
                        url: "https://example.test/address") },
        ])
        var outcomes: [[String]] = []
        for ctx in [stores.forward, stores.reversed] {
            let summary = NaturalKeyVenueMigration.run(in: ctx)
            try ctx.save()
            #expect(summary.duplicatesDeleted == 1, "the pair did not merge, so no survivor was chosen")
            outcomes.append(try Self.survivorSnapshot(ctx))
        }
        #expect(outcomes[0] == outcomes[1], Comment(rawValue:
            "which duplicate survived depends on read order: \(outcomes)"))
    }

    @Test func aDriftedRunTiedOnIngestedAtLeavesTheSameSurvivorWhateverTheReadOrder() throws {
        func drifted(_ key: String, opens: String, url: String) -> () -> Prospect {
            {
                let p = Prospect(naturalKey: key, groupName: "Autumn Series", discipline: "theater",
                                 venue: "Weill Recital Hall", performanceDate: opens, sourceListingURL: url,
                                 priorRelationship: "none", production: "unknown", profile: "unknown",
                                 coverage: "unknown", fitScore: 3, tier: "medium", fitReason: "",
                                 matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                                 ingestedAt: Self.older, runEndDate: "2026-11-06", partOfRelatedRun: true,
                                 runSourceURLs: [url], runNights: [opens])
                p.seriesId = "prod-1"
                return p
            }
        }
        let stores = try twoStores([
            drifted("autumn a|2026-11-04|weill recital hall", opens: "2026-11-04", url: "https://example.test/a"),
            drifted("autumn b|2026-11-05|weill recital hall", opens: "2026-11-05", url: "https://example.test/b"),
        ])
        var outcomes: [[String]] = []
        for ctx in [stores.forward, stores.reversed] {
            DriftedRunMerge.run(in: ctx)
            try ctx.save()
            let survivors = try Self.survivorSnapshot(ctx)
            #expect(survivors.count == 1, Comment(rawValue: "the drifted pair did not merge: \(survivors)"))
            outcomes.append(survivors)
        }
        #expect(outcomes[0] == outcomes[1], Comment(rawValue:
            "which night of the drifted run survived depends on read order: \(outcomes)"))
    }

    @Test func twoTitleVariantsTiedOnIngestedAtLeaveTheSameSurvivorWhateverTheReadOrder() throws {
        let stores = try twoStores([
            { Self.show("autumn series|2026-11-04|weill recital hall", group: "Autumn Series",
                        venue: "Weill Recital Hall", url: "https://example.test/plain") },
            { Self.show("autumn series gala|2026-11-04|weill recital hall", group: "Autumn Series Gala",
                        venue: "Weill Recital Hall", url: "https://example.test/gala") },
        ])
        var outcomes: [[String]] = []
        for ctx in [stores.forward, stores.reversed] {
            SameNightTitleVariantMerge.run(in: ctx)
            try ctx.save()
            let survivors = try Self.survivorSnapshot(ctx)
            #expect(survivors.count == 1, Comment(rawValue: "the title variants did not merge: \(survivors)"))
            outcomes.append(survivors)
        }
        #expect(outcomes[0] == outcomes[1], Comment(rawValue:
            "which title variant survived depends on read order: \(outcomes)"))
    }
}
