import Testing
import Foundation
import SwiftData

// #1720 (milestone 34 Phase 3): the house list actually reaching the file the Prep run reads. The gate
// computing it correctly (ProducerHouseListTests) and the queue carrying it are two separate claims, and
// #1679 is this repo's proof that the second one can silently fail while the first stays green: the
// promotion override had a set for months and every call site passed the empty default, so the human half
// of the decision looked shipped while doing nothing.
@MainActor
@Suite("The house list the Prep run is handed (#1720)")
struct PrepQueueHouseListTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(
            for: Schema([Prospect.self, PromotedProducer.self, DemotedHouse.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    @discardableResult
    private func insert(_ ctx: ModelContext, group: String, presenter: String?, venue: String,
                        status: ReviewStatus = .queued) -> Prospect {
        let key = Prospect.makeNaturalKey(groupName: group, performanceDate: "2026-09-11", venue: venue)
        let p = Prospect(naturalKey: key, groupName: group, discipline: "theater", venue: venue,
                         performanceDate: "2026-09-11", sourceListingURL: "https://src", priorRelationship: "none", production: "self",
                         profile: "strong", coverage: "likely_uncovered", fitScore: 7, tier: "high",
                         fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil, status: status)
        p.presenter = presenter
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    // The list is one answer about the whole store, so it is judged against the whole store. Judged
    // against the run's own items instead, a single-show run would name almost no houses and the run
    // would go hunting the building's own inbox for want of being told (the same reasoning
    // buildProbeQueue already states for the producer grouping).
    @Test func theListIsBuiltFromTheWholeStoreNotJustTheRunsOwnShows() throws {
        let ctx = ModelContext(try container())
        let selected = insert(ctx, group: "everyday royalty", presenter: "Abrons Arts Center",
                              venue: "Abrons Arts Center")
        // A row that never reaches this run: already dismissed, and at a different house.
        insert(ctx, group: "Something Else", presenter: "Merkin Hall", venue: "Merkin Hall",
               status: .dismissed)

        let queue = PrepQueueService.buildQueue(from: ctx, generatedAt: "now",
                                                includedKeys: [selected.naturalKey])
        #expect(queue.items.count == 1)
        let keys = Set((queue.houses ?? []).map(\.key))
        #expect(keys.contains("abrons arts center"))
        #expect(keys.contains("merkin hall"), "a house outside the run's own items is still a house")
    }

    // The #1681 pair, end to end: the room the run must refuse is on the list, and the organisation named
    // in the listing's title, which it must go and visit, is not.
    @Test func theOrganisationNamedInTheListingIsNotOnTheList() throws {
        let ctx = ModelContext(try container())
        insert(ctx, group: "everyday royalty: An Exhibition of Artists Across Henry Street Settlement",
               presenter: "Abrons Arts Center", venue: "Abrons Arts Center")

        let queue = PrepQueueService.buildQueue(from: ctx, generatedAt: "now")
        let keys = Set((queue.houses ?? []).map(\.key))
        #expect(keys.contains("abrons arts center"))
        #expect(keys.contains("henry street settlement") == false)
    }

    // Dan's own correction has to survive the trip. A demoted house that neither automatic arm reaches
    // (FRIGID New York is named in no venue string) is the case that proves the overrides are actually
    // read here rather than defaulted away.
    @Test func aHouseDanDemotedByHandReachesTheRun() throws {
        let ctx = ModelContext(try container())
        insert(ctx, group: "Some Fringe Show", presenter: "FRIGID New York", venue: "Under St Marks")

        let before = Set((PrepQueueService.buildQueue(from: ctx, generatedAt: "now").houses ?? []).map(\.key))
        #expect(before.contains("frigid new york") == false)

        ProducerOverrideEditing.demote("FRIGID New York", into: ctx)

        let after = Set((PrepQueueService.buildQueue(from: ctx, generatedAt: "now").houses ?? []).map(\.key))
        #expect(after.contains("frigid new york"))
    }

    // A reachability probe reads the same runbook and hunts the same contacts, so it is handed the same
    // list. This is the half most likely to be forgotten: it is a second build path, and the first one
    // passing tells you nothing about it.
    @Test func aReachabilityProbeIsHandedTheSameList() throws {
        let ctx = ModelContext(try container())
        let p = insert(ctx, group: "everyday royalty", presenter: "Abrons Arts Center",
                       venue: "Abrons Arts Center", status: .new)

        let queue = PrepQueueService.buildProbeQueue(from: ctx, generatedAt: "now", keys: [p.naturalKey])
        #expect(queue.items.count == 1)
        #expect(Set((queue.houses ?? []).map(\.key)).contains("abrons arts center"))
    }

    // An empty store names no houses, and that is an EMPTY list, not an absent one. The distinction is
    // the run's: absent means a queue file written before this phase existed, empty means the app looked
    // and there was nothing to name.
    @Test func anEmptyStoreWritesAnEmptyListNotAnAbsentOne() throws {
        let ctx = ModelContext(try container())
        let queue = PrepQueueService.buildQueue(from: ctx, generatedAt: "now")
        #expect(queue.houses == [])
    }
}
