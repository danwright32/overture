import Foundation

// What the scout-extract run hands back (#799): per source, the events it read off the pinned listings
// page, and its VERDICT on that page.
//
// The verdict is the reason this file exists in this shape rather than as a bare list of events. An
// empty event list is ambiguous, and the #770 spike found all three readings live in the wild:
// a healthy calendar with nothing on until autumn (5 of its 7 sites, in July), a page that is simply
// the WRONG one (HTTP 200, full of 2021 dates), and a page whose calendar is drawn by JavaScript so
// the bytes carry no events at all. They need opposite responses, and `[]` cannot tell them apart.
// Without the verdict, "the source is quiet" and "the source is broken" look identical to Dan, which
// is the single thing he said must never happen.
//
// `note` is the run's own one-liner about what made a page hard. It is for Dan to read, never parsed.
struct ScoutExtractResults: Codable, Equatable, Sendable {
    var version: Int
    var generatedAt: String
    var results: [ScoutExtractResult]

    // The USABLE events this run attributed to THIS source. An id the app never queued (a key the run
    // rebuilt instead of echoing) resolves to nothing at all, rather than to somebody else's events: a
    // silent mismatch must read as absence, never as the wrong show.
    //
    // The guard is applied HERE, at the boundary, not left as a helper an ingest might forget to call.
    // Enforcing it by construction is the whole point, because the failure it prevents IS a step being
    // silently skipped: an event with no real venue (Bargemusic's listings page carries numeric venue
    // ids) reads as perfectly well-formed and would put the wrong place in an email. See
    // ExtractedEventGuard.
    //
    // #1126: it also NORMALIZES the recurring-listing date here, at the same boundary and for the same
    // reason the venue guard lives here: a fabricated far-future placeholder (Jalopy's weekly open mic
    // came back dated 2028-03-15) reads as perfectly well-formed and would silently drop the show out of
    // Prep's four-month cutoff and show Dan a wrong date. RecurringEventDate resolves a weekly listing to
    // its next occurrence, or omits the date when no weekday is determinable, so nothing downstream ever
    // sees the placeholder. `today` defaults to the Eastern day so a lead paste needs no clock passed;
    // ScoutExtractIngest passes its own run day so the whole ingest reckons one consistent "today".
    // #1291: `listingsURL` is the source's own listings-page URL. When #1278's guard strips a show's only
    // link because it is a signup form, the show falls back to this instead of being left linkless, so Dan
    // still has a page to open. nil (a caller that has no listings URL to offer) keeps the old drop-to-nil
    // behavior exactly.
    func events(for sourceId: String, today: String = EasternDate.today(),
                listingsURL: String? = nil) -> [ExtractedEvent] {
        rawEvents(for: sourceId)
            .map(ExtractedEventGuard.placed)              // #1214: carry a rescued outdoor venue to the prospect
            // #1278/#1291: drop a signup-form listing link (keep the show), falling back to the listings page.
            .map { ExtractedEventGuard.sanitizedSourceURL($0, listingsURL: listingsURL) }
            .filter(ExtractedEventGuard.isUsable)
            .map { RecurringEventDate.normalized($0, today: today) }
    }

    // What was thrown out, and why, so it can be reported against the source that produced it. A source
    // that returns six shows and not one venue is a source whose detail pages are not being read: that
    // is an actionable fact about the SOURCE. Six quietly venue-less prospects would just poison the
    // queue with emails naming the wrong place.
    func rejectedEvents(for sourceId: String) -> [RejectedEvent] {
        rawEvents(for: sourceId).compactMap { event in
            ExtractedEventGuard.rejection(for: event).map { RejectedEvent(title: event.title, reason: $0) }
        }
    }

    // #1032: the same drops, counted by family (venue vs title), so the Sources note names a titleless
    // drop correctly rather than calling it "no venue". Counted through the SAME guard helper the native
    // door uses, so the two paths can never disagree on the split.
    func rejectionCounts(for sourceId: String) -> RejectionCounts {
        ExtractedEventGuard.rejectionCounts(for: rawEvents(for: sourceId))
    }

