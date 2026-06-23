import Foundation

// Where a Prep run stands, so a finished-but-empty run can be surfaced instead of
// looking identical to "still waiting" (#48). Pure: the view reads the marker and the
// results file's timestamp and asks here what to show.
enum PrepRunPhase: Equatable, Sendable {
    case idle              // no run has been started
    case running           // the in-flight marker is live
    case producedResults   // finished and the results file was refreshed by this run
    case finishedEmpty     // finished but produced no fresh results (failed or empty)
}

enum PrepRunOutcome {
    static func phase(runStartedAt: Date?, running: Bool, resultsModifiedAt: Date?) -> PrepRunPhase {
        guard let started = runStartedAt else { return .idle }
        if running { return .running }
        if let modified = resultsModifiedAt, modified >= started { return .producedResults }
        return .finishedEmpty
    }
}

// The tail of the Prep run log, shown when a run finishes empty so Dan can see why
// rather than guessing. Pure string slice; the file read is a thin wrapper.
enum PrepLog {
    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Overture", isDirectory: true)
            .appendingPathComponent("prep-run.log")
    }

    static func tail(_ n: Int, in text: String) -> String {
        guard n > 0, !text.isEmpty else { return "" }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(n).joined(separator: "\n")
    }

    static func tail(_ n: Int, from url: URL = defaultURL) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return tail(n, in: text)
    }
}
