import Testing
import Foundation
import SwiftData

// #1580. The persistent bar above the Queue searched the WHOLE store, dismissed shows included, and
// then routed roughly half of what it found out of the Queue and into Archive. Dan asked for the two
// to split: "search should only allow me to search for shows in the queue. Archive can have its own
// search."
//
// So the bar is fed StageNavigation.stagedKeys, which is the same predicate the stage lists render
// from (#1567) and now the same geography gate (#1570). A pick can only ever land on a row he can see.
@MainActor
@Suite("The global search bar can only find shows a stage will render (#1580)")
struct SearchScopedToQueueTests {
    private let today = ScoutTestClock.stageNavigationAnchor   // 2026-07-12
    private let now = Date(timeIntervalSince1970: 1_768_000_000)

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func show(_ ctx: ModelContext, _ key: String, status: ReviewStatus = .new,
                      date: String = "2026-08-19", location: String? = nil) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: key, discipline: "music", venue: "Merkin Hall",
                         performanceDate: date, sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: status)
        p.location = location
        ctx.insert(p)
        return p
    }

    private func all(_ ctx: ModelContext) throws -> [Prospect] {
        try ctx.fetch(FetchDescriptor<Prospect>())
    }

    private func staged(_ ps: [Prospect], reachedOut: Set<String> = [],
                        geo: GeoRefusals = .none) -> Set<String> {
        StageNavigation.stagedKeys(in: ps, reachedOutKeys: reachedOut, today: today, now: now, geo: geo)
    }

    // The whole point of routing search through one predicate: what the bar can FIND and what a pick
    // OPENS are the same question, so they cannot answer differently. Asked of every show in a store
    // holding one of each shape.
    @Test func everythingTheBarCanFindIsSomethingThePickOpensInTheQueue() throws {
        let ctx = try context()
        show(ctx, "untriaged")
        show(ctx, "far-future", date: "2027-03-01")
        show(ctx, "to-review", status: .drafted)
        show(ctx, "already-over", date: "2026-06-01")
        show(ctx, "pitched", status: .contacted)
        show(ctx, "cut", status: .dismissed)
        show(ctx, "baltimore", location: "Baltimore, Maryland")
        let ps = try all(ctx)
        let reachedOut: Set<String> = ["pitched"]
        let geo = GeoRefusals.none

        let scope = staged(ps, reachedOut: reachedOut, geo: geo)

        for p in ps {
            let opens = StageNavigation.opensInQueue(key: p.naturalKey, in: ps, reachedOutKeys: reachedOut,
                                                     today: today, now: now, geo: geo)
            #expect(scope.contains(p.naturalKey) == opens,
                    "\(p.naturalKey): searchable=\(scope.contains(p.naturalKey)) but opensInQueue=\(opens)")
        }
    }

    // What actually leaves the bar: a show Dan cut, and one whose last night has already gone by.
    // Both are Archive's job now.
    @Test func aCutShowAndAShowAlreadyGoneByAreOutOfScope() throws {
        let ctx = try context()
        show(ctx, "untriaged")
        show(ctx, "cut", status: .dismissed)
        show(ctx, "already-over", date: "2026-06-01")

        #expect(staged(try all(ctx)) == ["untriaged"])
    }

    // Reached out IS a stage, with its own pill and its own per-recipient rows, so a show Dan has
    // pitched and is waiting on stays findable. It is live work, not history.
    @Test func aShowHeHasAlreadyPitchedStaysInScope() throws {
        let ctx = try context()
        show(ctx, "pitched", status: .contacted)

        #expect(staged(try all(ctx), reachedOut: ["pitched"]) == ["pitched"])
    }

    // #1570's gate rides along, because it is the same predicate: a show in a town Dan refuses is not
    // in the Queue, so the bar must not offer it either.
    @Test func aShowInATownHeRefusesIsOutOfScope() throws {
        let ctx = try context()
        show(ctx, "manhattan", location: "New York, NY")
        show(ctx, "refused", location: "Poughkeepsie, NY")
        let geo = GeoRefusals(userExcludedTowns: ["poughkeepsie"])

        #expect(staged(try all(ctx), geo: geo) == ["manhattan"])
    }

    // The masthead counts a subset of the same predicate (it leaves out what Dan has already pitched),
    // so everything it counts is findable. Stated as its own test because the two are separate calls.
    @Test func everyShowTheMastheadCountsIsFindable() throws {
        let ctx = try context()
        show(ctx, "untriaged")
        show(ctx, "to-review", status: .drafted)
        show(ctx, "pitched", status: .contacted)
        let ps = try all(ctx)
        let reachedOut: Set<String> = ["pitched"]

        let scope = staged(ps, reachedOut: reachedOut)
        for key in StageNavigation.queueKeys(in: ps, reachedOutKeys: reachedOut, today: today, now: now) {
            #expect(scope.contains(key), "the masthead counts \(key) but the search bar cannot find it")
        }
    }
}

