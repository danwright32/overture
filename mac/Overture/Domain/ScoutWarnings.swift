import Foundation

// #1027: everything a finished scout has to say to Dan, as structured data rather than one string.
//
// It exists for two reasons the old `Outcome.warning` string could not serve. First, a scout has two
// halves that finish minutes apart (the native Carnegie sweep, then the detached calendar read), and a
// warning drawn from only the first half either fired mid-run, reading as "the whole thing is done", or
// lost what the second half found. This accumulates BOTH. Second, a single line could show only the
// highest-priority warning; a sectioned popup shows every applicable one, so a per-source failure is no
// longer hidden behind a save failure it happens to share a run with.
//
// The sentences themselves live in the view (copy inventory), except the ones that already exist as
// strings on the outcome (the reader-not-configured line, the past-client line, the reader-finished-empty
// line): those travel as-is so there is one wording, not two.
struct ScoutWarnings: Equatable, Sendable {
    var saveFailed: Bool
    var extractLaunchFailure: String?       // the run could not hand changed pages off to be read
    var extractRunFinishedEmpty: String?    // the reader ran and produced nothing (its own shape of failure)
    var failedSources: [ScoutService.SourceResult]   // the actionable per-source failures
    var unqueuedIds: [String]               // results returned under an id we never queued (#857)
    var silentlyEmptyFeed: Bool             // an established feed came back empty (#27)
    var clientListWarning: String?          // the past-client export was missing/stale (#22/#23)

    static func from(native: ScoutService.Outcome, extract: ScoutService.Outcome?,
                     finishedEmpty: String?) -> ScoutWarnings {
        // Union the per-source failures from both halves and dedupe by id: html verdict failures reach
        // only the extract half, fetch failures only the native half, so the two sets are disjoint by
        // construction, but a co-listed source must never be listed twice.
        var seen = Set<String>()
        var failures: [ScoutService.SourceResult] = []
        for r in native.failedSources + (extract?.failedSources ?? []) where seen.insert(r.sourceId).inserted {
            failures.append(r)
        }

        return ScoutWarnings(
            saveFailed: native.saveFailed || (extract?.saveFailed ?? false),
            extractLaunchFailure: native.extractLaunchFailure ?? extract?.extractLaunchFailure,
            extractRunFinishedEmpty: finishedEmpty,
            failedSources: failures,
            unqueuedIds: native.unqueuedResultIds + (extract?.unqueuedResultIds ?? []),
            silentlyEmptyFeed: native.silentlyEmptyFeed || (extract?.silentlyEmptyFeed ?? false),
            clientListWarning: native.clientListWarning ?? extract?.clientListWarning)
    }

    var isEmpty: Bool { sections.isEmpty }

    // One entry per applicable warning, ranked: app-level (most urgent, nothing Dan can fix per-source)
    // first, then the actionable per-source failures, then the informational notes. Show ALL, because a
    // sectioned surface can, and the old single line's precedence only existed because a string cannot
    // hold two messages.
    enum Section: Equatable, Sendable {
        case saveFailed
        case extractLaunchFailure(String)
        case readerFinishedEmpty(String)
        case failures([ScoutService.SourceResult])
        case unqueued([String])
        case silentlyEmptyFeed
        case pastClientList(String)
    }

    var sections: [Section] {
        var out: [Section] = []
        if saveFailed { out.append(.saveFailed) }
        if let extractLaunchFailure { out.append(.extractLaunchFailure(extractLaunchFailure)) }
        if let extractRunFinishedEmpty { out.append(.readerFinishedEmpty(extractRunFinishedEmpty)) }
        if !failedSources.isEmpty { out.append(.failures(failedSources)) }
        if !unqueuedIds.isEmpty { out.append(.unqueued(unqueuedIds)) }
        if silentlyEmptyFeed { out.append(.silentlyEmptyFeed) }
        if let clientListWarning { out.append(.pastClientList(clientListWarning)) }
        return out
    }
}
