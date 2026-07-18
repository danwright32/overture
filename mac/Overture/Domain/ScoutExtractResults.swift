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
    func events(for sourceId: String) -> [ExtractedEvent] {
        rawEvents(for: sourceId).filter(ExtractedEventGuard.isUsable)
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

    var asExtractedEvent: ExtractedEvent {
        ExtractedEvent(title: title, presenter: presenter, venue: venue,
                       performanceDate: performanceDate, sourceUrl: sourceUrl, location: location)
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
