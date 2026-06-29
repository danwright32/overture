import Foundation
import SwiftData

// Phase 4 of #112: gather the replies that need an intent read into a work-list, write it, and launch
// the classify run detached (Claude Code on Dan's Max plan). Mirrors PrepQueueService and shares the
// DetachedRunner launch/marker machinery. The app does not supervise the run; it ingests the results
// file later (ReplyClassifyImporter).
@MainActor
enum ReplyClassifyService {
    // A CONTACT needs classifying + drafting (#420 C2) when it replied, we captured its reply text,
    // Dan hasn't hand-marked it, and either there's no draft yet OR a fresh reply landed after the last
    // draft was requested (so an "actually, yes" turnaround is re-read rather than lost). Per-recipient
    // now, so each contact on a show is queued independently and once (keyed by recipientId), never
    // collapsing to the first replier.
    static func recipientNeedsClassify(_ r: Recipient) -> Bool {
        guard r.replied, let text = r.lastReplyText, !text.isEmpty else { return false }
        guard r.outcomeSource != .manual else { return false }
        if r.replyDraftBody == nil { return true }
        if let repliedAt = r.repliedAt, let requestedAt = r.replyDraftRequestedAt, repliedAt > requestedAt { return true }
        return false
    }

    static func buildQueue(from context: ModelContext, generatedAt: String) -> ReplyClassifyQueue {
        let all = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        var items: [ReplyClassifyItem] = []
        for p in all {
            for r in p.recipients where recipientNeedsClassify(r) {
                items.append(ReplyClassifyItem(naturalKey: p.naturalKey, groupName: p.groupName,
                                               venue: p.venue, performanceDate: p.performanceDate,
                                               replyText: r.lastReplyText ?? "",
                                               recipientId: r.id))   // v3: recipientId + performanceDate (#438) populated
            }
        }
        return ReplyClassifyQueueBuilder.build(from: items, generatedAt: generatedAt)
    }

    enum ClassifyLaunchError: LocalizedError {
        case nothingToClassify, runnerUnavailable, alreadyRunning
        var errorDescription: String? {
            switch self {
            case .nothingToClassify: return "No replies need classifying right now."
            case .runnerUnavailable: return "Couldn't find the reply-classify runner. Make sure Claude Code is installed and the Overture project is set up."
            case .alreadyRunning: return "A reply-classify run is already in progress. Wait for it to finish."
            }
        }
    }

    // Raised for the merged classify+drafter run (#420 C5): a cold Claude Code boot drafting replies for
    // several recipients runs well past the old 3-minute ceiling, so a too-short stale window would let a
    // second run start and clobber the shared results file. The atomic marker lock below is the real
    // guard; this ceiling only frees a genuinely dead run.
    static let markerStaleAfter: TimeInterval = 10 * 60

    static var defaultMarkerURL: URL {
        StoreLocation.handoffDirectory
            .appendingPathComponent("reply-classify-running")
    }

    static func isRunning(markerURL: URL = defaultMarkerURL, now: Date) -> Bool {
        DetachedRunner.isRunning(markerURL: markerURL, now: now, staleAfter: markerStaleAfter)
    }

    @discardableResult
    static func startClassify(from context: ModelContext, now: Date,
                              queueURL: URL = ReplyClassifyQueueBuilder.defaultURL,
                              markerURL: URL = defaultMarkerURL,
                              launch: @MainActor () throws -> Void = launchRunner) throws -> Int {
        guard !isRunning(markerURL: markerURL, now: now) else { throw ClassifyLaunchError.alreadyRunning }

        let stamp = ISO8601DateFormatter().string(from: now)
        let queue = buildQueue(from: context, generatedAt: stamp)
        guard !queue.items.isEmpty else { throw ClassifyLaunchError.nothingToClassify }

        // Take the lock ATOMICALLY (#420 C5): clear any stale marker, then exclusive-create so two
        // near-simultaneous starts can't both proceed and clobber the shared results file. If the
        // exclusive create fails, a racer already holds the lock.
        try FileManager.default.createDirectory(at: markerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: markerURL)
        do {
            try Data().write(to: markerURL, options: .withoutOverwriting)
        } catch {
            throw ClassifyLaunchError.alreadyRunning
        }

        do {
            let data = try ReplyClassifyQueueBuilder.encode(queue)
            try FileManager.default.createDirectory(at: queueURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: queueURL, options: .atomic)
            try launch()   // the script heartbeats/clears the marker from here
        } catch {
            try? FileManager.default.removeItem(at: markerURL)   // release the lock if we never launched
            throw error
        }
        return queue.items.count
    }

    private static func launchRunner() throws {
        guard let script = DetachedRunner.scriptURL(defaultsKey: "replyClassifyRunnerScriptPath"),
              FileManager.default.isExecutableFile(atPath: script.path) else {
            throw ClassifyLaunchError.runnerUnavailable
        }
        try DetachedRunner.launch(scriptPath: script.path, supportDirectory: StoreLocation.handoffDirectory)
    }
}
