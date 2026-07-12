import Testing
import Foundation
import SwiftData
@testable import Overture

// #799 (milestone 22, Phase 1): the extraction contract every source speaks, so the scout can stop
// hardcoding Carnegie (ScoutService.runScout used to open with `CarnegieExtractor().extract()`).
//
// The load-bearing part is NOT the event list. It is the PAGE VERDICT that travels with it.
//
// An empty event list is ambiguous, and the #770 spike proved all three readings occur in the wild:
//   - Heartbeat Opera: a healthy calendar that genuinely has no upcoming shows. Correct, and NORMAL:
//     5 of the spike's 7 real sites were in this state.
//   - musicasacrany.com/concerts: HTTP 200, full of dates, but they are all from 2021. We are on the
//     WRONG PAGE and would happily re-check it forever.
//   - Third Street: the calendar is drawn by JavaScript, so the HTML we fetched contains no event
//     data at all. We are blind and no model can fix that.
//
// All three return []. Only the verdict tells them apart, which is what stops "the source is quiet"
// and "the source is broken" from looking identical to Dan (his stated requirement), and what will
// later decide whether to fall back to a rendered fetch.
//
// The verdict is a routing signal for source HEALTH. It is NOT the upcoming-only filter: #798's guard
// is, and that runs on every scout regardless of what any extractor claims.
@Suite("Source extraction contract (#799)")
struct SourceExtractorTests {
    private func event(_ title: String, _ date: String?) -> ExtractedEvent {
        ExtractedEvent(title: title, presenter: title, venue: "Merkin Hall",
                       performanceDate: date, sourceUrl: "https://org.example/show")
    }

    // A structured feed (Carnegie's Algolia index) can only ever answer two of the four: it returns a
    // forward window of real events, or it returns nothing. It cannot be "on the wrong page" and it
    // cannot be "blind to JavaScript", so it must never claim those verdicts.
    @Test func aStructuredFeedWithEventsReportsUpcomingListings() {
        let listing = ExtractedListing.fromStructuredFeed([event("Indianapolis Children's Choir", "2026-09-19")])
        #expect(listing.verdict == .upcomingListings)
        #expect(listing.events.count == 1)
    }

    @Test func anEmptyStructuredFeedReportsNoDatedContent() {
        let listing = ExtractedListing.fromStructuredFeed([])
        #expect(listing.verdict == .noDatedContent)
        #expect(listing.events.isEmpty)
    }

    // The distinction the whole verdict exists for: three different truths, one empty list.
    @Test func anEmptyListMeansNothingWithoutTheVerdict() {
        let quiet = ExtractedListing(events: [], verdict: .allPast)          // healthy, off-season
        let wrongPage = ExtractedListing(events: [], verdict: .noDatedContent)
        let blind = ExtractedListing(events: [], verdict: .unreadable)

        #expect(quiet.events == wrongPage.events)      // identical event lists...
        #expect(quiet.events == blind.events)
        #expect(quiet.verdict != wrongPage.verdict)    // ...and completely different meanings
        #expect(quiet.verdict != blind.verdict)

        // Only one of these is a source that is working correctly.
        #expect(quiet.isHealthy)
        #expect(!wrongPage.isHealthy)
        #expect(!blind.isHealthy)
    }

    // A source that returned events is healthy whatever else is true: it did its job.
    @Test func aSourceThatReturnedEventsIsHealthy() {
        #expect(ExtractedListing(events: [event("A", "2026-09-19")], verdict: .upcomingListings).isHealthy)
    }

    // The verdict rides across the JSON handoff to the detached extract run and back, so it has to
    // survive a round trip with a stable wire spelling. A renamed case would silently become a
    // decode failure (which reads as "the source is broken") on Dan's real store.
    @Test func theVerdictHasAStableWireSpelling() throws {
        #expect(PageVerdict.upcomingListings.rawValue == "upcoming_listings")
        #expect(PageVerdict.allPast.rawValue == "all_past")
        #expect(PageVerdict.noDatedContent.rawValue == "no_dated_content")
        #expect(PageVerdict.unreadable.rawValue == "unreadable")

        for v in PageVerdict.allCases {
            let data = try JSONEncoder().encode(v)
            #expect(try JSONDecoder().decode(PageVerdict.self, from: data) == v)
        }
    }

