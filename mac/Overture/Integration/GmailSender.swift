import Foundation

// The live MailSender: sends an approved draft through the Gmail API as Dan's
// photography account. Called only from Dan's explicit Send action (never
// autonomously). Synchronous-throwing to satisfy the MailSender protocol; it drives
// the async token + send on a blocking bridge since each send is a single user-paced
// action, not a hot path.

struct GmailSender: MailSender {
    var fromName: String = "Dan Wright"
    var fromEmail: String

    func send(_ mail: OutgoingMail) throws -> SentReceipt {
        try runBlocking {
            let token = try await GmailAuthManager.shared.validAccessToken()
            return try await GmailSender.performSend(
                mail: mail, fromName: fromName, fromEmail: fromEmail, token: token)
        }
    }

    // The testable core: encode the message, POST it, and interpret the response (success,
    // api-error, or auth-expired). The HTTP fetch and the auth-expired hook are injected so a
    // fake response can drive each path without the network or the live token (#84, seam #55).
    @MainActor
    static func performSend(
        mail: OutgoingMail,
        fromName: String,
        fromEmail: String,
        token: String,
        fetch: (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) },
        onAuthExpired: () async -> Void = { await GmailAuthManager.shared.signalAuthExpired() }
    ) async throws -> SentReceipt {
        // Always stamp a Message-ID (use a caller-supplied one, else mint one) so the receipt can
        // hand it back for a future follow-up to thread against (#74).
        let messageID = mail.messageID ?? GmailMessage.newMessageID(senderEmail: fromEmail)
        let raw = GmailMessage.rawField(
            fromName: fromName, fromEmail: fromEmail,
            to: mail.to, subject: mail.subject, body: mail.body,
            messageID: messageID, inReplyTo: mail.inReplyTo)

        var req = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/send")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Including the original threadId tells Gmail to append this message to that conversation
        // (#74), so a follow-up nudge and any reply to it stay on the thread reply detection watches.
        var payload: [String: Any] = ["raw": raw]
        if let threadId = mail.threadId { payload["threadId"] = threadId }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, resp) = try await fetch(req)
        let http = resp as? HTTPURLResponse
        if http?.statusCode == 401 {
            // 401 = the token was revoked/expired since it was issued. Clear it so the
            // app shows as disconnected and prompts a reconnect. NOT 403: Gmail uses
            // 403 for rate limits and permission issues, which a reconnect won't fix
            // and which must not log Dan out mid-batch.
            await onAuthExpired()
            throw GmailSendError.authExpired
        }
        guard let http, (200..<300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? "send failed"
            throw GmailSendError.api(detail)
        }
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let threadId = (json?["threadId"] as? String) ?? (json?["id"] as? String) ?? ""
        return SentReceipt(threadId: threadId, messageID: messageID)
    }
}

enum GmailSendError: LocalizedError {
    case api(String)
    case authExpired
    var errorDescription: String? {
        switch self {
        case .api(let m): return m
        case .authExpired: return "Gmail access expired or was revoked. Click Connect Gmail to reconnect."
        }
    }
}

// Bridges one async send into the synchronous MailSender call. Acceptable because a
// send is a discrete, user-initiated action (one click = one email), not a loop.
private func runBlocking<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
    let sem = DispatchSemaphore(value: 0)
    let box = ResultBox<T>()
    Task {
        do { box.value = .success(try await work()) }
        catch { box.value = .failure(error) }
        sem.signal()
    }
    sem.wait()
    switch box.value! {
    case .success(let v): return v
    case .failure(let e): throw e
    }
}

private final class ResultBox<T>: @unchecked Sendable { var value: Result<T, Error>? }
