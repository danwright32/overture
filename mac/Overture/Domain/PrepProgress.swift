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

    // #2760: per slot, so the check's takeover counts the check's own N of M rather than whatever the
    // prep run last wrote.
    static func progressURL(for slot: RunSlot) -> URL {
        slot.progressURL(in: StoreLocation.handoffDirectory)
    }

    static var defaultURL: URL { progressURL(for: .prep) }

    // Best-effort read for the toolbar: a missing, malformed, or mid-write file (the workflow may
    // be writing it at the exact moment this is called) reads as "nothing to show", never a thrown
    // error or a crash.
    static func loadCurrent(from url: URL = defaultURL) -> PrepProgress? {
        // #2879: through the shared reader, so this read is an explicit decision rather than a `try?`
        // that says nothing. It uses the exemption that does NOT report: the run rewrites this file
        // after every item and this is polled for a live label, so meeting it half-written is the
        // ordinary case.
        HandoffFile.read(at: url, recorder: .readWhileBeingWritten, decode: decode).value
    }

    // A short "N of M" label for the toolbar; nil when there's nothing meaningful yet.
    static func label(for progress: PrepProgress?) -> String? {
        guard let progress, progress.total > 0 else { return nil }
        return "\(progress.completed) of \(progress.total)"
    }
}
