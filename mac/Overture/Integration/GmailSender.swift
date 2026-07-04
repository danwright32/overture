import Foundation

// The live MailSender: sends an approved draft through the Gmail API as Dan's
// photography account. Called only from Dan's explicit Send action (never
// autonomously). Fully async: it awaits the access token then the send, so a caller on
// the main actor (the Send button) never blocks the main thread. An earlier
// synchronous semaphore bridge deadlocked here — the blocked main thread could not
// service the @MainActor token work it was waiting on.

struct GmailSender: MailSender {
    var fromName: String = "Dan Wright"
    var fromEmail: String
    // The send dependencies, injectable so the protocol send(_:) the Send button drives is itself
    // testable from the main actor without the network or live auth (#194). Each defaults to nil
    // and falls back to the live implementation below, so production callers construct the sender
    // exactly as before while a test can hand in fakes and still exercise the real send chain.
    var token: (@Sendable () async throws -> String)? = nil
    var fetch: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil
    var onAuthExpired: (@Sendable () async -> Void)? = nil

    func send(_ mail: OutgoingMail) async throws -> SentReceipt {
        try await send(mail,
                       token: token ?? { try await GmailAuthManager.shared.validAccessToken() },
                       fetch: fetch ?? { try await URLSession.shared.data(for: $0) },
                       onAuthExpired: onAuthExpired ?? { await GmailAuthManager.shared.signalAuthExpired() })
    }

    // The full send with its dependencies injected (token provider + fetch + auth-expired hook),
    // so the wiring the Send button actually drives is testable from the main actor without the
    // network or live auth (#145). This is the path whose old synchronous bridge deadlocked, so
    // exercising it on the main actor is what guards against that regression coming back.
    // onAuthExpired has no default here (the main-actor singleton can't be a default in this
    // nonisolated method); the production caller above passes the real hook explicitly.
    func send(_ mail: OutgoingMail,
              token: @Sendable () async throws -> String,
              fetch: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) },
              onAuthExpired: @Sendable () async -> Void = {}) async throws -> SentReceipt {
        let resolved = try await token()
        return try await GmailSender.performSend(
            mail: mail, fromName: fromName, fromEmail: fromEmail, token: resolved,
            fetch: fetch, onAuthExpired: onAuthExpired)
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
        if let threadId = (json?["threadId"] as? String) ?? (json?["id"] as? String), !threadId.isEmpty {
            return SentReceipt(threadId: threadId, messageID: messageID)
        }
        // #483: the send itself succeeded, so this must never throw, but a body we can't read a
        // threadId out of leaves reply watching with nothing to watch. Come back flagged rather
        // than silently empty, so the recipient can be marked degraded instead of just dropped.
        return SentReceipt(threadId: "", messageID: messageID, threadIdDegraded: true)
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

