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

    // #2129: one conversation, named. The run drafts every waiting reply in a single detached, paid pass,
    // which is right for the batch it was built for and wrong for a button pressed on ONE reply: it would
    // spend across every other waiting conversation and its Cancel would abandon all of them.
    struct Target: Equatable, Sendable {
        let naturalKey: String
        let recipientId: String
    }

    static func buildQueue(from context: ModelContext, generatedAt: String,
                           only: Target? = nil) -> ReplyClassifyQueue {
        let all = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        var items: [ReplyClassifyItem] = []
        for p in all {
            // A scope that matches nothing yields NOTHING, never the whole batch. Widening a scoped
            // request back to everything is the exact failure this exists to prevent, and it would be
            // invisible: the run would look like it worked, having spent on every other conversation.
            if let only, only.naturalKey != p.naturalKey { continue }
            for r in p.recipients where recipientNeedsClassify(r) {
                if let only, only.recipientId != r.id { continue }
                items.append(ReplyClassifyItem(naturalKey: p.naturalKey, groupName: p.groupName,
                                               venue: p.venue, performanceDate: p.performanceDate,
                                               replyText: r.lastReplyText ?? "",
                                               recipientId: r.id))   // v3: recipientId + performanceDate (#438) populated
            }
        }
        return ReplyClassifyQueueBuilder.build(from: items, generatedAt: generatedAt)
    }

    enum ClassifyLaunchError: LocalizedError {
        case nothingToClassify, alreadyRunning
        // #2838: carries its reason, so it can name the setting that is wrong and what it points at.
        case runnerUnavailable(String)
        var errorDescription: String? {
            switch self {
            case .nothingToClassify: return "No replies need classifying right now."
            case .runnerUnavailable(let reason): return reason
            case .alreadyRunning: return "A reply-classify run is already in progress. Wait for it to finish."
            }
        }
    }

    // Raised for the merged classify+drafter run (#420 C5): a cold Claude Code boot drafting replies for
    // several recipients runs well past the old 3-minute ceiling, so a too-short stale window would let a
    // second run start and clobber the shared results file. The atomic marker lock below is the real
    // guard; this ceiling only frees a genuinely dead run.
    static let markerStaleAfter: TimeInterval = RunTimeouts.replyClassify

    static var defaultMarkerURL: URL {
        StoreLocation.handoffDirectory
            .appendingPathComponent("reply-classify-running")
    }

    // #1038: the cooperative-cancel sentinel. Launched through the same DetachedRunner as scout and prep,
    // so the run has no trackable PID and a hard kill is impossible; the app writes this file and the
    // runner checks for it on each heartbeat tick and stops cleanly. Same predicates (`lib/scout-cancel.sh`)
    // as ScoutExtractService and PrepQueueService.
    static var defaultCancelURL: URL {
        StoreLocation.handoffDirectory.appendingPathComponent("reply-classify-cancel")
    }

    // Ask a running reply-classify run to stop. Writing the sentinel IS the request; the runner reads only
    // its presence, never its contents. Best-effort: if the run has already finished, the next startClassify
    // clears the file so it can never affect a later run.
    static func requestCancel(cancelURL: URL = defaultCancelURL) {
        try? FileManager.default.createDirectory(at: cancelURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? Data().write(to: cancelURL)
    }

    // #2104: sweep a read that DIED rather than finished. Same shape and same shared implementation as
    // Prep's (#1613): the runner removes its own marker on the way out, so a marker still there when the
    // read stops being live means it stopped somewhere it never reached that exit, and Cancel (which
    // writes a sentinel only a live runner reads) can no longer do anything. Judged against THIS run's
    // own window, because a calendar read and a reply draft take nothing like the same time.
    @discardableResult
    static func clearDeadRun(markerURL: URL = defaultMarkerURL, cancelURL: URL = defaultCancelURL,
                             now: Date) -> Bool {
        DetachedRunner.sweepDeadRun(markerURL: markerURL, cancelURL: cancelURL, now: now,
                                    staleAfter: markerStaleAfter)
    }

    static func isRunning(markerURL: URL = defaultMarkerURL, now: Date) -> Bool {
        DetachedRunner.isRunning(markerURL: markerURL, now: now, staleAfter: markerStaleAfter)
    }

    // #1822: the same marker, read for whether it is beating, stale, or gone. A progress screen needs
    // the difference between the last two; `isRunning` cannot carry it.
    static func heartbeat(markerURL: URL = defaultMarkerURL, now: Date) -> RunHeartbeat {
        DetachedRunner.heartbeat(markerURL: markerURL, now: now, staleAfter: markerStaleAfter)
    }

    // When the last classify+drafter run began, so the completion watcher can ask DetachedRunOutcome
    // whether the run refreshed its results or finished empty (#435). Mirrors PrepQueueService; the
    // same plausibility floor collapses an epoch/sentinel timestamp from a fresh store to "never".
    static let lastRunKey = "replyClassifyLastRunStartedAt"

    static var lastRunStartedAt: Date? {
        PrepQueueService.sanitizedLastRun(UserDefaults.standard.object(forKey: lastRunKey) as? Date)
    }

    @discardableResult
    static func startClassify(from context: ModelContext, now: Date,
                              // #2129: nil is the batch run (the at-launch sweep); a Target is one reply
                              // Dan asked for by pressing Draft with AI on it.
                              only: Target? = nil,
                              queueURL: URL = ReplyClassifyQueueBuilder.defaultURL,
                              markerURL: URL = defaultMarkerURL,
                              cancelURL: URL = defaultCancelURL,
                              launch: @MainActor () throws -> Void = launchRunner,
                              // #1923: a started run tells the app it started, so nothing has to poll the
                              // marker to find out. Here rather than at the two call sites (the at-launch
                              // auto run, and a "Draft a reply" click) because a call site that forgot
                              // would leave its run unwatched: no line in the queue, and no ingest when
                              // it finished. Fires only once the launch has actually succeeded.
                              announce: @MainActor () -> Void = { DetachedRunActivity.replyClassify.runStarted() })
    throws -> Int {
        guard !isRunning(markerURL: markerURL, now: now) else { throw ClassifyLaunchError.alreadyRunning }

        let stamp = ISO8601DateFormatter().string(from: now)
        let queue = buildQueue(from: context, generatedAt: stamp, only: only)
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

        // #1038: clear any leftover cancel sentinel before this run starts, so a stale one from a
        // previously cancelled run can never make the new run's heartbeat stop on its first tick. The
        // runner clears it too, as defence in depth.
        try? FileManager.default.removeItem(at: cancelURL)

        do {
            let data = try ReplyClassifyQueueBuilder.encode(queue)
            try FileManager.default.createDirectory(at: queueURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: queueURL, options: .atomic)
            try launch()   // the script heartbeats/clears the marker from here
            UserDefaults.standard.set(now, forKey: lastRunKey)   // for the completion watcher (#435)
            announce()     // #1923: the run is real and launched; tell the app rather than making it look
        } catch {
            try? FileManager.default.removeItem(at: markerURL)   // release the lock if we never launched
            throw error
        }
        return queue.items.count
    }

    private static func launchRunner() throws {
        // #2838: see ScoutExtractService.launchRunner. One rule for all three runs.
        let script: URL
        switch DetachedRunner.resolveRunner(.replyClassify) {
        case .configured(let url), .derivedFromInstalledRepo(let url):
            script = url
        case .unavailable(let configuredPath, let derivedPath):
            throw ClassifyLaunchError.runnerUnavailable(
                RunnerScripts.unavailableMessage(.replyClassify, configuredPath: configuredPath,
                                                 derivedPath: derivedPath))
        }
        try DetachedRunner.launch(scriptPath: script.path, supportDirectory: StoreLocation.handoffDirectory)
    }
}
