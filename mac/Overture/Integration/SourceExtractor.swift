import Foundation

// #799 (milestone 22, Phase 1): the contract every event source speaks.
//
// The scout has only ever had one source, and it named it out loud: `ScoutService.runScout` opened
// with `CarnegieExtractor().extract()`. That worked because Carnegie hands us a clean Algolia JSON
// API. An arbitrary org's events page is unstructured HTML, so a second kind of extractor has to
// exist, and everything downstream of `ExtractedEvent` (classify, match, assemble, rank, group,
// upsert) must stay untouched: one pipeline, not two.

// What the extractor found, and what it makes of the page it found it on.
//
// The verdict is the part that matters, and it exists because AN EMPTY EVENT LIST IS AMBIGUOUS. The
// #770 spike found all three readings live in the wild, and they need opposite responses:
//
//   .allPast          A healthy calendar with nothing upcoming. CORRECT, and normal: 5 of the spike's
//                     7 real sites were in exactly this state in July. Leave it alone; it will have a
//                     season in the autumn.
//   .noDatedContent   The page carries no dated listings at all. Usually the WRONG PAGE (guessing a
//                     URL by convention landed the spike on a 2021 archived concert, HTTP 200), and
//                     we would otherwise re-check it forever, quietly, finding nothing.
//   .unreadable       The bytes we fetched contain no event data because the calendar is drawn by
//                     JavaScript. We are blind. No model can fix this; only a rendered fetch can.
//
// All three return `[]`. Only the verdict tells them apart, and telling them apart is precisely Dan's
// requirement that a broken source never be mistaken for a quiet one.
//
// The verdict routes source HEALTH. It is NOT the upcoming-only filter: #798's guard is, it runs on
// every scout, and it does not trust any extractor's claim about what is upcoming.
enum PageVerdict: String, Codable, Equatable, Sendable, CaseIterable {
    case upcomingListings = "upcoming_listings"
    case allPast = "all_past"
    case noDatedContent = "no_dated_content"
    case unreadable = "unreadable"
}

// Deliberately a plain Sendable struct and never a @Model: `ScoutService` is @MainActor and SwiftData
// models are not Sendable under Swift 6, so a model crossing this boundary would not compile (and
// would be the wrong shape anyway: this is what a source SAID, not what the store believes).
struct ExtractedListing: Equatable, Sendable {
    var events: [ExtractedEvent]
    var verdict: PageVerdict

    // A source that returned events did its job. A source that returned none did its job only if the
    // page genuinely has nothing upcoming; the other two empty verdicts mean it is broken or blind,
    // and Dan has to be told rather than left to assume the season is quiet.
    var isHealthy: Bool {
        if !events.isEmpty { return true }
        return verdict == .allPast
    }

    // A structured feed (Carnegie's Algolia index) can only ever answer two of the four. It queries a
    // forward window, so it cannot be "all past"; it parses JSON, so it cannot be "blind to
    // JavaScript". Deriving the verdict here keeps that honesty in one place rather than letting each
    // feed invent its own.
    static func fromStructuredFeed(_ events: [ExtractedEvent]) -> ExtractedListing {
        ExtractedListing(events: events,
                         verdict: events.isEmpty ? .noDatedContent : .upcomingListings)
    }
}

// The seam. `CarnegieExtractor` is its first conformer and stays on its own Algolia path (its index
// exposes 90 days; its rendered page exposes about three, so forcing it through a generic HTML
// extractor to "remove the special case" would cost 87 days of lead time). The agent-driven HTML
// extractor is the second, and `StubSourceExtractor` in the tests is the third, which is what lets
// every rule downstream be a real unit test with no network.
protocol SourceExtractor: Sendable {
    func extract() async throws -> ExtractedListing
}