    private func rawEvents(for sourceId: String) -> [ExtractedEvent] {
        results.first { $0.sourceId == sourceId }?.events.map(\.asExtractedEvent) ?? []
    }

    func verdict(for sourceId: String) -> PageVerdict? {
        results.first { $0.sourceId == sourceId }?.verdict
    }

    // #1054: how many shows across all sources would survive the guard and could actually land in the
    // queue. This is the honest number the cancel prompt shows Dan, counted through the SAME
    // ExtractedEventGuard the ingest uses, so "read 7 shows" can never disagree with what Keep imports.
    var usableEventCount: Int {
        results.reduce(0) { total, result in
            total + result.events.filter { ExtractedEventGuard.isUsable($0.asExtractedEvent) }.count
        }
    }
}

struct ScoutExtractResult: Codable, Equatable, Sendable {
    var sourceId: String          // echoed verbatim from the queue
    var verdict: PageVerdict
    var events: [ScoutExtractEvent]
    var note: String?             // for Dan to read, never parsed
    // v3 (#897): which of the pinned page's stitched month sections (`<!-- overture-month ... -->`, #858)
    // this run actually read. Optional, so a v1/v2 file written before the run was ever asked for it still
    // decodes and simply carries none. It exists for one job: a stitched multi-month page is a trustworthy
    // feed for reconcile ONLY once the run has read every month the app put in front of it, and the run's
    // own verdict cannot tell "the calendar shrank" from "I read three of the four sections". The app holds
    // the stitched set (it built the pin), compares it to this, and treats a shortfall as a NAMED
    // incomplete read rather than a smaller feed (SweepCoverage). Absent on a single-month page, where the
    // check is inert; irrelevant to any non-paginated source.
    var monthsCovered: [String]? = nil
}

// The wire shape of one event. Deliberately mirrors `ExtractedEvent` field for field, and converts
// straight across: the whole point of #799 is ONE pipeline, so an agent-read event and a Carnegie-read
// event must be the same thing by the time anything downstream sees it. If this ever needs a real
// translation layer, the contract has drifted and the two pipelines have started to grow apart.
struct ScoutExtractEvent: Codable, Equatable, Sendable {
    var title: String
    var presenter: String?
    var venue: String?
    var performanceDate: String?
    var sourceUrl: String?
    // #970: where the page says this show is, VERBATIM, exactly as written. Optional, so a v1 file
    // written before the run was ever asked for one still decodes and simply has no locations.
    var location: String?
    // #1174 (v4): the source's own production id, when it publishes one that ties several performances of
    // one show together (VenueTix tags every night of a run with a shared seriesId). Optional and additive,
    // so a v1/v2/v3 file written before the run was ever asked for it still decodes and simply carries none.
    var seriesId: String?
    // #1469 (v5): the run read this row and the PAGE ITSELF publishes no venue for it yet (a placeholder row,
    // an explicit TBA), as opposed to a detail page the run could not open. Optional and additive, so a
    // v1-v4 file written before the run was ever asked for it still decodes and simply carries none, which is
    // the same outcome as a v5 run whose pages all named their venues.
    var venueNotPublished: Bool?

    var asExtractedEvent: ExtractedEvent {
        ExtractedEvent(title: title, presenter: presenter, venue: venue,
                       performanceDate: performanceDate, sourceUrl: sourceUrl, location: location,
                       seriesId: seriesId, venueNotPublished: venueNotPublished)
    }
}

enum ScoutExtractResultsDecoder {
    static func decode(_ data: Data) throws -> ScoutExtractResults {
        try JSONDecoder().decode(ScoutExtractResults.self, from: data)
    }

    static var defaultURL: URL {
        StoreLocation.handoffDirectory
            .appendingPathComponent("overture-scout-extract-results.json")
    }

    // #1054: throw the partial file away when Dan discards a cancelled read. Deleting it (not merely
    // skipping the import) is what makes discard stick: the reattach path (#1035) re-reads this exact file
    // at the next launch, so a lingering file would silently resurrect the shows he just chose to drop.
    static func discard(at url: URL = defaultURL) {
        try? FileManager.default.removeItem(at: url)
    }
}
