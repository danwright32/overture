import Foundation
import SwiftData

// Live reply watcher (#40): fetches the Gmail threads of already-sent prospects and marks
// any that received a reply. Read-only Gmail access; never sends. Skips silently when
// Gmail isn't connected or the token can't refresh (auth handling lives in
// GmailAuthManager, #50). The marking decision is the tested ReplyService/ReplyDetection.
@MainActor
struct GmailReplyChecker {
    // #949: Dan's own address (used to tell his sends apart from a stranger's reply) is the same
    // sending identity the send path and the confirmation use, read from the one SendIdentity source
    // so it can never drift from what actually sends.
    var fromEmail: String = SendIdentity.danWright.email

    // #499: returns whether a detected reply's context.save() failed, so the caller can surface
    // it instead of it failing silently. false covers both "nothing to save" and "not connected".
    @discardableResult
    func checkReplies(in context: ModelContext, now: Date = Date()) async -> Bool {
        // #1770: the periodic check is a natural place to notice a credential that died since launch,
        // and it is nowhere near a render path, so it pays for a fresh read.
        guard GmailConnection.shared.refreshedIsConnected(),
              let token = try? await GmailAuthManager.shared.validAccessToken() else { return false }
        return await markReplies(in: context, token: token, now: now)
    }

    // The testable core: with a token in hand and an injected fetch, pull each unresolved
    // sent prospect's thread and mark replies via the tested ReplyService. No auth/connection
    // gating here, so a fake thread response can drive the marking without network (#84).
    @discardableResult
    func markReplies(
        in context: ModelContext,
        token: String,
        now: Date = Date(),
        fetch: (URLRequest) async throws -> (Data, URLResponse) = { try await GmailNetworking.session.data(for: $0) }
    ) async -> Bool {
        let prospects = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        // #1435: hire inquiries ride the SAME reply/bounce pipeline as a single self-thread. `try?`
        // keeps a container that predates Inquiry (an older test harness) working: it just yields none.
        let inquiries = (try? context.fetch(FetchDescriptor<Inquiry>())) ?? []
        let all: [any ReplyWatchable] = prospects.map { $0 as any ReplyWatchable }
            + inquiries.map { $0 as any ReplyWatchable }
        // Watch EVERY sent recipient's own thread (#418 A2), not just the lead's first-send thread,
        // so a reply to any contact is seen. Skip a show only on a MANUAL lead resolution or a booking
        // (a closed show); never on the auto .replied rollup, or a second contact's reply would be missed.
        // An inquiry presents itself here as its own single recipient.
        var threadIds: Set<String> = []
        for p in all {
            if p.replyWatchManualOutcome || p.replyWatchIsBooked { continue }
            for r in p.replyWatchRecipients {
                guard let t = r.gmailThreadId, !t.isEmpty,
                      !r.replyWatchManualOutcome, !r.replyWatchIsBooked else { continue }
                // #2113: a thread that already replied is normally never fetched again. One that replied
                // before the writer was recorded is fetched exactly once more, to learn who wrote, and
                // then falls back out of this set for good.
                guard !r.replied || r.replyFromAddress == nil || r.lastReplyText == nil else { continue }
                threadIds.insert(t)
            }
        }
        guard !threadIds.isEmpty else { return false }

        var threads: [String: Data] = [:]
        for id in threadIds {
            if let data = await fetchThread(id: id, token: token, format: "metadata", fetch: fetch) { threads[id] = data }
        }
        // Full-fetch the body ONLY for threads that actually have a reply (lazy), so the classify
        // workflow (#112) gets the reply text without pulling full bodies for the whole sent list.
        var fullThreads: [String: Data] = [:]
        for (id, data) in threads where ReplyDetection.hasReply(
            fromAddresses: ReplyDetection.fromAddresses(threadJSON: data), selfEmail: fromEmail) {
            if let full = await fetchThread(id: id, token: token, format: "full", fetch: fetch) { fullThreads[id] = full }
        }
        let repliesMarked = ReplyService.detectReplies(in: all, selfEmail: fromEmail, now: now,
                                                       fetchThread: { threads[$0] }, fetchFullThread: { fullThreads[$0] })
        let bouncesMarked = BounceService.detectBounces(in: all, selfEmail: fromEmail, now: now,
                                                        fetchThread: { threads[$0] })
        // #2113: name the writer on threads that replied before any of this was recorded. Runs after
        // detection, so a reply found on this very pass has already named its own writer and is skipped.
        let respondersFilled = ReplyService.backfillResponders(in: all, selfEmail: fromEmail,
                                                               fetchThread: { threads[$0] },
                                                               fetchFullThread: { fullThreads[$0] })
        guard repliesMarked > 0 || bouncesMarked > 0 || respondersFilled > 0 else { return false }
        do {
            try context.save()
            return false
        } catch {
            // #499: replies were detected in memory but couldn't persist.
            return true
        }
    }

    private func fetchThread(
        id: String, token: String, format: String = "metadata",
        fetch: (URLRequest) async throws -> (Data, URLResponse)
    ) async -> Data? {
        // Subject is included alongside From (#398) so a hard-bounce notification can be told
        // apart from a temporary delay purely from metadata, no full-body fetch needed.
        let query = format == "metadata" ? "format=metadata&metadataHeaders=From&metadataHeaders=Subject" : "format=full"
        guard let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/threads/\(id)?\(query)") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await fetch(req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }
}
