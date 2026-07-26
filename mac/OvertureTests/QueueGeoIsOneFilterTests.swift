import Testing
import Foundation
import SwiftData
@testable import Overture

// #1570. The geography gate was asked on ONE path. The masthead ran its shows through
// QueueModel.filter with Dan's town refusals; the stage list he actually triages was built straight
// from the raw items and applied none of it, so the number and the list beneath it were answering the
// same question two ways.
//
// Measured on the live store 2026-07-26: 4 of 588 untriaged shows (Baltimore, Harrogate in the UK,
// North Adams MA, San Rafael CA). None were town refusals, which is why this stayed invisible: the
// #1238 sweep dismisses a refused town's shows outright, and Dan has exactly one refused town. What it
// never covered is every OTHER way a show places out of range, and that is what the masthead was
// quietly subtracting.
//
// So the gate now lives on the same predicate #1567 settled on, and this suite holds every surface to
// it at once. The direction that matters most is the last one: a location Overture cannot read must
// never hide a show, because a confident wrong place is the only failure here that loses Dan real work.
@MainActor
@Suite("One filter answers whether a show is somewhere Dan would shoot (#1570)")
struct QueueGeoIsOneFilterTests {
    private let today = ScoutTestClock.stageNavigationAnchor   // 2026-07-12
    private let now = Date(timeIntervalSince1970: 1_768_000_000)

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func show(_ ctx: ModelContext, _ key: String, location: String?,
                      discipline: String = "other", status: ReviewStatus = .new) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: key, discipline: discipline, venue: "A Hall",
                         performanceDate: "2026-08-19", sourceListingURL: nil, websiteURL: nil,
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

    // Every surface that answers "will the Queue show this", asked at once with the same refusals.
    private func surfaces(_ ps: [Prospect], _ key: String,
                          geo: GeoRefusals) -> (stageList: Bool, pillCount: Bool, masthead: Bool, opens: Bool) {
        let rows = StageNavigation.focusedKeys(stage: .scout, leadKeys: [], in: ps,
                                               today: today, now: now, geo: geo)
        let counts = StageNavigation.counts(in: ps, today: today, now: now, geo: geo)
        let queue = StageNavigation.queueKeys(in: ps, reachedOutKeys: [], today: today, now: now, geo: geo)
        let opens = StageNavigation.opensInQueue(key: key, in: ps, reachedOutKeys: [],
                                                 today: today, now: now, geo: geo)
        // The pill's number is a promise about rows (#863), so it is read as "does this show account for
        // one of the shows the Scout pill is counting" against the list it lands on.
        return (rows.contains(key), (counts[.scout] ?? 0) == rows.count && rows.contains(key),
                queue.contains(key), opens)
    }

    // MARK: - The invariant

    @Test func aShowPlacedOutOfRangeLeavesEverySurfaceAtOnce() throws {
        let ctx = try context()
        show(ctx, "baltimore", location: "Baltimore, Maryland")
        show(ctx, "manhattan", location: "New York, NY")
        let ps = try all(ctx)

        let gone = surfaces(ps, "baltimore", geo: .none)
        #expect(!gone.stageList, "the Scout list must stop rendering a show the count above it already leaves out.")
        #expect(!gone.masthead)
        #expect(!gone.opens, "a show no stage renders must route to Archive, not open a Queue that will not show it.")

        let kept = surfaces(ps, "manhattan", geo: .none)
        #expect(kept.stageList)
        #expect(kept.pillCount, "the Scout pill must count exactly the rows its tap lands on.")
        #expect(kept.masthead)
        #expect(kept.opens)
    }

    @Test func theCountAndTheListAgreeOnAStoreHoldingBoth() throws {
        let ctx = try context()
        show(ctx, "baltimore", location: "Baltimore, Maryland")
        show(ctx, "uk", location: "Harrogate, UK")
        show(ctx, "manhattan", location: "New York, NY")
        show(ctx, "brooklyn", location: "Brooklyn")
        let ps = try all(ctx)

        let rows = StageNavigation.focusedKeys(stage: .scout, leadKeys: [], in: ps,
                                               today: today, now: now, geo: .none)
        let counts = StageNavigation.counts(in: ps, today: today, now: now, geo: .none)
        let queue = StageNavigation.queueKeys(in: ps, reachedOutKeys: [], today: today, now: now, geo: .none)
        #expect(rows.count == 2)
        #expect(counts[.scout] == 2, "this is the live discrepancy: 4 shows counted out and still rendered.")
        #expect(queue.count == 2)
    }

    // MARK: - Dan's own refusals

