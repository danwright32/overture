import Foundation

// Decides whether a sent email's Gmail thread has a reply (#40): any message from an
// address other than Dan's own. Pure so it's testable without the network; the live
// thread fetch lives in the integration layer.
enum ReplyDetection {
    static func hasReply(fromAddresses: [String], selfEmail: String) -> Bool {
        let me = email(from: selfEmail)
        return fromAddresses.contains { raw in
            let e = email(from: raw)
            return !e.isEmpty && e != me && !isAutomated(e)
        }
    }

    // Bounces, postmasters, and no-reply autoresponders aren't real replies; a delivery
    // bounce is the opposite of one. Matched on the local part so a real person isn't
    // excluded by a coincidental domain.
    private static let automatedLocalParts = [
        "mailer-daemon", "postmaster", "no-reply", "noreply",
        "do-not-reply", "donotreply", "auto-reply", "autoreply", "bounce",
    ]
    static func isAutomated(_ email: String) -> Bool {
        let local = email.split(separator: "@").first.map(String.init) ?? email
        return automatedLocalParts.contains { local.contains($0) }
    }

    // The bare email out of a From header ("Name <a@b.com>" or "a@b.com"), lowercased.
    static func email(from raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if let lo = s.firstIndex(of: "<"), let hi = s.firstIndex(of: ">"), lo < hi {
            return String(s[s.index(after: lo)..<hi]).trimmingCharacters(in: .whitespaces).lowercased()
        }
        return s.lowercased()
    }

    // From-header values of every message in a Gmail threads.get (metadata) response.
    static func fromAddresses(threadJSON data: Data) -> [String] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = obj["messages"] as? [[String: Any]] else { return [] }
        return messages.compactMap { m in
            guard let payload = m["payload"] as? [String: Any],
                  let headers = payload["headers"] as? [[String: Any]] else { return nil }
            return headers.first { ($0["name"] as? String)?.lowercased() == "from" }?["value"] as? String
        }
    }

    // The Gmail message id of the newest message from someone other than Dan (skipping automated
    // senders), or nil if there's no real reply. Lets a single auto-detected reply be dismissed (#219)
    // while a genuinely newer reply (a different id) still gets flagged.
    static func latestReplyId(threadJSON data: Data, selfEmail: String) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = obj["messages"] as? [[String: Any]] else { return nil }
        let me = email(from: selfEmail)
        for m in messages.reversed() {
            guard let payload = m["payload"] as? [String: Any],
                  let headers = payload["headers"] as? [[String: Any]] else { continue }
            let from = headers.first { ($0["name"] as? String)?.lowercased() == "from" }?["value"] as? String ?? ""
            let e = email(from: from)
            if e.isEmpty || e == me || isAutomated(e) { continue }
            return m["id"] as? String
        }
        return nil
    }

    // The latest inbound reply's text from a threads.get (format=full) response: the NEWEST message
    // from someone other than Dan (skipping automated senders). Prefers text/plain, falls back to
    // stripped text/html; base64url-decoded and capped. Residual quoted history is left for the
    // classifier (#112) rather than perfectly stripped here. nil if there's no real reply with text.
    static func latestReplyBody(threadJSON data: Data, selfEmail: String, maxLength: Int = 6_000) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = obj["messages"] as? [[String: Any]] else { return nil }
        let me = email(from: selfEmail)
        for m in messages.reversed() {   // messages are oldest-first; walk back to the newest reply
            guard let payload = m["payload"] as? [String: Any],
                  let headers = payload["headers"] as? [[String: Any]] else { continue }
            let from = headers.first { ($0["name"] as? String)?.lowercased() == "from" }?["value"] as? String ?? ""
            let e = email(from: from)
            if e.isEmpty || e == me || isAutomated(e) { continue }
            guard let text = bodyText(from: payload) else { return nil }
            return String(text.prefix(maxLength))
        }
        return nil
    }

    // Best text out of a message payload: prefer text/plain, fall back to stripped text/html.
    private static func bodyText(from payload: [String: Any]) -> String? {
        if let plain = firstPart(payload, mime: "text/plain") { return plain }
        if let html = firstPart(payload, mime: "text/html") { return stripHTML(html) }
        return nil
    }

    // The decoded body of the first part (recursing into multipart) matching the mime type.
    private static func firstPart(_ node: [String: Any], mime: String) -> String? {
        if (node["mimeType"] as? String)?.lowercased() == mime,
           let body = node["body"] as? [String: Any], let b64 = body["data"] as? String,
           let decoded = decodeBase64URL(b64) {
            return decoded
        }
        for p in (node["parts"] as? [[String: Any]]) ?? [] {
            if let found = firstPart(p, mime: mime) { return found }
        }
        return nil
    }

    static func decodeBase64URL(_ s: String) -> String? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        guard let data = Data(base64Encoded: b) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func stripHTML(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
