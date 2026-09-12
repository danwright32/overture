import Testing
import Foundation
import SwiftData

// #3645: what one render pass of the SOURCES SHEET is allowed to cost, counted rather than timed.
//
// WHY A SECOND PASS AND NOT A SHARE OF THE QUEUE'S. The queue's cost is per-card construction over rows
// it does not render; this sheet renders every row it has and its cost is whole-store sweeps plus an
// O(clients x sources) fuzzy match that was on the render path. The queue's fix does nothing for this one
// (#3645 says so in its own body), so the instrument is separate and the numbers below are this
// surface's own.
//
// WHY COUNTED. `SourcesSheetCostTests` (#3656) already times this sheet's derivations against a clone of
// the live store, and that reading is the right one for asking how long a thing takes. It is opt-in and
// it cannot ride the push gate, because a timing assertion on a shared Mac measures what else the machine
// is running (L224). A count can, so a sweep added to this surface next month goes red on the push that
// adds it rather than waiting for Dan to notice the sheet has gone slow.
//
// PINNED DELIBERATELY, and meant to be argued with rather than updated to whatever the code does. Raising
// either number is a decision about how much opening this sheet, typing in its search field and scrolling
// it are allowed to cost.
@MainActor
@Suite("One render pass of the Sources sheet costs a pinned number of sweeps (#3645)")
struct SourcesRenderPassCostTests {
    // The live store, measured 2026-09-11 on the same read the drift check takes:
    // 1,238 prospects and 73 watched sources. Both carry a LIVE-SHAPE tag, so
    // scripts/check-fixture-corpus-drift.sh names whichever has fallen behind on every push instead of
    // this fixture quietly exercising a smaller world than the one that ships (L354).
    // LIVE-SHAPE: prospects
    static let corpusSize = 1238
    // LIVE-SHAPE: sources
    static let sourceCount = 73
    // The Downbeat roster, 31 clients on 2026-09-08 (`SourcesSheetCostTests`). Not a dimension the drift
    // check can measure: the roster is a FILE, not a table in the store, so it carries its date instead.
    static let clientCount = 31

    // TWO sweeps of the store per pass, once each, and both of them named. If this number moves, one of
    // these has changed or a new one has appeared, and either is a decision rather than an accident:
    //
    //   1. every source's lifetime tally, one pass over the store for the whole list (#1429/#3656)
    //   2. the rooms no table can place, which walks the store for the shows still waiting on an answer
    //
    // It is TWO rather than three because the coverage gap list is not a sweep of the store at all: it
    // matches sources against the Downbeat roster and never reads a prospect.
    static let allowedSweeps = 2

    // NO fuzzy client match on the render path, and this is the number #3645 is actually about.
    //
    // `SourcesView.roomContext` used to construct `ClientWindow(sources:clients:)` as an ARGUMENT to the
    // unplaced-rooms derivation, so every body evaluation ran `ClientHorizon.clientSourceIds`, an
    // O(clients x sources) fuzzy match, over the whole watchlist and the whole roster. #1429 measured
    // that exact shape, run per row, freezing this sheet. The verdict is decided once when its inputs
    // change and handed to the pass as a value, so a pass runs it zero times.
    //
    // Zero is only meaningful because `theCounterCanSeeAClientNameMatch` below shows the counter can
    // reach a real match: a zero from an instrument nothing calls is UNMEASURED, not cheap (L90, L98).
    static let allowedClientNameMatches = 0