    @Test func aRefusedTownHidesTheShowEverywhere() throws {
        let ctx = try context()
        show(ctx, "chautauqua", location: "Chautauqua, NY")
        let ps = try all(ctx)

        #expect(surfaces(ps, "chautauqua", geo: .none).stageList,
                "an unrefused town in New York is in range; only Dan's refusal takes it out.")
        let refused = GeoRefusals(userExcludedTowns: ["chautauqua"])
        #expect(!surfaces(ps, "chautauqua", geo: refused).stageList)
        #expect(!surfaces(ps, "chautauqua", geo: refused).masthead)
    }

    @Test func unSkippingASeedTownBringsItsShowsBack() throws {
        let ctx = try context()
        show(ctx, "montauk", location: "Montauk, NY")
        let ps = try all(ctx)

        #expect(!surfaces(ps, "montauk", geo: .none).stageList,
                "a built-in far town is excluded before Dan says anything.")
        let allowed = GeoRefusals(allowedSeedTowns: ["montauk"])
        #expect(surfaces(ps, "montauk", geo: allowed).stageList,
                "un-skipping a seed town must put its shows back in the list, not only in the count.")
    }

    // MARK: - The directions that must never hide a show

    @Test func aLocationOvertureCannotReadKeepsTheShow() throws {
        let ctx = try context()
        show(ctx, "unreadable", location: "The North Patio, behind the monument")
        show(ctx, "none-at-all", location: nil)
        show(ctx, "empty", location: "   ")
        let ps = try all(ctx)

        for key in ["unreadable", "none-at-all", "empty"] {
            let s = surfaces(ps, key, geo: .none)
            #expect(s.stageList, "\(key): an unread location must keep the show. Certainty or nothing.")
            #expect(s.masthead)
            #expect(s.opens)
        }
    }

    // Live outreach is never Overture's to hide, which is the same line ExcludedTownRetirement draws
    // before it dismisses anything: a send error on a show in Baltimore is still a problem Dan has to
    // see, and burying it behind a geography rule would lose it silently.
    @Test func aShowDanHasAlreadyActedOnStaysVisibleWhereverItIs() throws {
        let ctx = try context()
        let approved = show(ctx, "approved-far", location: "Baltimore, Maryland", status: .approved)
        approved.sentAt = nil
        show(ctx, "errored-far", location: "San Rafael, CA", status: .contacted).sendError = "bounced"
        let ps = try all(ctx)

        let counts = StageNavigation.counts(in: ps, today: today, now: now, geo: .none)
        #expect(counts[.sendApproved] == 1, "an approved show out of range is committed outreach, not a scouting suggestion.")
        #expect(counts[.sendErrors] == 1, "a send error must never be hidden by a geography rule.")
        #expect(StageNavigation.opensInQueue(key: "errored-far", in: ps, reachedOutKeys: [],
                                             today: today, now: now, geo: .none))
    }

    // The Prep and Review stages carry no committed outreach yet, so the gate holds there too: a show
    // out of range must not reach a Prep run that would spend tokens drafting a pitch Dan cannot use.
    @Test func anUntriagedShowOutOfRangeIsGoneFromPrepAndReviewToo() throws {
        let ctx = try context()
        show(ctx, "queued-far", location: "Baltimore, Maryland", status: .queued)
        show(ctx, "drafted-far", location: "Harrogate, UK", status: .drafted)
        let ps = try all(ctx)

        let counts = StageNavigation.counts(in: ps, today: today, now: now, geo: .none)
        #expect((counts[.prep] ?? 0) == 0)
        #expect((counts[.review] ?? 0) == 0)
    }

    // MARK: - Music, which has its own range

    @Test func musicOutsideTheBoroughsLeavesTheListTheSameWayItLeftTheCount() throws {
        let ctx = try context()
        show(ctx, "band-upstate", location: "Poughkeepsie, NY", discipline: "music")
        show(ctx, "opera-upstate", location: "Poughkeepsie, NY", discipline: "opera")
        let ps = try all(ctx)

        #expect(!surfaces(ps, "band-upstate", geo: .none).stageList,
                "Dan will not travel for a band, and the list must say so the same way the count does.")
        #expect(surfaces(ps, "opera-upstate", geo: .none).stageList,
                "everything else is in range across NY, NJ and CT.")
    }
}

// #1570 second claim: the predicate applying the gate is worth nothing if the surfaces hand it an
// empty set of refusals. The argument defaults to `.none` so the fifty-odd tests that are not about
// geography stay readable, and a default is exactly what a new caller silently inherits, so the real
// call sites are pinned here. This is the same shape as StagePillCountMatchesNavigationTests, and the
// standing guard #1575 asks for generally.
@Suite("The queue surfaces hand the geography gate Dan's real refusals (#1570)")
struct QueueGeoWiringGuardTests {
    private var queueView: String { SourceGuardHelper.source("Overture/UI/QueueView.swift") }
    private var rootView: String { SourceGuardHelper.source("Overture/App/RootView.swift") }

    @Test func theQueueBuildsItsRefusalsFromDansStoredTowns() {
        #expect(!queueView.isEmpty)
        #expect(queueView.contains("GeoRefusals(userExcludedTowns: userExcludedTowns, allowedSeedTowns: allowedSeedTowns)"))
    }

    @Test func everyQueueSurfacePassesThem() {
        for call in ["queueKeys", "focusedKeys", "counts", "naturalKeys", "stage(containing:"] {
            #expect(queueView.contains(call), "\(call) is no longer called; re-point this guard.")
        }
        // Four calls resolve rows or counts, plus the roster's inputs. Each must carry geo, or that
        // surface goes back to answering the question its own way.
        #expect(queueView.components(separatedBy: "geo: geo").count - 1 >= 6,
                "a queue surface is resolving stage membership without Dan's refusals.")
    }

    @Test func theSearchAndFollowUpRoutingPassesThemToo() {
        #expect(!rootView.isEmpty)
        #expect(rootView.contains("reachedOutKeys: reachedOutKeys, geo: geo)"),
                "routing a pick to the Queue or Archive must apply the same gate the Queue's lists do.")
    }
}
