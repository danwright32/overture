import Foundation

// #1081: incremental progress the reply-classify + reply-drafter run makes as it works through its
// queue, so the reply drafter's "Drafting a reply" label can show real "N of M" progress instead of a
// bare spinner. Same shape and same one-sided contract as PrepProgress (#354) and ScoutExtractProgress
// (#799): the shell script seeds it and then DERIVES every update by counting the results file's own
// entries (lib/progress-watcher.sh, the same helper prep and scout use), so no Claude workflow ever
// writes it. fixtures/reply-classify-progress/ plus docs/reply-classify-runbook.md is the writer's spec
// (docs/contracts.md).
//
// This exists because of CLAUDE.md's standing rule, not as a nicety: a run that takes minutes must make
// "working", "still alive" and "failed" visibly different states. A spinner that looks the same whether
// the run is progressing, hung, or dead is a defect.
struct ReplyClassifyProgress: Codable, Equatable, Sendable {
    var version: Int
    var total: Int
    var completed: Int
}

enum ReplyClassifyProgressDecoder {
    static func decode(_ data: Data) throws -> ReplyClassifyProgress {
        try JSONDecoder().decode(ReplyClassifyProgress.self, from: data)
    }

    static var defaultURL: URL {
        StoreLocation.handoffDirectory.appendingPathComponent("overture-reply-classify-progress.json")
    }

    // Best-effort read for the live label: a missing, malformed, or mid-write file (the run may be
    // writing it at the exact moment this is called) reads as "nothing to show", never a thrown error
    // or a crash.
    static func loadCurrent(from url: URL = defaultURL) -> ReplyClassifyProgress? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decode(data)
    }

    // A short "N of M" label for the reply drafter; nil when there's nothing meaningful yet. `completed`
    // is clamped to `total` so a stray extra entry can never read as more done than was ever asked for.
    static func label(for progress: ReplyClassifyProgress?) -> String? {
        guard let progress, progress.total > 0 else { return nil }
        return "\(min(progress.completed, progress.total)) of \(progress.total)"
    }
}
