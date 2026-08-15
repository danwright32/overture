import Foundation
import SwiftData

// #2718: Dan says yes. Fetch the conversation he confirmed and hand it to the attach (#2715).
//
// A separate step from the attach itself, and from the sweep that proposed it, because it is the only
// part that needs Gmail at the moment of the click. The proposal is stored in full precisely so the ROW
// needs no Gmail call to ask the question; answering it does, because the attach runs detection over the
// real thread and cannot do that from six stored fields.
@MainActor
struct ConfirmProposedConversation {

    enum Outcome: Equatable {
        case notConnected
        case failed(reason: String)
        case refused(reason: String)
        case attached(alreadyAnswered: Bool, saveFailed: Bool)
    }

    var fromEmail: String = SendIdentity.danWright.email

    // copy-inventory:ignore-start  Google API URLs and an HTTP header, not sentences Overture says (#915)
    static func threadURL(id: String, format: String) -> URL? {
        guard let escaped = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        let query = format == "metadata"
            ? "format=metadata&metadataHeaders=From&metadataHeaders=Subject&metadataHeaders=Message-ID"
            : "format=full"
        return URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/threads/" + escaped + "?" + query)
    }
    // copy-inventory:ignore-end

    func confirm(on r: Recipient, of p: Prospect, in context: ModelContext,
                 now: Date = Date(),
                 token: String? = nil,
                 save: (() throws -> Void)? = nil,
                 fetch: ((URLRequest) async throws -> (Data, URLResponse))? = nil) async -> Outcome {
        guard let candidate = ProposedConversation.stored(on: r) else {
            return .refused(reason: DetachConversationCopy.nothingLinked)
        }
        let live: (URLRequest) async throws -> (Data, URLResponse) = { try await GmailNetworking.session.data(for: $0) }
        let fetcher = fetch ?? live
        var accessToken = token
        if accessToken == nil {
            guard GmailConnection.shared.refreshedIsConnected(),
                  let fresh = try? await GmailAuthManager.shared.validAccessToken() else {
                return .notConnected
            }
            accessToken = fresh
        }
        guard let accessToken else { return .notConnected }

        guard let metadata = await read(Self.threadURL(id: candidate.threadId, format: "metadata"),
                                        token: accessToken, fetch: fetcher) else {
            return .failed(reason: GmailReplySearch.couldNotReachGmail)
        }
        // The bodies, so the attach captures the words in the same write. Best effort: a thread whose
        // full form cannot be read still attaches, exactly as `ReplyService` still detects without it.
        let full = await read(Self.threadURL(id: candidate.threadId, format: "full"),
                              token: accessToken, fetch: fetcher)

        let outcome = AttachConversation.attach(threadId: candidate.threadId, threadJSON: metadata,
                                                fullThreadJSON: full, subject: candidate.subject,
                                                fromAddress: candidate.fromAddress, to: r, on: p,
                                                ledger: ContactRefusal.ledger(in: context),
                                                selfEmail: fromEmail, now: now)
        switch outcome {
        case .refused(let reason):
            // The question stays standing on a refusal. It is still a real question, and taking it down
            // would leave Dan with a row that had silently stopped asking and no record of why.
            return .refused(reason: reason)
        case .attached(_, let alreadyAnswered):
            // The question has been answered, so it comes DOWN rather than being declined: declining
            // would record this conversation as "not them", which is the opposite of what he just said.
            ProposedConversation.clear(on: r)
            var saveFailed = false
            do {
                if let save { try save() } else { try context.save() }
            } catch {
                saveFailed = true
                // copy-inventory:ignore-start  developer diagnostic log, not the app's own voice (#915)
                AgentLog.note("[Overture] Linking the conversation could not save: \(error)")
                // copy-inventory:ignore-end
            }
            return .attached(alreadyAnswered: alreadyAnswered, saveFailed: saveFailed)
        }
    }

    // copy-inventory:ignore-start  an HTTP header, not a sentence (#915)
    private func read(_ url: URL?, token: String,
                      fetch: (URLRequest) async throws -> (Data, URLResponse)) async -> Data? {
        guard let url else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await fetch(req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        return data
    }
    // copy-inventory:ignore-end
}