// #1580. With the bar narrowed, "No matches" became a lie in the common case: the show exists, it is
// just in Archive. Dan chose the version that hands him the next step rather than only naming the
// miss, so the empty state carries a jump.
@Suite("A search that finds nothing in the queue points at Archive (#1580)")
struct SearchEmptyStateTests {
    @Test func withNothingAnywhereItSaysOnlyThat() {
        let state = ShowSearch.emptyState(query: "philharmonic", archiveMatches: 0)

        #expect(state.note == "No matches for \"philharmonic\"")
        #expect(state.archiveMatches == 0)
        #expect(!state.offersArchive, "there is nothing in Archive to send him to, so offering the jump would be a dead end of its own")
    }

    @Test func whenArchiveHoldsTheShowItOffersTheJump() {
        let state = ShowSearch.emptyState(query: "philharmonic", archiveMatches: 3)

        #expect(state.offersArchive)
        #expect(state.note == "Nothing in the queue matches \"philharmonic\"")
        #expect(state.archiveAction == "Look in Archive (3)")
    }

    // The count belongs to the button, which is the thing he acts on, and appears once. Two lines
    // stating the same number is exactly the on-screen restatement #843 was about.
    @Test func theCountIsStatedOnceOnTheButton() {
        let state = ShowSearch.emptyState(query: "phil", archiveMatches: 2)

        #expect(!state.note.contains("2"))
    }

    // The query is quoted back in both lines, which is what makes them useful: a typo is visible.
    @Test func bothLinesQuoteBackWhatHeTyped() {
        #expect(ShowSearch.emptyState(query: "merkin", archiveMatches: 0).note.contains("\"merkin\""))
        #expect(ShowSearch.emptyState(query: "merkin", archiveMatches: 1).note.contains("\"merkin\""))
    }
}

// #1580. Taking the jump has to LAND on the show. Archive opens on two status chips (New and Active),
// and the shows the narrowed bar can no longer find are precisely the ones outside those two, so an
// Archive opened with a query and the usual chips would show him an empty list about a query that
// just told him there were three matches.
@Suite("Archive opened from a search carries the query and shows every status (#1580)")
struct ArchiveOpeningTests {
    @Test func openingWithAQueryWidensToEveryStatus() {
        #expect(ArchiveOpening.statuses(forQuery: "philharmonic") == Set(ArchiveStatus.allCases))
    }

    @Test func openingWithoutAQueryKeepsTheUsualTwo() {
        #expect(ArchiveOpening.statuses(forQuery: "") == ArchiveOpening.defaultStatuses)
        #expect(ArchiveOpening.statuses(forQuery: "   ") == ArchiveOpening.defaultStatuses)
        #expect(ArchiveOpening.defaultStatuses == [.new, .active])
    }
}

// The wiring, which no test can reach from outside a SwiftUI view: that the bar is fed the scoped
// list rather than every prospect the store holds, and that Archive's own field is NOT scoped.
@Suite("The scope and the Archive jump are wired to the right fields (#1580)")
struct SearchScopeWiringGuardTests {
    private var rootView: String { SourceGuardHelper.source("Overture/App/RootView.swift") }
    private var archiveView: String { SourceGuardHelper.source("Overture/UI/ArchiveView.swift") }
    private var field: String { SourceGuardHelper.source("Overture/UI/ShowSearchField.swift") }

    @Test func theGlobalBarIsFedTheStagedShowsOnly() {
        #expect(!rootView.isEmpty)
        #expect(rootView.contains("StageNavigation.stagedKeys("),
                "the bar's scope must come from the predicate the stage lists render from, not a second filter of its own")
        #expect(!rootView.contains("private var searchableItems: [QueueItem] { allProspects.map(QueueItem.init) }"),
                "feeding the bar every prospect is what #1580 removed")
    }

    @Test func archivesOwnFieldKeepsTheWholeStore() {
        #expect(!archiveView.isEmpty)
        // #1926: the scope arrives as a closure now, so this pins `{ items }` rather than `items`.
        #expect(archiveView.contains("ShowSearchField(query: $query, allItems: { items }"),
                "Archive is the screen whose job is everything else; narrowing its field too would leave the out-of-scope shows unreachable")
    }

    @Test func theEmptyStateGoesThroughTheTestedHelper() {
        #expect(field.contains("ShowSearch.emptyState("),
                "the sentence and the button title must come from the tested helper, not be composed in the view")
    }
}
