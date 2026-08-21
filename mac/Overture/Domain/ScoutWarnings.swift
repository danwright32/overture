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
// #1027: where a finished scout's warnings go. Pure, so the rule (manual run gets the popup, an
// unattended scheduled run gets only a quiet line, a clean run shows nothing) is tested rather than
// buried in the view's async flow.
enum ScoutWarningsPresentation: Equatable, Sendable {
    case popup(ScoutWarnings)
    case quietLine(String)
    case nothing

    static func decide(_ warnings: ScoutWarnings, auto: Bool) -> ScoutWarningsPresentation {
        guard !warnings.isEmpty else { return .nothing }
        if auto {
            // An auto run he did not start must never pop a modal (Dan's call): a quiet line, or nothing.
            return warnings.quietLine.map(ScoutWarningsPresentation.quietLine) ?? .nothing
        }
        return .popup(warnings)
    }
}

struct ScoutWarnings: Equatable, Sendable {
    var saveFailed: Bool
    var extractLaunchFailure: String?       // the run could not hand changed pages off to be read
    var extractRunFinishedEmpty: String?    // the reader ran and produced nothing (its own shape of failure)
    var failedSources: [ScoutService.SourceResult]   // the actionable per-source failures
    var unqueuedIds: [String]               // results returned under an id we never queued (#857)
    // The established calendars that came back empty (#27). #1531: the sources themselves, so the warning
    // can name them; a Bool here is what forced the popup to say "the calendar feed" about any of 62.
    var silentlyEmptySources: [ScoutService.SourceResult]
    var clientListWarning: String?          // the past-client export was missing/stale (#22/#23)
    // #1190: how many watched sources this run was over budget to check. A real state, not silence: they
    // were NOT checked, so the manual summary offers a one-click re-run rather than letting them go
    // unchecked for weeks while the run reports as done. Always 0 for a scheduled watch-only run, which
    // defers nothing by design.
    var deferredCount: Int = 0

    // #2758 / #2999: shows the run refused to touch because the store could not answer whether their key
    // was free. App-level like `saveFailed`, and for the same reason: nothing is wrong with any source,
    // and there is nothing to fix per-source. It must be SAID, because a run that quietly leaves shows
    // out is indistinguishable from a run that found none (L98).
    var storeUnreadableCount: Int = 0

    // #3074: WHICH shows those were. The count says a run left three shows out; this is the only thing
    // that can say which three when somebody comes to diagnose it, which is what #2999 kept it for. It
    // had four writers in ScoutService and no reader at all until now (L46).
    var storeUnreadableKeys: [String] = []

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

        // #1531: an established source can come back empty in EITHER half, so both are unioned, and a
        // co-listed source seen empty in both is named once. Same shape as the failures above, for the
        // same reason: a run must never list one source twice.
        var seenEmpty = Set<String>()
        var empties: [ScoutService.SourceResult] = []
        for r in native.silentlyEmptySources + (extract?.silentlyEmptySources ?? [])
        where seenEmpty.insert(r.sourceId).inserted {
            empties.append(r)
        }

        // The deferred sources are recorded on whichever outcome the schedule budgeted them out of (the
        // native half, today). Count across both halves so the source of the record cannot change the
        // number Dan sees.
        let deferred = native.sources.filter { $0.state == .deferred }.count
            + (extract?.sources.filter { $0.state == .deferred }.count ?? 0)

        var seenKeys = Set<String>()
        var dedupedKeys: [String] = []
        for key in native.storeUnreadableKeys + (extract?.storeUnreadableKeys ?? [])
        where seenKeys.insert(key).inserted {
            dedupedKeys.append(key)
        }

        return ScoutWarnings(
            saveFailed: native.saveFailed || (extract?.saveFailed ?? false),
            extractLaunchFailure: native.extractLaunchFailure ?? extract?.extractLaunchFailure,
            extractRunFinishedEmpty: finishedEmpty,
            failedSources: failures,
            unqueuedIds: native.unqueuedResultIds + (extract?.unqueuedResultIds ?? []),
            silentlyEmptySources: empties,
            clientListWarning: native.clientListWarning ?? extract?.clientListWarning,
            deferredCount: deferred,
            // Summed across both halves for the same reason the deferred count is: which half refused a
            // row is not a fact about Dan's run.
            storeUnreadableCount: native.storeUnreadable + (extract?.storeUnreadable ?? 0),
            // #3074: deduped rather than summed, unlike the count above, and the difference is real. The
            // count is a tally of REFUSALS and a show refused in both halves was refused twice; this is
            // the list of SHOWS, and naming one twice would read as two shows (the same rule the failures
            // and the empties above follow).
            storeUnreadableKeys: dedupedKeys)
    }

    // #1190: deferred venues make a run NOT clean even when nothing failed. A run that checked 20 of 38
    // healthy sources still has 18 it did not reach, and the manual summary has to open to say so, or
    // that tail could go unchecked indefinitely while every run reports as done.
    var isEmpty: Bool { sections.isEmpty && deferredCount == 0 }

    // One entry per applicable warning, ranked: app-level (most urgent, nothing Dan can fix per-source)
    // first, then the actionable per-source failures, then the informational notes. Show ALL, because a
    // sectioned surface can, and the old single line's precedence only existed because a string cannot
    // hold two messages.
    enum Section: Equatable, Sendable {
        case saveFailed
        // #3074: the keys ride WITH the count rather than in a section of their own, because they are
        // the detail of one fact and a second section would ask Dan to join two boxes up himself.
        case storeUnreadable(Int, [String])
        case extractLaunchFailure(String)
        case readerFinishedEmpty(String)
        case failures([ScoutService.SourceResult])
        case unqueued([String])
        case silentlyEmptyFeed([ScoutService.SourceResult])
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
        case .storeUnreadable(let count, _):
            // #3074: deliberately still just the count. This is ONE line in the masthead for a run Dan
            // did not start, and a natural key is long; the summary he opens is where the list belongs.
            return count == 1
                ? "A show was left out this run because the local store stopped answering. Run the scout again."
                : "\(count) shows were left out this run because the local store stopped answering. Run the scout again."
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
        case .silentlyEmptyFeed(let empties):
            // #1531: named here too. "An established calendar came back empty" sent Dan to the Sources
            // sheet to work out which one, on the one line meant to save him opening anything.
            return empties.count == 1
                ? "\(empties[0].orgName) has listed shows before and came back empty this run."
                : "\(empties.count) established calendars came back empty this run."
        case .pastClientList(let message):
            return message
        }
    }

    var sections: [Section] {
        var out: [Section] = []
        if saveFailed { out.append(.saveFailed) }
        if storeUnreadableCount > 0 {
            out.append(.storeUnreadable(storeUnreadableCount, storeUnreadableKeys))
        }
        if let extractLaunchFailure { out.append(.extractLaunchFailure(extractLaunchFailure)) }
        if let extractRunFinishedEmpty { out.append(.readerFinishedEmpty(extractRunFinishedEmpty)) }
        if !failedSources.isEmpty { out.append(.failures(failedSources)) }
        if !unqueuedIds.isEmpty { out.append(.unqueued(unqueuedIds)) }
        if !silentlyEmptySources.isEmpty { out.append(.silentlyEmptyFeed(silentlyEmptySources)) }
        if let clientListWarning { out.append(.pastClientList(clientListWarning)) }
        return out
    }
}
