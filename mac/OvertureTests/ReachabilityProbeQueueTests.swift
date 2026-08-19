import Testing
import Foundation
import SwiftData

// #1308 Layer 2 Phase 1: the probe work-list is built from Dan's hand-picked keys DIRECTLY, bypassing the
// normal "must be kept" prep gate (a Review-stage .new show can never enter the prep queue via
// needsPrepEligible). Every probe item is contacts-only, and the queue is marked a probe so the runner
// researches without drafting and the results are stamped as a probe run.
@MainActor
@Suite("Reachability probe queue (#1308)")
struct ReachabilityProbeQueueTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func insert(_ ctx: ModelContext, group: String, date: String, status: ReviewStatus) -> String {
        let key = Prospect.makeNaturalKey(groupName: group, performanceDate: date, venue: "Weill Recital Hall")
        let p = Prospect(naturalKey: key, groupName: group, discipline: "music", venue: "Weill Recital Hall",
                         performanceDate: date, sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 6, tier: "mid", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: status)
        ctx.insert(p)
        try? ctx.save()
        return key
    }

    @Test func buildsContactsOnlyProbeItemsForHandPickedNewShows() throws {
        let ctx = ModelContext(try container())
        let a = insert(ctx, group: "Aurora Strings", date: "2026-09-12", status: .new)   // Review-stage, not kept
        let b = insert(ctx, group: "Boreal Brass", date: "2026-09-12", status: .new)
        _ = insert(ctx, group: "Not Chosen", date: "2026-09-12", status: .new)

        let queue = PrepQueueService.buildProbeQueue(from: ctx, generatedAt: "now", keys: [a, b])

        #expect(Set(queue.items.map(\.naturalKey)) == [a, b])   // only the hand-picked keys, though .new
        // Contacts-only is what tells the runner not to draft; no queue-level probe flag on the wire.
        #expect(queue.items.allSatisfy { $0.reprepMode == "contacts_only" })
    }

    // #1597 Phase 4.3: ProbeBatch decides the grouping, but the QUEUE has to actually carry it. These are
    // two separate claims and the pure planner passing says nothing about the wiring.
    private func insert(_ ctx: ModelContext, group: String, date: String,
                        presenter: String?, venue: String) -> String {
        let key = Prospect.makeNaturalKey(groupName: group, performanceDate: date, venue: venue)
        let p = Prospect(naturalKey: key, groupName: group, discipline: "theater", venue: venue,
                         performanceDate: date, sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .new)
        p.presenter = presenter
        ctx.insert(p)
        try? ctx.save()
        return key
    }

    @Test func oneProducersShowsBecomeASingleItemThatAnswersForTheRest() throws {
        let ctx = ModelContext(try container())
        let a = insert(ctx, group: "Show A", date: "2026-09-12", presenter: "FRIGID New York", venue: "Under St Marks")
        let b = insert(ctx, group: "Show B", date: "2026-09-13", presenter: "FRIGID New York", venue: "The Kraine Theater")
        let c = insert(ctx, group: "Show C", date: "2026-09-14", presenter: "FRIGID New York", venue: "Under St Marks")

        let queue = PrepQueueService.buildProbeQueue(from: ctx, generatedAt: "now", keys: [a, b, c])

        #expect(queue.items.count == 1)
        let item = try #require(queue.items.first)
        // Whichever show is the representative, the other two ride along and every show is accounted for.
        let covered = try #require(item.alsoAnswersFor)
        #expect(Set([item.naturalKey] + covered) == Set([a, b, c]))
        #expect(covered.count == 2)
        #expect(covered == covered.sorted())   // stable output for an identical selection
    }

    // The expensive-but-correct case. A room that rents itself out is three unrelated productions that
    // share an address, so one contact must never be stamped across them: three items, three researches.
    @Test func aRoomThatRentsItselfOutStillCostsOneResearchPerShow() throws {
        let ctx = ModelContext(try container())
        let a = insert(ctx, group: "Show A", date: "2026-09-12", presenter: "Green Room 42", venue: "Green Room 42")
        let b = insert(ctx, group: "Show B", date: "2026-09-13", presenter: "Green Room 42", venue: "Green Room 42")
        let c = insert(ctx, group: "Show C", date: "2026-09-14", presenter: "Green Room 42", venue: "Green Room 42")

        let queue = PrepQueueService.buildProbeQueue(from: ctx, generatedAt: "now", keys: [a, b, c])

        #expect(queue.items.count == 3)
        #expect(queue.items.allSatisfy { $0.alsoAnswersFor == nil })
    }

    // The grouping must be judged against the whole store. Dan ticks ONE night, on which this producer
    // has a single show at a single venue; the store knows it also plays elsewhere, so it still groups.
    @Test func theGroupingSeesTheWholeStoreNotJustTheSelectedNight() throws {
        let ctx = ModelContext(try container())
        let a = insert(ctx, group: "Show A", date: "2026-09-12", presenter: "FRIGID New York", venue: "Under St Marks")
        let b = insert(ctx, group: "Show B", date: "2026-09-12", presenter: "FRIGID New York", venue: "Under St Marks")
        _ = insert(ctx, group: "Elsewhere", date: "2027-01-04", presenter: "FRIGID New York", venue: "The Kraine Theater")

        let queue = PrepQueueService.buildProbeQueue(from: ctx, generatedAt: "now", keys: [a, b])

        #expect(queue.items.count == 1)
        #expect(queue.items[0].alsoAnswersFor?.count == 1)
    }

    // #2983: the check is TOLD the producing organisation the app already holds, by name.
    //
    // Until this issue the only thing either builder derived from `presenter` was the boolean
    // `onlyTheActIsNamed`, so a check on a show credited to a real company was told a producer existed
    // and never told which one. Measured on the live store: 12 of the 23 cards reading "No email found"
    // were in that state, and four of those companies appear in no check transcript at all. The check
    // that produced Dan's report spent 22 web calls, never searched the company's name once, drifted onto
    // a different production of a similarly titled show, and recorded `nothing_published` about an
    // organisation publishing its address on its own contact page.
    @Test func theCheckIsToldTheProducingOrganisationTheAppAlreadyHolds() throws {
        let ctx = ModelContext(try container())
        let key = insert(ctx, group: "Punk Goes Broadway!", date: "2026-08-22",
                         presenter: "Underbelly Theatre Company", venue: "The Green Room 42")

        let queue = PrepQueueService.buildProbeQueue(from: ctx, generatedAt: "now", keys: [key])

        let item = try #require(queue.items.first)
        #expect(item.presenterOnRecord == "Underbelly Theatre Company")
        // The flag ABOUT the fact is not a substitute for the fact, which is the whole defect.
        #expect(item.onlyTheActIsNamed == false)
    }

    // The Prep run is blind in the identical way, so it is covered in the same change rather than left
    // as a sibling nobody comes back to (L30). A drafted pitch has the same reason to name the company.
    @Test func thePrepQueueIsToldTheProducingOrganisationToo() throws {
        let ctx = ModelContext(try container())
        let key = insert(ctx, group: "Song & Word", date: "2026-09-12",
                         presenter: "Vivace Arts Collective", venue: "The Green Room 42")
        let p = try #require(ctx.fetch(FetchDescriptor<Prospect>()).first { $0.naturalKey == key })
        p.status = .queued                      // buildQueue only admits kept, undrafted shows
        try? ctx.save()

        let queue = PrepQueueService.buildQueue(from: ctx, generatedAt: "now",
                                                venueHistory: VenueShootHistory(shoots: [], bookings: [],
                                                                                  today: "2026-08-19"))

        let item = try #require(queue.items.first { $0.naturalKey == key })
        #expect(item.presenterOnRecord == "Vivace Arts Collective")
    }

    // A show that genuinely names nobody must carry NO field rather than an empty string: absent is the
    // answer the runbook already has a sentence for, and an empty value would read as a named nobody
    // (L138, L67).
    @Test func aShowThatNamesNoProducerCarriesNoOrganisationAtAll() throws {
        let ctx = ModelContext(try container())
        let key = insert(ctx, group: "Broadway's Bad Guys!", date: "2026-08-22",
                         presenter: nil, venue: "The Green Room 42")

        let queue = PrepQueueService.buildProbeQueue(from: ctx, generatedAt: "now", keys: [key])

        let item = try #require(queue.items.first)
        #expect(item.presenterOnRecord == nil)
        #expect(item.onlyTheActIsNamed == true)
    }

    // #2983: the flag and the name can never disagree, on any input either builder can meet.
    //
    // This is the defect one layer down. A queue saying "an organisation IS named here" while carrying no
    // name is the same withholding again, so the two answers are one predicate rather than two spellings
    // of the same trim. Whitespace is the case that separates them: it is not a name, and a padded value
    // must never reach a reader looking present.
    @Test(arguments: [nil, "", "   ", "\n", " Underbelly Theatre Company ", "FRIGID New York"] as [String?])
    func theFlagAndTheNameAlwaysAgree(presenter: String?) {
        let name = OrganiserNaming.namedOrganiser(presenter: presenter)
        #expect(OrganiserNaming.onlyTheActIsNamed(presenter: presenter) == (name == nil))
        #expect(name?.hasPrefix(" ") != true)
        #expect(name?.hasSuffix(" ") != true)
    }

    // And the queue carries the trimmed name, not the padded stored one, so a reader is never handed a
    // value whose whitespace is the only reason it looked like a name.
    @Test func theQueueCarriesTheTrimmedNameNotThePaddedStoredOne() throws {
        let ctx = ModelContext(try container())
        let key = insert(ctx, group: "Show A", date: "2026-09-12",
                         presenter: "  Moore Productions  ", venue: "The Green Room 42")

        let queue = PrepQueueService.buildProbeQueue(from: ctx, generatedAt: "now", keys: [key])

        #expect(try #require(queue.items.first).presenterOnRecord == "Moore Productions")
    }
}
