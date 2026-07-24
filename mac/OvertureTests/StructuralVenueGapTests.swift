import Testing
import Foundation
import SwiftData
@testable import Overture

// #1472: a row that a FEED itself publishes with no venue is not a page Overture failed to read, and must
// not be counted as one.
//
// The live case, measured against OPERA America's Umbraco feed on 2026-07-24: of 93 rows in the NY/NJ/CT
// four-month window, 34 carry an empty `venue` field (27 Glimmerglass, 6 Metropolitan Opera, 1 Chautauqua).
// It is OPERA America's own data entry, it recurs on every scout, and it is per PRODUCTION rather than per
// company: every Met row for Macbeth and La boheme names Lincoln Center while every row of the Met's Tosca
// run is blank. The usable-event guard (#987) rightly refuses to import a venue-less show, but every drop
// then fed #887's 5% tolerance, so 34 of 92 read as a broken scraper. National Opera Center forfeited
// gone-marking permanently and sat in the toolbar badge on every scout, with nothing Dan could do to clear
// it. #1469 is the same defect at small scale (one "Info coming soon" row is 25% of a four-show page).
//
// The rule has TWO halves, and the second is what makes the first safe rather than merely quieter:
//
//   (a) the source itself is the reason the venue is missing. True by construction on a native feed: those
//       adapters parse structured rows and never hop to a per-event detail page, so there is no page that
//       could have failed. An .html source keeps today's behaviour (#1469 is where its run learns to say
//       "the page itself publishes no venue").
//   (b) the dropped row's own listing link is carried into the reconcile as STILL LISTED, so a stored show
//       whose row went blank between runs can never be struck for it. Without (b), dropping the fraction
//       would ship the bug #887 exists to prevent: the Tosca case proves one production's venue can go
//       blank while its siblings keep theirs, and 11 stored National Opera Center prospects are exposed to
//       exactly that.
//
// A row that cannot satisfy (b) is never exempted. VenueTix and OvationTix set `sourceUrl: nil` on every
// row, so a venue-less row from those has no identity to protect a stored show with and keeps counting
// against readability.
@MainActor
@Suite("A feed row the source itself left venue-less (#1472)")
struct StructuralVenueGapTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, WatchedSource.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15
    private static let toscaURL = "https://operaamerica.org/calendar/tosca"
    private static let macbethURL = "https://operaamerica.org/calendar/macbeth"

    private func row(_ title: String, venue: String?, url: String?) -> ExtractedEvent {
        ExtractedEvent(title: title, presenter: "The Metropolitan Opera", venue: venue,
                       performanceDate: "2027-03-14", sourceUrl: url,
                       location: "New York, NY", seriesId: nil)
    }

    // MARK: half (a): which kinds have no detail page to fail

    // The routing question, answered once and exhaustively, so a new feed adapter cannot be added without
    // deciding it. An .html source is read by the paid extract run, which DOES fetch each event's own
    // detail page, so a blank venue there is still a suspected reading failure.
    @Test func onlyANativeFeedsBlankVenueIsTheSourcesOwnData() {
        #expect(SourceKind.html.venueGapsAreStructural == false)
        #expect(SourceKind.algolia.venueGapsAreStructural)
        #expect(SourceKind.operaAmericaFeed.venueGapsAreStructural)
        #expect(SourceKind.venueTixFeed.venueGapsAreStructural)
        #expect(SourceKind.ovationTixFeed.venueGapsAreStructural)
        #expect(SourceKind.allCases.count == 5, "a new SourceKind must decide whether its venue gaps are structural")
    }

    // MARK: the tally

    // The OPERA America shape: one row names Lincoln Center, one is blank. The blank one is counted apart
    // and its link kept, and it does NOT reach the count #887 measures.
    @Test func aVenuelessFeedRowIsCountedApartFromAnUnreadPage() {
        let tally = ExtractedEventGuard.rejectionCounts(
            for: [row("Tosca", venue: nil, url: Self.toscaURL),
                  row("Macbeth", venue: "Lincoln Center for the Performing Arts", url: Self.macbethURL)],
            venueGapsAreStructural: true)

        #expect(tally.unreadTotal == 0)
        #expect(tally.structuralGapCount == 1)
        #expect(tally.structuralGapURLs == [Self.toscaURL])
    }

    // Half (b), enforced where it is decided: a row with no link of its own cannot protect a stored show,
    // so it is never exempted. This is every VenueTix and OvationTix row.
    @Test func aVenuelessRowWithNoLinkOfItsOwnKeepsCountingAgainstReadability() {
        let tally = ExtractedEventGuard.rejectionCounts(
            for: [row("Green Room 42 night", venue: nil, url: nil)],
            venueGapsAreStructural: true)

        #expect(tally.structuralGapCount == 0)
        #expect(tally.structuralGapURLs.isEmpty)
        #expect(tally.unreadTotal == 1)
    }

    // The .html path is untouched by this change. An event whose detail page was never reached comes back
    // venue-less and still costs the source its readability, which is #887 working as designed.
    @Test func anUnreadDetailPageOnAnHtmlSourceStillCountsAgainstReadability() {
        let tally = ExtractedEventGuard.rejectionCounts(
            for: [row("Recital", venue: nil, url: "https://kaufman.example/recital")],
            venueGapsAreStructural: false)

        #expect(tally.unreadTotal == 1)
        #expect(tally.structuralGapCount == 0)
    }

    // Deliberately narrow: only the VENUE family is ever structural. A row with no name at all (no title,
    // no presenter, no venue) is far more likely a broken parse than a publisher's blank field, so it keeps
    // counting even on a native feed.
    @Test func aNamelessFeedRowIsNeverExemptEvenOnANativeFeed() {
        let nameless = ExtractedEvent(title: "", presenter: nil, venue: nil,
                                      performanceDate: "2027-03-14", sourceUrl: Self.toscaURL,
                                      location: nil, seriesId: nil)

        let tally = ExtractedEventGuard.rejectionCounts(for: [nameless], venueGapsAreStructural: true)

        #expect(tally.unreadTotal == 1)
        #expect(tally.structuralGapCount == 0)
    }

    // MARK: what Dan sees

    // The live numbers, on the row and on the badge. 34 blank rows out of 92 is disclosed, in the feed's own
    // terms rather than the detail-page wording (this source has no detail pages), in plain text rather than
    // the gold an actionable problem gets, and it is not work Dan owes anyone.
    @Test func theLiveOperaAmericaRunDisclosesItsBlankRowsWithoutAlarm() throws {
        let ctx = try context()
        let source = operaAmericaSource(ctx)
        source.successfulCheckCount = WatchedSource.warmupRuns
        source.baselineFeedCount = 58

        source.recordSuccessfulRead(events: 58, unreadable: 0, structuralGaps: 34, placed: 58,
                                    feedHealth: .init(baseline: 58, degradedStreak: 0, lastDegradedCount: 0),
                                    now: now)

        #expect(source.lastUnreadableCount == 0)
        #expect(source.lastStructuralGapCount == 34)
        #expect(source.readabilityNote == "34 of 92 listings in the feed named no venue, so Overture left those out of the queue.")
        #expect(source.readabilityNoteIsInformationalOnly)
        #expect(SourceAttention.needsALook(source) == false)
    }

    // The forfeit sentence and the badge are still there for a source that genuinely cannot read its pages.
    // This change must not quiet the alarm it was aimed at.
    @Test func aSourceThatGenuinelyCannotReadItsPagesStillSaysSoInGold() throws {
        let ctx = try context()
        let source = WatchedSource(sourceId: "kaufman", orgName: "Kaufman Music Center",
                                   listingsURL: "https://kaufman.example/events", kind: .html)
        ctx.insert(source)
        source.successfulCheckCount = WatchedSource.warmupRuns
        source.baselineFeedCount = 68

        source.recordSuccessfulRead(events: 68, unreadable: 12, placed: 68,
                                    feedHealth: .init(baseline: 68, degradedStreak: 0, lastDegradedCount: 0),
                                    now: now)

        #expect(source.readabilityNote?.contains("won't mark anything from this source as gone") == true)
        #expect(source.readabilityNoteIsInformationalOnly == false)
        #expect(SourceAttention.needsALook(source))
    }

    // MARK: half (b), wired

    // THE test. A guard and its wiring are two claims (#887 cut its own wire and left 1,829 tests green), so
    // this runs the REAL native scout and asserts both halves of the rule in the same run:
    //
    //   - Tosca's row came back with no venue, so it was not imported. Its stored prospect must survive,
    //     because the row was RIGHT THERE in the feed. That is half (b), and it can only be proven on a run
    //     whose silence is believed.
    //   - Turandot is genuinely gone from the feed, and this run must still be able to say so. Without this
    //     half the test above passes vacuously on any run that simply forfeited its gone-marking, which is
    //     exactly today's broken behaviour.
    @Test func aStoredShowWhoseRowWentBlankSurvivesARunThatCanStillCancel() async throws {
        let ctx = try context()
        let source = operaAmericaSource(ctx)
        source.successfulCheckCount = WatchedSource.warmupRuns
        source.baselineFeedCount = 1                       // this run returns one usable row: full size
        let tosca = storedShow(ctx, key: "tosca-2027-03-14", listingURL: Self.toscaURL)
        let turandot = storedShow(ctx, key: "turandot-2027-03-20", listingURL: "https://operaamerica.org/calendar/turandot")

        let feed = StubSourceExtractor(listing: ExtractedListing(
            events: [row("Tosca", venue: nil, url: Self.toscaURL),
                     row("Macbeth", venue: "Lincoln Center for the Performing Arts", url: Self.macbethURL)],
            verdict: .upcomingListings))

        for _ in 1...FeedReconcile.goneThreshold {
            _ = try await ScoutService.runScout(
                into: ctx,
                extractorRegistry: { _ in feed },
                pin: { _, id in URL(fileURLWithPath: "/tmp/\(id).html") },
                launch: { _ in },
                now: now,
                defaults: UserDefaults(suiteName: "svg-\(UUID().uuidString)")!)
        }

        // Half (b): the blank row's own link was carried into the reconcile, so the show it belongs to is
        // still listed and never accrues a miss.
        #expect(tosca.missedScoutCount == 0)
        #expect(tosca.disappearedFromFeed == false)
        // And the run's silence still means something, which is the capability #1472 restores.
        #expect(turandot.missedScoutCount == FeedReconcile.goneThreshold)
        #expect(turandot.disappearedFromFeed)
        #expect(SourceAttention.needsALook(source) == false)
    }

    // The other half of #1472, the stale html-era read left on a converted source, is covered beside its
    // sibling migrations in WatchedSourceBackfillTests.

    // MARK: fixtures

    @discardableResult
    private func operaAmericaSource(_ ctx: ModelContext) -> WatchedSource {
        let s = WatchedSource(sourceId: "opera-america", orgName: "National Opera Center",
                             listingsURL: "https://operaamerica.org/calendar", kind: .operaAmericaFeed)
        s.venueLocation = "New York, NY"
        ctx.insert(s)
        return s
    }

    @discardableResult
    private func storedShow(_ ctx: ModelContext, key: String, listingURL: String) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: "The Metropolitan Opera", discipline: "music",
                         venue: "Lincoln Center for the Performing Arts", performanceDate: "2027-03-14",
                         sourceListingURL: listingURL, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .queued)
        p.sourceIds = ["opera-america"]
        ctx.insert(p)
        return p
    }
}
