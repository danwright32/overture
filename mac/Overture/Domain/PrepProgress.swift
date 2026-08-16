import Foundation

// #354: incremental progress the Prep run writes as it works through its queue, so the toolbar
// can show real "N of M" progress instead of an indefinite spinner. One-sided: the shell script
// seeds it and the Prep run (a Claude Code workflow) updates it, neither of which is Swift, so
// fixtures/prep-progress/ plus docs/prep-runbook.md is the writer's spec (docs/contracts.md).
struct PrepProgress: Codable, Equatable, Sendable {
    var version: Int
    var total: Int
    var completed: Int
}

enum PrepProgressDecoder {
    static func decode(_ data: Data) throws -> PrepProgress {
        try JSONDecoder().decode(PrepProgress.self, from: data)
    }

    static var defaultURL: URL {
        RunSlot.prep.progressURL(in: StoreLocation.handoffDirectory)
    }

    // Best-effort read for the toolbar: a missing, malformed, or mid-write file (the workflow may
    // be writing it at the exact moment this is called) reads as "nothing to show", never a thrown
    // error or a crash.
    static func loadCurrent(from url: URL = defaultURL) -> PrepProgress? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decode(data)
    }

    // A short "N of M" label for the toolbar; nil when there's nothing meaningful yet.
    static func label(for progress: PrepProgress?) -> String? {
        guard let progress, progress.total > 0 else { return nil }
        return "\(progress.completed) of \(progress.total)"
    }
}