    // The protocol is what lets the scout iterate sources instead of naming Carnegie, and what lets
    // every extraction rule be a real Swift unit test with no network (StubSourceExtractor).
    @Test func anyExtractorCanStandInForAnother() async throws {
        let stub = StubSourceExtractor(listing: ExtractedListing(
            events: [event("Brooklyn Youth Chorus", "2026-09-19")], verdict: .upcomingListings))
        let extractor: any SourceExtractor = stub

        let listing = try await extractor.extract()

        #expect(listing.events.first?.title == "Brooklyn Youth Chorus")
        #expect(listing.verdict == .upcomingListings)
    }

    // A source that throws is not a source that returned nothing. Fail loud: the caller must be able
    // to tell "I could not reach this page" apart from "this page has no shows".
    @Test func anExtractorThatCannotReachItsSourceThrows() async {
        let stub = StubSourceExtractor(error: StubSourceExtractor.Failure.unreachable)
        await #expect(throws: StubSourceExtractor.Failure.self) {
            _ = try await stub.extract()
        }
    }
}

// The seam actually wired into the scout: `runScout` no longer names Carnegie, it takes whatever
// source it is given (defaulting to Carnegie, still the only one that exists until Phase 2).
//
// This exercises the FAILURE path on purpose, and it is the only half of runScout that is safe to
// drive from a test: the extractor is the FIRST thing runScout touches, so a source that cannot be
// reached short-circuits before runScout records a scout timestamp or a feed-health baseline into the
// real app's UserDefaults. (That is also why the rest of the scout is tested through `apply`, which
// takes its inputs injected and touches nothing global.)
//
// The behavior under test is the one that matters for a watchlist: a source that fails must be NAMED,
// never quietly become "this source returned no events". Those are opposite facts about a source's
// health, and conflating them is how a dead source hides behind a quiet off-season.
//
// #802 changed the MECHANISM and kept the principle. It used to throw, which was right when there was
// one source and its failure meant the run had nothing left to do. With a watchlist, throwing means
// source 9 being down silently costs Dan sources 10 through 20. So the failure is now typed, written
// onto that source's row, and reported by name in the outcome, and the run carries on.
@MainActor
@Suite("Scout source injection (#799, #802)")
struct ScoutSourceInjectionTests {
    @Test func runScoutUsesTheSourceItIsGivenAndNamesItsFailureWithoutKillingTheRun() async throws {
        let ctx = ModelContext(try ModelContainer(
            for: Schema([Prospect.self, WatchedSource.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
        let carnegie = WatchedSource(sourceId: WatchedSource.carnegieId, orgName: "Carnegie Hall",
                                     kind: .algolia)
        ctx.insert(carnegie)
        let stub = StubSourceExtractor(error: StubSourceExtractor.Failure.unreachable)
        let scratch = UserDefaults(suiteName: "ScoutSourceFailureTests")!
        scratch.removePersistentDomain(forName: "ScoutSourceFailureTests")

        let outcome = try await ScoutService.runScout(into: ctx, extractor: stub, defaults: scratch)

        #expect(stub.callCount == 1)     // the injected source really is the one the scout asked
        #expect(try ctx.fetch(FetchDescriptor<Prospect>()).isEmpty)   // and nothing was written

        // The failure is a NAMED fact about this source, not an absence of events.
        #expect(outcome.failedSources.map(\.sourceId) == [WatchedSource.carnegieId])
        #expect(outcome.warning?.contains("Carnegie Hall") == true)
        #expect(carnegie.health == .failing)
        #expect(carnegie.lastFailure != nil)

        // And it stays watched. Only an org's refusal or Dan's own removal takes a source off the list.
        #expect(carnegie.isActive)

        // Crucially, NOT the empty-feed warning: "we could not reach it" and "it had nothing on" are
        // the two facts this whole design exists to keep apart.
        #expect(outcome.warning?.localizedCaseInsensitiveContains("data format") == false)

        scratch.removePersistentDomain(forName: "ScoutSourceFailureTests")
    }

    // The rule the loop exists for: one source going down must not cost Dan the rest of his watchlist.
    @Test func oneSourceFailingDoesNotStopTheOthersFromBeingChecked() async throws {
        let ctx = ModelContext(try ModelContainer(
            for: Schema([Prospect.self, WatchedSource.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
        ctx.insert(WatchedSource(sourceId: WatchedSource.carnegieId, orgName: "Carnegie Hall",
                                 kind: .algolia))
        for org in ["broken", "fine"] {
            ctx.insert(WatchedSource(sourceId: org, orgName: org,
                                     listingsURL: "https://\(org).example/events", kind: .html))
        }
        let scratch = UserDefaults(suiteName: "ScoutLoopTests")!
        scratch.removePersistentDomain(forName: "ScoutLoopTests")

        let stub = StubSourceExtractor(listing: ExtractedListing(events: [], verdict: .upcomingListings))
        let outcome = try await ScoutService.runScout(
            into: ctx, extractor: stub,
            fetch: { url in
                if url.absoluteString.contains("broken") { throw SourceFetchError.http(500) }
                return FetchedPage(normalizedHTML: "<p>shows</p>", finalURL: url.absoluteString,
                                   contentHash: "new")
            },
            // #849: STUBBED. These defaulted to the real ScoutPagePin.write and the real
            // ScoutExtractService.startExtract, so this test pinned a page into Dan's live handoff
            // directory and launched a real, token-spending Claude run on every single run of the suite,
            // including CI. The stale results file it left behind is what later hung his Add-a-lead sheet.
            pin: { _, id in URL(fileURLWithPath: "/tmp/\(id).html") },
            launch: { _ in },
            defaults: scratch)

        // Every source is accounted for. The run did not stop at the broken one.
        #expect(outcome.sources.count == 3)
        #expect(outcome.failedSources.map(\.sourceId) == ["broken"])

        let fine = outcome.sources.first { $0.sourceId == "fine" }
        #expect(fine?.state == .queuedForReading)   // its page changed and Dan started this run

        scratch.removePersistentDomain(forName: "ScoutLoopTests")
    }

    // Dan's 4th decision, at the level of the whole run: the automatic daily scout checks every source
    // and reads none of them. It costs nothing, and a dead source is still noticed within a day.
    @Test func theAutomaticDailyRunChecksEverySourceAndReadsNone() async throws {
        let ctx = ModelContext(try ModelContainer(
            for: Schema([Prospect.self, WatchedSource.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
        ctx.insert(WatchedSource(sourceId: "org", orgName: "Org",
                                 listingsURL: "https://org.example/events", kind: .html))
        let scratch = UserDefaults(suiteName: "ScoutWatchOnlyTests")!
        scratch.removePersistentDomain(forName: "ScoutWatchOnlyTests")

        let stub = StubSourceExtractor(listing: ExtractedListing(events: [], verdict: .upcomingListings))
        let outcome = try await ScoutService.runScout(
            into: ctx, depth: .watchOnly, extractor: stub,
            fetch: { url in
                FetchedPage(normalizedHTML: "<p>new shows</p>", finalURL: url.absoluteString,
                            contentHash: "changed")
            },
            pin: { _, id in URL(fileURLWithPath: "/tmp/\(id).html") },   // #849
            launch: { _ in },
            defaults: scratch)

        let org = outcome.sources.first { $0.sourceId == "org" }
        #expect(org?.state == .changedNotRead)   // noticed, flagged, and not a token spent on it

        scratch.removePersistentDomain(forName: "ScoutWatchOnlyTests")
    }

    // The SUCCESS path of the scout's entry point, which had no test at all: a source returns shows,
    // and they land in the store through the real classify/assemble/upsert chain.
    //
    // It was untestable rather than untested. `runScout` recorded the last-scout time and the
    // feed-health baseline into `UserDefaults.standard`, which under the test host is the LIVE app's
    // own preference domain, so running it from a test would have scribbled on Dan's real app. The
    // stored settings are injected now, so the whole run drives against a scratch domain instead.
    //
    // This matters ahead of Phase 4, which turns this same function into the loop that walks every
    // watched source. Better to have the seam before it becomes the most important function in the
    // feature than to bolt it on after.
    @Test func runScoutImportsWhatTheSourceReturnsWithoutTouchingTheLiveAppsSettings() async throws {
        let ctx = ModelContext(try ModelContainer(
            for: Schema([Prospect.self, WatchedSource.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
        let scratch = UserDefaults(suiteName: "ScoutSourceInjectionTests")!
        scratch.removePersistentDomain(forName: "ScoutSourceInjectionTests")

        // Carnegie's row, as the #800 backfill leaves it on a real store.
        let carnegie = WatchedSource(sourceId: WatchedSource.carnegieId, orgName: "Carnegie Hall",
                                     kind: .algolia)
        ctx.insert(carnegie)

        let stub = StubSourceExtractor(listing: ExtractedListing(
            events: [ExtractedEvent(title: "Indianapolis Children's Choir",
                                    presenter: "Indianapolis Children's Choir",
                                    venue: "Merkin Hall", performanceDate: "2099-09-19",
                                    sourceUrl: "https://org.example/show")],
            verdict: .upcomingListings))

        let outcome = try await ScoutService.runScout(into: ctx, extractor: stub, defaults: scratch)

        #expect(outcome.found == 1)
        #expect(outcome.inserted == 1)
        #expect(try ctx.fetch(FetchDescriptor<Prospect>()).count == 1)

        // The last-scout time still goes to the scratch domain, which is the whole point of injecting
        // it: the live app's own is untouched by the suite.
        #expect(ScoutService.lastScoutedAt(in: scratch) != nil)

        // #801: the FEED HEALTH no longer goes to a global key at all. It is folded into the source's
        // own row, which is what lets a second source's dead scraper stop being masked by this one's
        // big season.
        #expect(carnegie.baselineFeedCount == 1)
        #expect(carnegie.successfulCheckCount == 1)
        #expect(carnegie.health == .ok)
        #expect(carnegie.lastSucceededAt != nil)
        #expect(ScoutService.lastHealthyFeedCount(in: scratch) == 0)   // the old global key is dead

        scratch.removePersistentDomain(forName: "ScoutSourceInjectionTests")
    }

    // A source cannot mark anything gone until it has a feed history of its own. One successful check is
    // not a history: this run is the FIRST, so the show it did not list this time cannot be cancelled on
    // its say-so. Without the warmup, a brand-new source's first big import would look like a mass
    // cancellation on its second run.
    @Test func aSourceOnItsFirstCheckCannotMarkAnythingGone() async throws {
        let ctx = ModelContext(try ModelContainer(
            for: Schema([Prospect.self, WatchedSource.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
        let scratch = UserDefaults(suiteName: "ScoutWarmupTests")!
        scratch.removePersistentDomain(forName: "ScoutWarmupTests")

        ctx.insert(WatchedSource(sourceId: WatchedSource.carnegieId, orgName: "Carnegie Hall",
                                 kind: .algolia))
        let stored = Prospect(naturalKey: "already-here", groupName: "Already Here", discipline: "music",
                              venue: "Weill Recital Hall", performanceDate: "2099-12-01",
                              sourceListingURL: "https://www.carnegiehall.org/event/here",
                              websiteURL: nil, priorRelationship: "none", production: "self",
                              profile: "strong", coverage: "likely_uncovered", fitScore: 5, tier: "mid",
                              fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                              possibleMatchName: nil)
        stored.sourceIds = [WatchedSource.carnegieId]
        ctx.insert(stored)

        // A perfectly healthy feed that simply does not list the stored show.
        let stub = StubSourceExtractor(listing: ExtractedListing(
            events: [ExtractedEvent(title: "Someone Else", presenter: "Someone Else",
                                    venue: "Merkin Hall", performanceDate: "2099-09-19",
                                    sourceUrl: "https://org.example/other")],
            verdict: .upcomingListings))

        _ = try await ScoutService.runScout(into: ctx, extractor: stub, defaults: scratch)

        #expect(stored.missedScoutCount == 0)
        #expect(stored.disappearedFromFeed == false)

        scratch.removePersistentDomain(forName: "ScoutWarmupTests")
    }
}

// The test double the plan calls for, so every extraction rule downstream is testable without a
// network, a browser, or a detached Claude run.
final class StubSourceExtractor: SourceExtractor, @unchecked Sendable {
    enum Failure: Error { case unreachable }

    private let listing: ExtractedListing?
    private let error: Error?
    private(set) var callCount = 0

    init(listing: ExtractedListing) {
        self.listing = listing
        self.error = nil
    }

    init(error: Error) {
        self.listing = nil
        self.error = error
    }

    func extract() async throws -> ExtractedListing {
        callCount += 1
        if let error { throw error }
        return listing ?? ExtractedListing(events: [], verdict: .unreadable)
    }
}
