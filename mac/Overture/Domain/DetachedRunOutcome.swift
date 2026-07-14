import Foundation

// Where a detached run stands, so a finished-but-empty run can be surfaced instead of looking
// identical to "still waiting" (#48). Shared by every detached AI run (Prep and the reply-classify
// drafter, #435), since the rule is the same: started? did this run refresh its results?
// Pure: the view reads the marker and the results file's timestamp and asks here what to show.
//
// #472: a deliberately different, narrower vocabulary from RunLiveness (RunProgress.swift), not an
// oversight. RunLiveness answers "what should the UI show right now while something might still be
// in flight" (a continuous, per-second question). This answers "the moment a detached run stopped
// being live, what did it produce" (a one-shot terminal question), only ever asked by a caller that
// has already confirmed the run is no longer running. Evaluated folding them into one vocabulary
// per #472 and deliberately didn't: the two are used in disjoint call sites for different lifecycle
// moments, so a single flat enum would just give each side dead cases it can never see.
enum DetachedRunPhase: Equatable, Sendable {
    case idle              // no run has been started
    case producedResults   // finished and the results file was refreshed by this run
    case finishedEmpty     // finished but produced no fresh results (failed or empty)
}

enum DetachedRunOutcome {
    // No `running` input: every real caller only asks this after its own isRunning() check has
    // already confirmed the run stopped (#472), so a `.running` outcome was dead code, never
    // reachable from anything but a test exercising the parameter directly.
    static func phase(runStartedAt: Date?, resultsModifiedAt: Date?) -> DetachedRunPhase {
        guard let started = runStartedAt else { return .idle }
        if let modified = resultsModifiedAt, modified >= started { return .producedResults }
        return .finishedEmpty
    }

    // #885: the type that decides a run finished EMPTY should also say what that means. All three
    // sentences were assembled inline in RootView's three watcher functions, each concatenating its own
    // log tail with its own ternary, where no test could read any of them.
    //
    // A run that finished empty is not silence. It is the one shape of failure that would otherwise be
    // indistinguishable from a quiet calendar, an inbox with no replies, or a Prep run with nothing to
    // do, which is why each sentence says something different and true about ITS OWN work rather than
    // sharing a generic one.
    enum Kind: Equatable, Sendable { case prep, scoutExtract, replyClassify }

    static func finishedEmptyMessage(_ kind: Kind, tail: String) -> String {
        let lead: String
        switch kind {
        case .prep:
            lead = "The Prep run finished but didn't produce any results. It may have hit an error or found no contacts."
        case .scoutExtract:
            // NOT "the calendars are quiet". Those pages were never read, and saying so is the whole
            // point: a broken read and an empty calendar must never look alike.
            lead = "The scout started reading the calendars that changed, but the run finished without producing anything. Those pages have NOT been read, and it will try them again on the next scout."
        case .replyClassify:
            lead = "The reply drafter finished but didn't produce a draft. It may have hit an error."
        }
        // The reason travels WITH the failure rather than living in a file nobody opens. An empty tail
        // adds nothing, so no heading is ever left dangling over nothing.
        guard !tail.isEmpty else { return lead }
        return lead + "\n\nLast lines of the run log:\n\(tail)"
    }
}

// The tail of a detached run's log, shown when a run finishes empty so Dan can see why rather than
// guessing. Shared by every detached run (#435); each one writes its own log file. Pure string slice;
// the file read is a thin wrapper.
enum RunLog {
    static var prepURL: URL {
        StoreLocation.handoffDirectory.appendingPathComponent("prep-run.log")
    }

    static var replyClassifyURL: URL {
        StoreLocation.handoffDirectory.appendingPathComponent("reply-classify-run.log")
    }

    static var scoutExtractURL: URL {
        StoreLocation.handoffDirectory.appendingPathComponent("scout-extract-run.log")
    }

    static func tail(_ n: Int, in text: String) -> String {
        guard n > 0, !text.isEmpty else { return "" }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(n).joined(separator: "\n")
    }

    static func tail(_ n: Int, from url: URL) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return tail(n, in: text)
    }
}
