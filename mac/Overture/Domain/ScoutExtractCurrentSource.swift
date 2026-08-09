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

// #2216: which sources a run in flight is still going to read.
//
// Dan pressed scout, looked at the Sources sheet nine minutes later, and saw two rows telling him to run
// a scout. He had just run one. It was, at that moment, reading those exact two pages: four detached
// runs were alive, 18 of 30 pages done, and both sources were queued in chunks still working.
//
// Every stored fact on those rows was correct. The fetch had landed and set the unread flag, and the read
// was queued behind a dozen other pages. What was wrong was that one sentence covered two situations:
// nobody is going to read these unless Dan starts a scout, and the scout he started is reading them right
// now. Told the second, he does the reasonable thing and presses scout again, which is how he ran two
// that night. A second press cannot help.
//
// Derived from the same two files ScoutExtractCurrentSource already diffs, so there is no second idea of
// what a run is doing: the queue names every source the run was asked for, and the results file names
// every one it has come back with.
enum ScoutReadInFlight {
    // The sourceIds a live run has been asked for and not yet reported on. Empty when no run is in
    // flight, so a stale queue file left over from a finished run can never speak for one.
    static func sourceIdsStillToRead(isRunning: Bool,
                                     queue: ScoutExtractQueue?,
                                     results: ScoutExtractResults?) -> Set<String> {
        guard isRunning, let queue else { return [] }
        let reported = Set(results?.results.map(\.sourceId) ?? [])
        return Set(queue.items.map(\.sourceId)).subtracting(reported)
    }

    // Best-effort live read, the same degrade-safe shape as loadCurrentName: a missing or half-written
    // file reads as "no run is reading anything", which is the safe direction. It leaves the row asking
    // for a scout, which is only ever a wasted press, where the opposite mistake would hide a source that
    // genuinely needs one.
    static func loadSourceIdsStillToRead(isRunning: Bool,
                                         queueURL: URL = ScoutExtractQueueBuilder.defaultURL,
                                         resultsURL: URL = ScoutExtractResultsDecoder.defaultURL) -> Set<String> {
        guard isRunning else { return [] }
        guard let queueData = try? Data(contentsOf: queueURL),
              let queue = try? JSONDecoder().decode(ScoutExtractQueue.self, from: queueData) else { return [] }
        let results = (try? Data(contentsOf: resultsURL)).flatMap { try? ScoutExtractResultsDecoder.decode($0) }
        return sourceIdsStillToRead(isRunning: true, queue: queue, results: results)
    }
}
