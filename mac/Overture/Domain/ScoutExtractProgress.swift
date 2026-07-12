import Foundation

// Incremental progress the scout-extract run writes as it works through its sources (#799), so the
// scout's live label can show "checking source 3 of 9" instead of a bare spinner. Same shape and same
// one-sided contract as PrepProgress (#354): the shell script seeds it and the detached Claude run
// updates it, neither of which is Swift, so the fixture plus docs/scout-extract-runbook.md is the
// writer's spec (docs/contracts.md).
//
// This exists because of CLAUDE.md's standing rule, not as a nicety: a run that takes minutes must
// make "working", "still alive" and "failed" visibly different states. A spinner that looks the same
// whether the run is progressing, hung, or dead is a defect.
struct ScoutExtractProgress: Codable, Equatable, Sendable {
    var version: Int
    var total: Int
    var completed: Int
}

enum ScoutExtractProgressDecoder {
    static func decode(_ data: Data) throws -> ScoutExtractProgress {
        try JSONDecoder().decode(ScoutExtractProgress.self, from: data)
    }

    static var defaultURL: URL {
        StoreLocation.handoffDirectory
            .appendingPathComponent("overture-scout-extract-progress.json")
    }

    // Best-effort read for the live label: a missing, malformed, or half-written file (the run may be
    // writing it at the exact moment this is called) reads as "nothing to show yet", never as an error
    // and never as a crash.
    static func loadCurrent(from url: URL = defaultURL) -> ScoutExtractProgress? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decode(data)
    }

    // "3 of 9" for the toolbar, or nil when there is nothing meaningful to say yet.
    static func label(from progress: ScoutExtractProgress?) -> String? {
        guard let progress, progress.total > 0 else { return nil }
        return "\(min(progress.completed, progress.total)) of \(progress.total)"
    }
}
