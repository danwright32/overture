import Testing
import Foundation
import SwiftData

// #987: the two ingest paths disagreed about what a usable event is, and nobody chose that.
//
// The agent path applies ExtractedEventGuard at the boundary BY CONSTRUCTION
// (ScoutExtractResults.events(for:) filters on isUsable), so a venue-less event never becomes a
// prospect. The native path handed `extractor.extract().events` straight to applySweep and never
// touched ScoutExtractResults, so it never saw the guard at all. The same show got a different verdict
// depending on which door it came through.
//
// LIVE-STORE-CLAIM verified=2026-07-18 measure="sources that have never scouted successfully, and live rows with a missing/placeholder/numeric-id venue"
// This was invisible when #987 shipped because 37 of 38 sources had never successfully scouted, and
// Carnegie (the one that produced prospects) always publishes a venue: measured on the live store then,
// 0 of 132 rows had a missing, placeholder, or numeric-id venue. Re-checked 2026-07-18: 30 of 38 sources
// have since scouted successfully and the store has grown to 313 rows, still with 0 missing a venue, so
// guarding the native path still changes nothing today. It is insurance, and it is the reason #970's
// place-aware venue rule (#979) can be written ONCE rather than forked across two paths that already
// disagree.
//
// The guard's own argument is what settles it, and it is path-independent: a prospect with no venue puts
// the wrong place in Dan's email, and nothing downstream can catch it, because nothing downstream knows
// what the venue was supposed to be. A structured feed that stops naming a facility produces exactly
// that, silently.
@MainActor
@Suite("The native path follows the same usable-event rule (#987)")
struct NativePathGuardTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, WatchedSource.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "NativePathGuardTests-\(UUID().uuidString)")!
    }

    private func event(_ title: String, venue: String?) -> ExtractedEvent {
        ExtractedEvent(title: title, presenter: title, venue: venue,
                       performanceDate: "2099-09-19",
                       sourceUrl: "https://www.carnegiehall.org/Calendar/2099/09/19/\(title)")
    }

    private func runNativeScout(_ events: [ExtractedEvent], into ctx: ModelContext) async throws {
        _ = try await ScoutService.runScout(
            into: ctx,
            extractor: StubSourceExtractor(listing: ExtractedListing(events: events,
                                                                     verdict: .upcomingListings)),
            now: now,
            defaults: defaults())
    }

    private func stored(_ ctx: ModelContext) throws -> [Prospect] {
        try ctx.fetch(FetchDescriptor<Prospect>())
    }

    // The rule, through the native door. A venue-less event from the structured feed must not quietly
    // become a prospect that names no place.
    @Test func aVenuelessNativeEventDoesNotBecomeAProspect() async throws {
        let ctx = try context()

        try await runNativeScout([event("HasVenue", venue: "Stern Auditorium / Perelman Stage"),
                                  event("NoVenue", venue: nil)], into: ctx)

        #expect(try stored(ctx).map(\.groupName) == ["HasVenue"])
    }

    // The Bargemusic shape, through the native door: a feed whose venue field is an id, not a room.
    @Test func aNativeEventWhoseVenueIsAPlaceholderDoesNotBecomeAProspect() async throws {
        let ctx = try context()

        try await runNativeScout([event("Real", venue: "Zankel Hall"),
                                  event("NumericId", venue: "3"),
                                  event("NonAnswer", venue: "TBD")], into: ctx)

        #expect(try stored(ctx).map(\.groupName) == ["Real"])
    }

    // A real venue still sails through. If this ever fails, the guard has started eating the events it
    // exists to protect, and Carnegie is the source that produces every prospect Dan has.
    @Test func realCarnegieVenuesAreUntouched() async throws {
        let ctx = try context()

        try await runNativeScout([event("Stern", venue: "Stern Auditorium / Perelman Stage"),
                                  event("Weill", venue: "Weill Recital Hall"),
                                  event("Zankel", venue: "Zankel Hall"),
                                  event("Offsite", venue: "Jazz at Lincoln Center Shanghai")], into: ctx)

        #expect(try stored(ctx).count == 4)
    }
}

