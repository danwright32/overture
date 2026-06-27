import Foundation
import SwiftData

// Phase 4 of #112: gather the replies that need an intent read into a work-list, write it, and launch
// the classify run detached (Claude Code on Dan's Max plan). Mirrors PrepQueueService and shares the
// DetachedRunner launch/marker machinery. The app does not supervise the run; it ingests the results
// file later (ReplyClassifyImporter).
@MainActor
enum ReplyClassifyService {
    // A reply needs classifying when the lead has replied, we captured its text, Dan hasn't set the
    // state by hand, and either there's no state yet OR a fresh reply landed after the state was set
    // (so an "actually, yes" turnaround is re-read rather than lost).
    static func needsClassify(_ p: Prospect) -> Bool {
        guard p.outcome == .replied, let text = p.lastReplyText, !text.isEmpty else { return false }
        guard p.conversationStateSource != .manual else { return false }
        if p.conversationState == nil { return true }
        if let replyAt = p.lastReplyAt, let setAt = p.conversationStateSetAt, replyAt > setAt { return true }
        return false
    }

    static func buildQueue(from context: ModelContext, generatedAt: String) -> ReplyClassifyQueue {
        let all = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        let items = all.filter(needsClassify).map { p in
            ReplyClassifyItem(naturalKey: p.naturalKey, groupName: p.groupName,
                              venue: p.venue, replyText: p.lastReplyText ?? "")
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

    static let markerStaleAfter: TimeInterval = 3 * 60

    static var defaultMarkerURL: URL {
        StoreLocation.dataDirectory
            .appendingPathComponent("Overture", isDirectory: true)
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

        let data = try ReplyClassifyQueueBuilder.encode(queue)
        try FileManager.default.createDirectory(at: queueURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: queueURL, options: .atomic)

        try launch()
        try? Data().write(to: markerURL)   // mark in-flight immediately; the script heartbeats/clears it
        return queue.items.count
    }

    private static func launchRunner() throws {
        guard let script = DetachedRunner.scriptURL(defaultsKey: "replyClassifyRunnerScriptPath"),
              FileManager.default.isExecutableFile(atPath: script.path) else {
            throw ClassifyLaunchError.runnerUnavailable
        }
        try DetachedRunner.launch(scriptPath: script.path)
    }
}
