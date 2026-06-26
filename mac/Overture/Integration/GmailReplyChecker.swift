import Foundation
import SwiftData

// Live reply watcher (#40): fetches the Gmail threads of already-sent prospects and marks
// any that received a reply. Read-only Gmail access — never sends. Skips silently when
// Gmail isn't connected or the token can't refresh (auth handling lives in
// GmailAuthManager, #50). The marking decision is the tested ReplyService/ReplyDetection.
@MainActor
struct GmailReplyChecker {
    var fromEmail: String = "dan@danwrightphotography.com"

    func checkReplies(in context: ModelContext, now: Date = Date()) async {
        guard GmailAuthManager.shared.isConnected,
              let token = try? await GmailAuthManager.shared.validAccessToken() else { return }
        await markReplies(in: context, token: token, now: now)
    }

    // The testable core: with a token in hand and an injected fetch, pull each unresolved
    // sent prospect's thread and mark replies via the tested ReplyService. No auth/connection
    // gating here, so a fake thread response can drive the marking without network (#84).
    func markReplies(
        in context: ModelContext,
        token: String,
        now: Date = Date(),
        fetch: (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }
    ) async {
        let all = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        let threadIds = Set(all.compactMap { p -> String? in
            guard let t = p.gmailThreadId, !t.isEmpty, p.sentAt != nil,
                  p.outcomeSourceRaw != OutcomeSource.manual.rawValue,
                  p.outcome != .replied, p.outcome != .booked else { return nil }
            return t
        })
        guard !threadIds.isEmpty else { return }

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
        let marked = ReplyService.detectReplies(in: all, selfEmail: fromEmail, now: now,
                                                fetchThread: { threads[$0] }, fetchFullThread: { fullThreads[$0] })
        if marked > 0 { try? context.save() }
    }

    private func fetchThread(
        id: String, token: String, format: String = "metadata",
        fetch: (URLRequest) async throws -> (Data, URLResponse)
    ) async -> Data? {
        let query = format == "metadata" ? "format=metadata&metadataHeaders=From" : "format=full"
        guard let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/threads/\(id)?\(query)") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await fetch(req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }
}
