import Foundation

// #1034: which source the detached "Reading calendars" phase is reading RIGHT NOW, derived without any
// new file from the runner. The runner writes results in queue order as it finishes each source (the
// #1015 count is script-derived from the same file), so the first queued item not yet present in the
// results file is the one currently in flight.
//
// Deliberately no shell/runbook change: the queue file the app WROTE and the results file the run is
// filling are both already on disk, and diffing them is enough to name the source. That keeps the
// model-facing progress contract (overture-scout-extract-progress.json) exactly as #1015 left it.
enum ScoutExtractCurrentSource {
    // The display name of the source being read now, or nil when every queued source has been reported
    // (the run is finishing) or the queue is empty.
    static func currentName(queue: ScoutExtractQueue, results: ScoutExtractResults?) -> String? {
        let done = Set(results?.results.map(\.sourceId) ?? [])
        guard let next = queue.items.first(where: { !done.contains($0.sourceId) }) else { return nil }
        return displayName(next)
    }

    // orgName is research-only and can be absent (a pasted lead stores no org), so fall back to the
    // listing page's host rather than showing Dan a blank line. Nothing resolvable means nil, and the
    // caller renders no source line at all.
    static func displayName(_ item: ScoutExtractQueueItem) -> String? {
        if let name = item.orgName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        if let listings = item.listingsURL, let host = URL(string: listings)?.host, !host.isEmpty {
            return host
        }
        return nil
    }

    // Best-effort live read for the modal: loads the queue and results the app already owns and names
    // the in-flight source. A missing or half-written file reads as "nothing to show yet", never a crash
    // (mirrors ScoutExtractProgressDecoder.loadCurrent).
    static func loadCurrentName(queueURL: URL = ScoutExtractQueueBuilder.defaultURL,
                                resultsURL: URL = ScoutExtractResultsDecoder.defaultURL) -> String? {
        guard let queueData = try? Data(contentsOf: queueURL),
              let queue = try? JSONDecoder().decode(ScoutExtractQueue.self, from: queueData) else { return nil }
        let results = (try? Data(contentsOf: resultsURL)).flatMap { try? ScoutExtractResultsDecoder.decode($0) }
        return currentName(queue: queue, results: results)
    }
}
