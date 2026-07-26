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
        // #1503: a Squarespace events collection is read from the publisher's own JSON and never hops to
        // a per-event detail page, so there is no page that could have failed. Rainer Crosett's single
        // upcoming show is exactly this: the feed names no venue for it, which is his data, not a bad
        // read, and counting it as unreadable would push a healthy source toward #1498's false alarm.
        #expect(SourceKind.squarespaceFeed.venueGapsAreStructural)
        #expect(SourceKind.allCases.count == 6, "a new SourceKind must decide whether its venue gaps are structural")
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

    // Half (b), enforced where it is decided: a row that could identify NOTHING cannot protect a stored show,
    // so it is never exempted, however the gap arose. A row with no link but a date is held by the date
    // instead (#1469, below); this is the row that has neither.
    @Test func aVenuelessRowWithNoIdentityAtAllKeepsCountingAgainstReadability() {
        var undated = row("Green Room 42 night", venue: nil, url: nil)
        undated.performanceDate = nil

        let tally = ExtractedEventGuard.rejectionCounts(for: [undated], venueGapsAreStructural: true)

        #expect(tally.structuralGapCount == 0)
        #expect(tally.structuralGapURLs.isEmpty)
        #expect(tally.structuralGapDates.isEmpty)
        #expect(tally.unreadTotal == 1)
    }

    // A linked row contributes its LINK and not its date. The link already identifies the one show the blank
    // row is about, so also recording the night would shelter any sibling that source genuinely cancelled on
    // that date, buying nothing. The weaker key is reserved for rows that have no other (#1469).
    @Test func aLinkedRowIsHeldByItsLinkAndNeverByItsNight() {
        let tally = ExtractedEventGuard.rejectionCounts(
            for: [row("Tosca", venue: nil, url: Self.toscaURL)], venueGapsAreStructural: true)

        #expect(tally.structuralGapURLs == [Self.toscaURL])
        #expect(tally.structuralGapDates.isEmpty)
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
        #expect(source.readabilityNote == "34 of 92 listings named no venue, so Overture left those out of the queue.")
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
        // #1471: and the row says WHICH listing it could not use, so Dan can open the feed's own page and
        // see for himself. Asserted through the real scout, because the count reaching the row and the name
        // reaching it are two separate claims.
        #expect(source.readabilityNote?.hasSuffix("That was Tosca on Mar 14.") == true)
    }

    // The other half of #1472, the stale html-era read left on a converted source, is covered beside its
    // sibling migrations in WatchedSourceBackfillTests.

    // MARK: #1469, the same rule on a page the run reads itself

    // An .html source's rows are read page by page, so the run is the only thing that can tell the two cases
    // apart, and now it does. A row it flags as "the page publishes no venue" is the source's own gap.
    @Test func aRowThePageItselfLeavesVenuelessIsNotAReadingFailure() {
        var placeholder = row("", venue: nil, url: nil)
        placeholder.venueNotPublished = true

        let tally = ExtractedEventGuard.rejectionCounts(for: [placeholder], venueGapsAreStructural: false)

        #expect(tally.structuralGapCount == 1)
        #expect(tally.unreadTotal == 0)
    }

    // The discrimination that makes the flag worth carrying. Identical row, no flag: the run did not say the
    // page publishes no venue, so this is still a detail page it may have failed to open, and it still costs
    // the source its readability exactly as before #1469.
    @Test func aVenuelessRowTheRunDidNotFlagStillCountsAsAnUnreadPage() {
        let unflagged = row("Recital", venue: nil, url: "https://kaufman.example/recital")

        let tally = ExtractedEventGuard.rejectionCounts(for: [unflagged], venueGapsAreStructural: false)

        #expect(tally.unreadTotal == 1)
        #expect(tally.structuralGapCount == 0)
    }

    // Half (b) on a page like Smoke Ring's, where the placeholder row links NOWHERE. Its date is the only
    // identity it carries, so the date is what travels: a show already in the queue on that night, from this
    // source, is still listed. Dan's call (2026-07-24), taking the small cost that a genuinely cancelled show
    // sharing that date with a placeholder would linger rather than be struck.
    @Test func aPlaceholderRowWithNoLinkIsHeldByItsDate() {
        var placeholder = row("", venue: nil, url: nil)
        placeholder.venueNotPublished = true

        let tally = ExtractedEventGuard.rejectionCounts(for: [placeholder], venueGapsAreStructural: false)

        #expect(tally.structuralGapDates == ["2027-03-14"])
        #expect(tally.structuralGapURLs.isEmpty)
    }

    // A date is only evidence about the source that published it. Unioned across every source the way
    // listing URLs are, one venue's placeholder would shelter every other venue's show on that night, which
    // is a far bigger claim than the one this rule is allowed to make.
    @Test func aPlaceholderDateOnlyShelltersShowsFromTheSourceThatPublishedIt() {
        let ours = prospectOn("2027-03-14", sourceId: "smoke-ring-quartet")
        let theirs = prospectOn("2027-03-14", sourceId: "another-venue")
        let report = FeedReconcile.SourceReport(
            sourceId: "smoke-ring-quartet", seenKeys: [], seenSourceURLs: [],
            structuralGapDates: ["2027-03-14"],
            feedCount: 3, baseline: 3, successfulCheckCount: WatchedSource.warmupRuns,
            verdict: .upcomingListings, rejectedCount: 0)
        let theirReport = FeedReconcile.SourceReport(
            sourceId: "another-venue", seenKeys: [], seenSourceURLs: [],
            feedCount: 3, baseline: 3, successfulCheckCount: WatchedSource.warmupRuns,
            verdict: .upcomingListings, rejectedCount: 0)

        FeedReconcile.reconcile(stored: [ours, theirs], reports: [report, theirReport], today: "2027-01-01")

        #expect(ours.missedScoutCount == 0)
        #expect(theirs.missedScoutCount == 1)
    }

    // The cost Dan accepted when he chose the date as identity (2026-07-24), pinned so it is a known price
    // rather than a surprise: a second show from the SAME source on the SAME night as a linkless placeholder
    // is sheltered too, so if that one were genuinely cancelled it lingers in the queue instead of being
    // struck. It is the narrowest over-reach available (one source, one night, only while the placeholder is
    // up), and it errs toward keeping a real show rather than losing one, which is the direction this whole
    // area is deliberately biased.
    @Test func aSecondShowOnThePlaceholdersNightIsShelteredToo() {
        let sameNight = prospectOn("2027-03-14", sourceId: "smoke-ring-quartet")
        let report = FeedReconcile.SourceReport(
            sourceId: "smoke-ring-quartet", seenKeys: [], seenSourceURLs: [],
            structuralGapDates: ["2027-03-14"],
            feedCount: 3, baseline: 3, successfulCheckCount: WatchedSource.warmupRuns,
            verdict: .upcomingListings, rejectedCount: 0)

        FeedReconcile.reconcile(stored: [sameNight], reports: [report], today: "2027-01-01")

        #expect(sameNight.missedScoutCount == 0)
    }

    // The live Smoke Ring shape, through the REAL agent ingest: four rows, one of them the Oct 24 placeholder.
    // The source keeps its cancellation detection and leaves the badge, the placeholder's own show is never
    // struck, and a show that genuinely dropped off the page still is.
    @Test func theLiveSmokeRingPageStopsTrippingTheAlarmAndStillCancels() throws {
        let ctx = try context()
        let source = WatchedSource(sourceId: "smoke-ring-quartet", orgName: "Smoke Ring Quartet",
                                   listingsURL: "https://www.smokeringquartet.com/gigs", kind: .html)
        source.venueLocation = "New York, NY"
        source.successfulCheckCount = WatchedSource.warmupRuns
        source.baselineFeedCount = 3
        ctx.insert(source)
        let placeholderShow = prospectOn("2026-10-24", sourceId: "smoke-ring-quartet")
        let droppedShow = prospectOn("2026-11-08", sourceId: "smoke-ring-quartet")
        ctx.insert(placeholderShow)
        ctx.insert(droppedShow)

        for _ in 1...FeedReconcile.goneThreshold {
            source.pendingContentHash = "hash-\(UUID().uuidString)"
            source.hasUnreadChanges = true
            ScoutExtractIngest.ingest(smokeRingResults(), clients: [], history: [], blocked: .empty,
                                      today: ScoutTestClock.beforeAllFixtures, now: now, into: ctx)
        }

        #expect(source.lastUnreadableCount == 0)
        #expect(source.lastStructuralGapCount == 1)
        #expect(SourceAttention.needsALook(source) == false)
        // The sentence Dan actually reads on this row, and #1469's live case is exactly one placeholder, so
        // the singular is the common path rather than an edge case.
        // #1471: named, so Dan can look the Oct 24 row up on the band's own page. The placeholder has no
        // title at all, so it is named by its act and its night, which is exactly how the page shows it.
        #expect(source.readabilityNote == "1 of 4 listings named no venue, so Overture left it out of the queue."
                + " That was Smoke Ring Quartet on Oct 24.")
        #expect(source.readabilityNoteIsInformationalOnly)
        #expect(placeholderShow.missedScoutCount == 0)
        #expect(placeholderShow.disappearedFromFeed == false)
        #expect(droppedShow.missedScoutCount == FeedReconcile.goneThreshold)
        #expect(droppedShow.disappearedFromFeed)
    }

    // The band's real page, as the run reports it: three rows it read a venue off, and the Oct 24 Palm
    // Springs row the page prints as "Info coming soon" with no title, venue or link.
    private func smokeRingResults() -> ScoutExtractResults {
        func read(_ title: String, _ date: String, _ venue: String) -> ScoutExtractEvent {
            ScoutExtractEvent(title: title, presenter: "Smoke Ring Quartet", venue: venue,
                              performanceDate: date,
                              sourceUrl: "https://www.smokeringquartet.com/gigs/\(date)",
                              location: "New York, NY")
        }
        var placeholder = ScoutExtractEvent(title: "", presenter: "Smoke Ring Quartet", venue: nil,
                                            performanceDate: "2026-10-24", sourceUrl: nil,
                                            location: "Palm Springs, CA")
        placeholder.venueNotPublished = true
        return ScoutExtractResults(
            version: 5, generatedAt: "2026-07-24T14:00:00Z",
            results: [ScoutExtractResult(
                sourceId: "smoke-ring-quartet", verdict: .upcomingListings,
                events: [read("Gotham Chorus Show", "2026-09-11", "Merkin Hall"),
                         read("Harmony Sweepstakes", "2026-10-17", "Merkin Hall"),
                         read("LABBS 50th Convention", "2026-10-30", "Merkin Hall"),
                         placeholder],
                note: "The Oct 24 row is a placeholder.")])
    }

    private func prospectOn(_ date: String, sourceId: String) -> Prospect {
        let p = Prospect(naturalKey: "\(sourceId)-\(date)", groupName: "Smoke Ring Quartet",
                         discipline: "music", venue: "Merkin Hall", performanceDate: date,
                         sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .queued)
        p.sourceIds = [sourceId]
        return p
    }

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