    private func container() throws -> ModelContainer {
        try ModelContainer(
            for: Schema([Prospect.self, Recipient.self, WatchedSource.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    // A corpus with the spread the real store has: most shows placed, a minority carrying no location at
    // all (which is what the room list is about), dates either side of today, and a mix of statuses, so
    // no sweep can short-circuit on an empty or uniform list.
    //
    // THE BLANK-LOCATION MINORITY IS LOAD BEARING. Measured on the live store 2026-08-07 and recorded on
    // `UnplacedRooms`: 78 of 845 shows carry no location, and the room derivation is cheap precisely
    // because it pays the expensive half only on those. A fixture giving every row a location would take
    // the empty branch and measure a path the store does not take (L101).
    private func seed(_ ctx: ModelContext) -> (prospects: [Prospect], sources: [WatchedSource]) {
        let venues = ["Weill Recital Hall", "SoHo Playhouse", "The Green Room 42", "Merkin Hall",
                      "Roulette Intermedium", "The Tank", "Bargemusic", "54 Below"]
        var rows: [Prospect] = []
        for n in 0..<Self.corpusSize {
            // Inside the ordinary 90 day lead-time window from this fixture's pinned `now` (2026-08-02),
            // because the room list only names rooms the QUEUE will show Dan and the queue's own gate is
            // that window. Dated past it, every candidate falls out, `rooms` comes back empty and every
            // count below would be a reading of the branch that does nothing (L101, L165).
            let date = String(format: "2026-%02d-%02d", 8 + (n % 3), 1 + (n % 27))
            let p = Prospect(naturalKey: "row-\(n)", groupName: "Ensemble \(n % 90)", discipline: "music",
                             venue: venues[n % venues.count], performanceDate: date,
                             sourceListingURL: nil, priorRelationship: "none",
                             production: n % 3 == 0 ? "self" : "presenter", profile: "strong",
                             coverage: "likely_uncovered", fitScore: 4 + (n % 5), tier: "mid",
                             fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                             possibleMatchName: nil,
                             status: n % 3 == 0 ? .new : (n % 2 == 0 ? .drafted : .contacted))
            // Roughly one row in thirteen has no place, which is the live store's shape (78 of 845).
            p.location = n % 13 == 0 ? nil : "New York, NY"
            p.sourceIds = ["src-\(n % Self.sourceCount)"]
            ctx.insert(p)
            rows.append(p)
        }
        var sources: [WatchedSource] = []
        for n in 0..<Self.sourceCount {
            let s = WatchedSource(sourceId: "src-\(n)", orgName: "Org \(n)",
                                  listingsURL: "https://org\(n).example/events", kind: .html)
            ctx.insert(s)
            sources.append(s)
        }
        try? ctx.save()
        return (rows, sources)
    }

    private func clients() -> [DownbeatClient] {
        (0..<Self.clientCount).map {
            DownbeatClient(id: "client-\($0)", displayName: "Client Chorale \($0)", shortName: nil,
                           email: "", contractEmail: "", phoneNumber: nil, isTaxExempt: nil,
                           hasLeftReview: false, specialBehaviors: [], notes: nil, hostingSite: "")
        }
    }

    private func inputs(_ seeded: (prospects: [Prospect], sources: [WatchedSource]),
                        tally: SourcesRenderPass.CostTally? = nil,
                        query: String = "") -> SourcesRenderPass.Inputs {
        let now = Date(timeIntervalSince1970: 1_785_000_000)
        return SourcesRenderPass.Inputs(
            prospects: SourcesRenderPass.Corpus(seeded.prospects, tally: tally),
            sources: seeded.sources,
            searchQuery: query,
            context: StageContext(now: now, geo: .none, clients: .none))
    }

    // THE MEASUREMENT. One pass over a realistic store sweeps it a pinned number of times.
    @Test func onePassSweepsTheStoreAPinnedNumberOfTimes() throws {
        let ctx = ModelContext(try container())
        let seeded = seed(ctx)
        let tally = SourcesRenderPass.CostTally()

        let data = SourcesRenderPass.make(inputs(seeded, tally: tally))

        #expect(tally.sweeps == Self.allowedSweeps)
        // And it really did derive the whole store, so the count above is not the cost of doing nothing.
        #expect(data.tallies.count == Self.sourceCount)
        #expect(!data.rooms.isEmpty, "the fixture produced no unplaced rooms, so half the pass was inert")
    }

    // THE NUMBER #3645 IS ABOUT. No fuzzy client match happens while the sheet redraws.
    @Test func onePassRunsNoFuzzyClientMatches() throws {
        let ctx = ModelContext(try container())
        let seeded = seed(ctx)

        let work = SourcesRenderPass.WorkTally.measure { _ = SourcesRenderPass.make(inputs(seeded)) }

        #expect(work.clientNameMatches == Self.allowedClientNameMatches, """
            one redraw of the Sources sheet ran \(work.clientNameMatches) org-name-against-roster fuzzy \
            matches. #1429 measured that work on this sheet's render path freezing it (#3645).
            """)
    }

    // THE POSITIVE CONTROL for the line above. A counter nothing ever increments reports zero for a
    // surface that is doing the work, and that reading is indistinguishable from the fix holding (L90).
    @Test func theCounterCanSeeAClientNameMatch() throws {
        let ctx = ModelContext(try container())
        let seeded = seed(ctx)

        let work = SourcesRenderPass.WorkTally.measure {
            _ = ClientWindow(sources: seeded.sources, clients: clients())
        }

        #expect(work.clientNameMatches > 0,
                "the fuzzy-match counter never fires, so the zero asserted above measures nothing")
    }

    // Searching hides the two whole-watchlist panels, so it must also stop paying for them: the room
    // derivation is the sweep that goes, and nothing else changes.
    @Test func searchingCostsOneFewerSweep() throws {
        let ctx = ModelContext(try container())
        let seeded = seed(ctx)
        let tally = SourcesRenderPass.CostTally()

        let data = SourcesRenderPass.make(inputs(seeded, tally: tally, query: "Org 1"))

        #expect(tally.sweeps == Self.allowedSweeps - 1)
        #expect(data.rooms.isEmpty)
        #expect(!data.visible.isEmpty)
        #expect(data.tallies.count == Self.sourceCount)
    }

    // A search that matches nothing draws a sentence and no list at all, so it may not touch the store.
    @Test func aSearchThatMatchesNothingSweepsTheStoreNotAtAll() throws {
        let ctx = ModelContext(try container())
        let seeded = seed(ctx)
        let tally = SourcesRenderPass.CostTally()

        let data = SourcesRenderPass.make(inputs(seeded, tally: tally, query: "zzzz no such org"))

        #expect(tally.sweeps == 0)
        #expect(data.visible.isEmpty)
        #expect(data.tallies.isEmpty)
    }

    // An empty watchlist draws its own screen, and derives nothing.
    @Test func anEmptyWatchlistSweepsTheStoreNotAtAll() throws {
        let ctx = ModelContext(try container())
        let seeded = seed(ctx)
        let tally = SourcesRenderPass.CostTally()

        let data = SourcesRenderPass.make(
            inputs((prospects: seeded.prospects, sources: []), tally: tally))

        #expect(tally.sweeps == 0)
        #expect(data.tallies.isEmpty)
        #expect(data.rooms.isEmpty)
    }

    // THE REGRESSION GUARD ON WHAT THE SHEET SHOWS, which every number above is worthless without.
    //
    // The pass is a LIFT, so its answer has to be the one the sheet's body produced inline, field for
    // field, over the same inputs. Asserted against the domain functions called exactly as
    // `SourcesView` called them rather than against a recorded expectation, because a snapshot defends
    // whatever the surface happened to be showing when it was taken (L84).
    @Test func theLiftedPassAnswersWhatTheInlineDerivationDid() throws {
        let ctx = ModelContext(try container())
        let seeded = seed(ctx)
        let i = inputs(seeded)

        let data = SourcesRenderPass.make(i)

        let visible = SourceSearch.filter(seeded.sources, query: "")
        let attention = SourceAttention.split(visible, now: i.context.now)
        #expect(data.visible.map(\.sourceId) == visible.map(\.sourceId))
        #expect(data.needsALook.map(\.sourceId) == attention.needsALook.map(\.sourceId))
        #expect(data.sections.map(\.grade) == SourceGrade.sections(attention.rest).map(\.grade))
        #expect(data.sections.map { $0.sources.map(\.sourceId) }
                == SourceGrade.sections(attention.rest).map { $0.sources.map(\.sourceId) })
        #expect(data.tallies == SourceYield.tallies(in: seeded.prospects))
        #expect(data.rooms == UnplacedRooms.from(seeded.prospects, context: i.context))
        #expect(data.isSearching == SourceSearch.isSearching(""))
    }

    // The same claim on the branch a search takes, because that branch renders different sections and a
    // lift that got the common case right can still have moved a panel.
    @Test func theLiftedPassAnswersWhatTheInlineDerivationDidWhileSearching() throws {
        let ctx = ModelContext(try container())
        let seeded = seed(ctx)
        let i = inputs(seeded, query: "Org 2")

        let data = SourcesRenderPass.make(i)

        let visible = SourceSearch.filter(seeded.sources, query: "Org 2")
        let attention = SourceAttention.split(visible, now: i.context.now)
        #expect(!visible.isEmpty, "the fixture matched nothing, so this compared two empty lists")
        #expect(data.visible.map(\.sourceId) == visible.map(\.sourceId))
        #expect(data.needsALook.map(\.sourceId) == attention.needsALook.map(\.sourceId))
        #expect(data.sections.map { $0.sources.map(\.sourceId) }
                == SourceGrade.sections(attention.rest).map { $0.sources.map(\.sourceId) })
        #expect(data.tallies == SourceYield.tallies(in: seeded.prospects))
        #expect(data.isSearching)
    }
}

// The other half of the cost, and the one a sweep count cannot see: a file read on the render path. The
// queue's pass is held to this and so is this one, because a sheet that reaches for the Downbeat export
// or a run marker while it redraws pays a disk read per keystroke.
@Suite("A Sources render pass reads no files (#3645)")
struct SourcesRenderPassIsPureTests {
    private var renderPass: String { SourceGuardHelper.source("Overture/UI/SourcesRenderPass.swift") }

    @Test func thePassNeverTouchesTheFilesystem() {
        #expect(!renderPass.isEmpty)
        for reader in ["DownbeatBridge.load", "ScoutReadInFlight.load", "ScoutExtractService.isRunning",
                       "GmailConnection", "FileManager", "Data(contentsOf:"] {
            #expect(!renderPass.contains(reader),
                    "\(reader) is a filesystem read, and this runs on every render pass")
        }
    }

    // The counting is not optional. If the rows could be reached around the corpus, a new sweep would be
    // invisible to the measurement above and the guard would quietly stop guarding.
    @Test func theRowsCanOnlyBeReachedThroughTheCountedAccessor() {
        #expect(renderPass.contains("typealias Corpus = QueueRenderPass.Corpus"),
                "the pass no longer takes its rows through the counted corpus")
    }
}
