import Foundation

// #857: treat a run's results file as untrusted input. Every rule in the runner's prompt (echo the
// sourceId, judge the page with exactly one verdict, never invent an event, write the results) is
// enforced by nothing but hope, and when a run quietly ignores one the failure is silent and often
// plausible-looking. This is the cheapest, highest-value check: does a source's VERDICT agree with the
// EVENTS it returned? Four of the six verdicts are claims that the page had nothing upcoming to hand
// back, so a run that makes one of them and still returns shows is disagreeing with itself, and its
// result cannot be trusted enough to ingest.
//
// `upcoming_listings` with NO events is deliberately NOT a contradiction: an empty upcoming_listings is a
// documented healthy state (a run that read the page, found its shows, and left every one out for a
// reason it explains in its note), the same fact as `all_past` arrived at differently. See
// `ScoutExtractIngestTests.anEmptyButHealthyListingIsNotAFailure`.
//
// `incomplete_extraction` is the other verdict any event count is plausible under: it never claimed the
// page had nothing on it, only that it might not have seen all of it (#1012).
//
// Measured on the RAW events the run returned, before ExtractedEventGuard filters any out: the question
// is what the RUN claimed versus what the RUN handed back, not what survived our own guard.
enum ScoutResultAudit {
    // The reason this result contradicts itself, phrased for Dan to read on the failing source, or nil
    // when the verdict and the events agree.
    static func contradiction(in result: ScoutExtractResult) -> String? {
        let count = result.events.count
        switch result.verdict {
        case .upcomingListings, .incompleteExtraction:
            return nil
        case .allPast:
            guard count > 0 else { return nil }
            return "The run said every listing on this page was in the past but still returned \(shows(count)) from it."
        case .noDatedContent:
            guard count > 0 else { return nil }
            return "The run said this page had no dated listings but still returned \(shows(count)) from it."
        case .unreadable:
            guard count > 0 else { return nil }
            return "The run said this page could not be read but still returned \(shows(count)) from it."
        case .notRead:
            guard count > 0 else { return nil }
            return "The run said it never read this page but still returned \(shows(count)) from it."
        }
    }

    private static func shows(_ n: Int) -> String {
        n == 1 ? "1 show" : "\(n) shows"
    }
}