// The dangerous half, and the reason guarding the native path is not a one-line filter.
//
// Dropping an event removes it from the feed the reconcile reads, so a run that threw events away looks
// exactly like a run whose shows were CANCELLED. That is #897/#917's live bug class, the one that has
// bitten this repo three times. The agent path is only safe because it hands its rejectedCount to
// #887's tolerance gate, which then forbids that run from concluding anything is gone.
//
// #1472 changed which SHOW that protection covers on a NATIVE feed, and did not remove it. A blanket
// "this run may cancel nothing" was the right answer while every drop was assumed to be a detail page
// Overture could not open. On a feed parsed row by row there is no detail page to fail: a blank venue is
// the publisher's own empty field (OPERA America leaves 34 of its 92 NY-area rows that way, on every
// scout, forever), and disarming the whole source for it cost National Opera Center its cancellation
// detection permanently, with nothing Dan could do to clear it.
//
// So the protection is now aimed rather than broad, and three separate rules hold it up:
//
//   1. the show behind the blank row is protected precisely, by carrying that row's own listing link into
//      the reconcile as still listed (asserted below, and end to end in StructuralVenueGapTests);
//   2. a feed whose rows are being dropped WHOLESALE also comes back short, and a run too small to be
//      credible as this source's size can still cancel nothing (#897, ShrunkenFeedCannotCancelTests);
//   3. an .html source, whose events really are read page by page, keeps the blanket rule until its own
//      run can say the page publishes no venue (#1469).
//
// A CONTRAST TRIO, and they must be read together: each one is what stops the others being vacuous.
@MainActor
@Suite("What a native run that dropped events may still say (#987/#1472)")
struct NativePathCannotCancelTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, WatchedSource.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // Carnegie's own row, past warmup with a baseline: the exact state in which its silence about a show
    // IS allowed to count against that show. Anything less and the reconcile is disarmed for an
    // unrelated reason and both tests below pass while proving nothing.
    @discardableResult
    private func establishedCarnegie(_ ctx: ModelContext) -> WatchedSource {
        let s = WatchedSource(sourceId: WatchedSource.carnegieId, orgName: "Carnegie Hall",
                              listingsURL: "https://www.carnegiehall.org/Calendar", kind: .algolia)
        s.successfulCheckCount = WatchedSource.warmupRuns
        s.baselineFeedCount = 1
        ctx.insert(s)
        return s
    }

    // A show Carnegie listed last time, which this run does not list.
    @discardableResult
    private func showItListedLastTime(_ ctx: ModelContext) -> Prospect {
        let p = Prospect(naturalKey: "a-show-from-last-time", groupName: "Aurora Strings",
                         discipline: "music", venue: "Weill Recital Hall", performanceDate: "2099-09-19",
                         sourceListingURL: "https://www.carnegiehall.org/Calendar/2099/09/19/Aurora",
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .queued)
        p.sourceIds = [WatchedSource.carnegieId]
        p.missedScoutCount = 0
        ctx.insert(p)
        return p
    }

    private func event(_ title: String, venue: String?) -> ExtractedEvent {
        ExtractedEvent(title: title, presenter: title, venue: venue,
                       performanceDate: "2099-10-01",
                       sourceUrl: "https://www.carnegiehall.org/Calendar/2099/10/01/\(title)")
    }

    private func runNativeScout(_ events: [ExtractedEvent], into ctx: ModelContext) async throws {
        _ = try await ScoutService.runScout(
            into: ctx,
            extractor: StubSourceExtractor(listing: ExtractedListing(events: events,
                                                                     verdict: .upcomingListings)),
            now: now,
            defaults: UserDefaults(suiteName: "NativeCancel-\(UUID().uuidString)")!)
    }

    // #1472: an UNRELATED show is no longer sheltered by somebody else's blank venue field. This feed came
    // back its full size, one of its rows carries no venue, and the show that vanished from it is not that
    // row: nothing about a publisher's empty field says anything about the show that is simply not listed
    // any more, so the run may say so. It is one miss, not a cancellation (goneThreshold is 2), so a single
    // odd run still cannot take a show away on its own.
    //
    // This assertion was the opposite before #1472, and the flip is the whole point: the blanket rule is
    // what left National Opera Center unable to mark ANY of its shows gone, forever, over 34 rows OPERA
    // America publishes with an empty venue on every scout.
    @Test func aNativeRunThatDroppedAnEventCanStillCancelAnUnrelatedShow() async throws {
        let ctx = try context()
        establishedCarnegie(ctx)
        let stranded = showItListedLastTime(ctx)

        try await runNativeScout([event("Kept", venue: "Zankel Hall"),
                                  event("Dropped", venue: nil)], into: ctx)

        #expect(stranded.missedScoutCount == 1)
    }

    // And the show the drop is actually ABOUT keeps its full protection, which is what makes the test above
    // safe rather than merely permissive. Same run, same blank row, but this time the stranded show IS that
    // row's show: it is listed on the calendar right now, with an empty venue field, so it is not gone and
    // must never accrue a miss. Its listing link is what carries that fact into the reconcile.
    @Test func theShowBehindTheBlankRowIsNeverMarkedMissing() async throws {
        let ctx = try context()
        establishedCarnegie(ctx)
        let stranded = showItListedLastTime(ctx)

        try await runNativeScout([event("Kept", venue: "Zankel Hall"),
                                  blankVenueRowFor(stranded)], into: ctx)

        #expect(stranded.missedScoutCount == 0)
    }

    // The blank-venue row for a show already in the store: same listing link, no venue. This is the Tosca
    // shape from #1472, where one production of a run loses its venue while its siblings keep theirs.
    private func blankVenueRowFor(_ p: Prospect) -> ExtractedEvent {
        ExtractedEvent(title: p.groupName, presenter: p.groupName, venue: nil,
                       performanceDate: p.performanceDate, sourceUrl: p.sourceListingURL)
    }

    // The contrast, and the reason the test above is not vacuous. Same source, same stranded show, same
    // healthy verdict. The ONLY difference is that this run threw nothing away, so the reconcile is
    // allowed to speak, and it does.
    //
    // If this ever stops incrementing, the test above has stopped testing anything.
    @Test func aCleanNativeRunDoesMarkLastTimesShowAsMissing() async throws {
        let ctx = try context()
        establishedCarnegie(ctx)
        let stranded = showItListedLastTime(ctx)

        try await runNativeScout([event("Kept", venue: "Zankel Hall")], into: ctx)

        #expect(stranded.missedScoutCount == 1)
    }
}
