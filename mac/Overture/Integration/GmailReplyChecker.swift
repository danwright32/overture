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
            if let data = await fetchThread(id: id, token: token) { threads[id] = data }
        }
        let marked = ReplyService.detectReplies(in: all, selfEmail: fromEmail, now: now) { threads[$0] }
        if marked > 0 { try? context.save() }
    }

    private func fetchThread(id: String, token: String) async -> Data? {
        guard let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/threads/\(id)?format=metadata&metadataHeaders=From") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }
}
