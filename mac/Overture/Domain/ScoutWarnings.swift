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

    // #1027: the ONE quiet line an unattended scheduled run leaves in the masthead instead of the popup
    // (Dan's call: an auto run he did not start must never pop a modal at him). The single most urgent
    // section, in a sentence; the Sources sheet holds the detail and the actionable buttons. Manual runs
    // never use this: they get the full sectioned popup.
    var quietLine: String? {
        guard let first = sections.first else { return nil }
        switch first {
        case .saveFailed:
            return "The scout couldn't save its results. Run it again."
        case .extractLaunchFailure:
            return "Some changed calendars couldn't be read this run."
        case .readerFinishedEmpty:
            return "The calendar reader ran but produced nothing this run."
        case .failures(let f):
            return f.count == 1
                ? "A source couldn't be checked. Open Sources to fix or confirm it."
                : "\(f.count) sources couldn't be checked. Open Sources to fix or confirm them."
        case .unqueued:
            return "Some results came back under an unknown source and were ignored this run."
        case .silentlyEmptyFeed:
            return "An established calendar came back empty this run."
        case .pastClientList(let message):
            return message
        }
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
