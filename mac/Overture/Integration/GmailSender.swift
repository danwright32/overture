import Foundation

// The live MailSender: sends an approved draft through the Gmail API as Dan's
// photography account. Called only from Dan's explicit Send action (never
// autonomously). Fully async: it awaits the access token then the send, so a caller on
// the main actor (the Send button) never blocks the main thread. An earlier
// synchronous semaphore bridge deadlocked here: the blocked main thread could not
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
                       fetch: fetch ?? { try await GmailNetworking.session.data(for: $0) },
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
              fetch: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await GmailNetworking.session.data(for: $0) },
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
        signature: OutboundSignature? = nil,
        fetch: (URLRequest) async throws -> (Data, URLResponse) = { try await GmailNetworking.session.data(for: $0) },
        onAuthExpired: () async -> Void = { await GmailAuthManager.shared.signalAuthExpired() }
    ) async throws -> SentReceipt {
        // #2647: nothing is minted here any more. Gmail DISCARDS a client-supplied Message-ID on
        // users/me/messages/send and assigns its own (@mail.gmail.com), measured on the live mailbox
        // 2026-08-13, so a minted value has never been on the wire. Storing it made every In-Reply-To
        // and References Overture later wrote a dangling reference: Gmail's web view still grouped the
        // thread, because the send also passes the internal threadId and Gmail threads server side on
        // that, while every standards based client (Spark, Apple Mail, Outlook) threads purely on the
        // headers and filed a second conversation. The real id is read back below instead.
        //
        // `mail.messageID` is still honoured, for a caller that genuinely supplies one; no production
        // caller does, and on the Gmail path it would be discarded anyway.
        let suppliedMessageID = mail.messageID
        // #1144: attach Dan's signature. Prefer his live styled Gmail signature (stored by
        // GmailSignatureService); if none is stored (fetch never succeeded, or he hasn't re-authorized for
        // the settings scope yet) fall back to the plain-text sign-off and log loudly, rather than sending
        // a signature-less email silently.
        let sig = signature ?? GmailSignatureStore.currentSignature()
        if sig.html == nil {
            // copy-inventory:ignore-start  developer diagnostic log, not the app's own voice (#915)
            // #1689: a NOTE. Sending with the plain-text sign-off is a supported, working path.
            AgentLog.note("[Overture] Sending with the plain-text sign-off: no styled Gmail signature is stored. Reconnect Gmail to fetch it.")
            // copy-inventory:ignore-end
        }
        let raw = GmailMessage.rawField(
            fromName: fromName, fromEmail: fromEmail,
            to: mail.to, subject: mail.subject, body: mail.body,
            signature: sig,
            messageID: suppliedMessageID, inReplyTo: mail.inReplyTo, references: mail.references)

        var req = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/send")!)
        req.httpMethod = "POST"
        // copy-inventory:ignore-start  the HTTP Authorization header Google reads, not a sentence
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // copy-inventory:ignore-end
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
        // #2647: the id of the message Gmail just created, which is what the read back asks for. Read
        // on its own rather than through the threadId fallback below, because that fallback deliberately
        // treats the message id as a stand-in for a missing threadId and this is the message id proper.
        let sentMessageId = json?["id"] as? String
        let realMessageID = await readBackMessageID(
            sentMessageId: sentMessageId, token: token, fetch: fetch)
        if let threadId = (json?["threadId"] as? String) ?? sentMessageId, !threadId.isEmpty {
            return SentReceipt(threadId: threadId, messageID: realMessageID,
                               messageIDDegraded: realMessageID == nil)
        }
        // #483: the send itself succeeded, so this must never throw, but a body we can't read a
        // threadId out of leaves reply watching with nothing to watch. Come back flagged rather
        // than silently empty, so the recipient can be marked degraded instead of just dropped.
        return SentReceipt(threadId: "", messageID: realMessageID, threadIdDegraded: true,
                           messageIDDegraded: realMessageID == nil)
    }

    // #2647: the Message-ID Gmail actually stamped on the message it just sent, or nil.
    //
    // Nil is the whole point of the return type. Falling back to anything (a minted id, the Gmail
    // message id, an empty string) would hand every reader downstream a value indistinguishable from a
    // real one that references a message existing nowhere, which is the defect this exists to end. The
    // caller flags the receipt instead, so a contact whose threading cannot be trusted is visible
    // rather than quietly wrong (L11).
    //
    // Never throws: the SEND already succeeded by the time this runs, and a failure to read a header
    // back must not be reported to Dan as a failure to send an email that has gone.
    // copy-inventory:ignore-start  a Google API URL and developer diagnostic reasons, not the app's own voice (#915)
    @MainActor
    private static func readBackMessageID(
        sentMessageId: String?,
        token: String,
        fetch: (URLRequest) async throws -> (Data, URLResponse)
    ) async -> String? {
        guard let id = sentMessageId, !id.isEmpty,
              let escaped = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/"
                            + escaped + "?format=metadata&metadataHeaders=Message-ID")
        else {
            logReadBackFailure("the send response named no message id")
            return nil
        }
        var req = URLRequest(url: url)
        // The Authorization header Google reads needs no ignore marker of its own: the region opened
        // above already covers this whole function, and a nested pair would CLOSE that region early,
        // leaking every diagnostic below it into the inventory (measured while writing this).
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await fetch(req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            logReadBackFailure("Gmail refused the read back for message \(id)")
            return nil
        }
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let headers = (json?["payload"] as? [String: Any])?["headers"] as? [[String: Any]] ?? []
        // Case insensitively: RFC 2822 header names are, and Gmail returns "Message-Id" as often as
        // "Message-ID", so an exact match would degrade a send that was perfectly fine.
        let value = headers.first {
            ($0["name"] as? String)?.caseInsensitiveCompare("Message-ID") == .orderedSame
        }?["value"] as? String
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else {
            logReadBackFailure("no Message-ID header on message \(id)")
            return nil
        }
        return trimmed
    }

    private static func logReadBackFailure(_ reason: String) {
        AgentLog.note("[Overture] Could not read the sent message's Message-ID back: \(reason). "
                      + "The next message on this conversation will not thread onto it.")
    }
    // copy-inventory:ignore-end
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

