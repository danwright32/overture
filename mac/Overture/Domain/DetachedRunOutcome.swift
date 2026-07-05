import Foundation

// Where a detached run stands, so a finished-but-empty run can be surfaced instead of looking
// identical to "still waiting" (#48). Shared by every detached AI run (Prep and the reply-classify
// drafter, #435), since the rule is the same: started? still live? did this run refresh its results?
// Pure: the view reads the marker and the results file's timestamp and asks here what to show.
enum DetachedRunPhase: Equatable, Sendable {
    case idle              // no run has been started
    case running           // the in-flight marker is live
    case producedResults   // finished and the results file was refreshed by this run
    case finishedEmpty     // finished but produced no fresh results (failed or empty)
}

enum DetachedRunOutcome {
    static func phase(runStartedAt: Date?, running: Bool, resultsModifiedAt: Date?) -> DetachedRunPhase {
        guard let started = runStartedAt else { return .idle }
        if running { return .running }
        if let modified = resultsModifiedAt, modified >= started { return .producedResults }
        return .finishedEmpty
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
