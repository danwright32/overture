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
        return automatedLocalParts.contains { matchesToken(local, $0) }
    }

    // True when `local` is exactly `token`, or has it as a prefix or suffix set off by a
    // separator (or the string's edge), rather than merely containing it as a substring, so a
    // real address like "bouncebackband" or "eleanoreply" isn't caught while "noreply-support"
    // or "notifications-noreply" still are.
    // Internal (not private): BounceDetection (#398) reuses this same separator-aware token
    // match instead of duplicating it.
    static func matchesToken(_ local: String, _ token: String) -> Bool {
        guard local.count >= token.count else { return false }
        if local.hasPrefix(token) {
            let after = local.index(local.startIndex, offsetBy: token.count)
            if after == local.endIndex || !(local[after].isLetter || local[after].isNumber) { return true }
        }
        if local.hasSuffix(token) {
            let before = local.index(local.endIndex, offsetBy: -token.count - 1, limitedBy: local.startIndex)
            if before == nil || !(local[before!].isLetter || local[before!].isNumber) { return true }
        }
        return false
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

    // #2032: are these the same mailbox? Both sides go through `email(from:)`, so a display name, angle
    // brackets and casing are all handled in one place rather than at each comparison.
    static func isSameAddress(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        let l = email(from: a), r = email(from: b)
        return !l.isEmpty && l == r
    }

    // #2032: the ADDRESS the newest real reply came from, so a thread carrying more than one contact can
    // say which of them wrote. Nil when there is no real reply, exactly as `latestReplyId` is.
    static func latestReplySender(threadJSON data: Data, selfEmail: String) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = obj["messages"] as? [[String: Any]] else { return nil }
        let me = email(from: selfEmail)
        for m in newestFirst(messages) {
            guard let payload = m["payload"] as? [String: Any],
                  let headers = payload["headers"] as? [[String: Any]] else { continue }
            let from = headers.first { ($0["name"] as? String)?.lowercased() == "from" }?["value"] as? String ?? ""
            let e = email(from: from)
            if e.isEmpty || e == me || isAutomated(e) { continue }
            return e
        }
        return nil
    }

    // The Gmail message id of the newest message from someone other than Dan (skipping automated
    // senders), or nil if there's no real reply. Lets a single auto-detected reply be dismissed (#219)
    // while a genuinely newer reply (a different id) still gets flagged.
    static func latestReplyId(threadJSON data: Data, selfEmail: String) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = obj["messages"] as? [[String: Any]] else { return nil }
        let me = email(from: selfEmail)
        for m in newestFirst(messages) {
            guard let payload = m["payload"] as? [String: Any],
                  let headers = payload["headers"] as? [[String: Any]] else { continue }
            let from = headers.first { ($0["name"] as? String)?.lowercased() == "from" }?["value"] as? String ?? ""
            let e = email(from: from)
            if e.isEmpty || e == me || isAutomated(e) { continue }
            return m["id"] as? String
        }
        return nil
    }

    // #2063: who the latest inbound reply was addressed to, so Dan's answer can go to exactly those people
    // rather than to everyone the ORIGINAL email went to. The send group records what Overture did; only
    // the reply itself records what the other side chose, and they differ the moment somebody replies
    // privately or drops a name.
    //
    // Its SENDER plus everyone else it names, minus Dan. The sender is the point: on a reply-all they sit
    // in From and the rest in To/Cc, so taking only To/Cc would answer everybody except the person who
    // actually wrote. Deduped case-insensitively, in the order met, so nobody gets two copies.
    //
    // nil, never an empty array, when there is no real reply to mirror. The caller has to tell "never
    // captured" from a real audience, because that is what decides whether the send falls back.
    static func latestReplyAudience(threadJSON data: Data, selfEmail: String) -> [String]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = obj["messages"] as? [[String: Any]] else { return nil }
        let me = email(from: selfEmail)
        for m in newestFirst(messages) {
            guard let payload = m["payload"] as? [String: Any],
                  let headers = payload["headers"] as? [[String: Any]] else { continue }
            func header(_ name: String) -> String {
                headers.first { ($0["name"] as? String)?.lowercased() == name }?["value"] as? String ?? ""
            }
            let sender = email(from: header("from"))
            if sender.isEmpty || sender == me || isAutomated(sender) { continue }

            var audience: [String] = []
            for address in [sender] + addresses(inHeader: header("to")) + addresses(inHeader: header("cc")) {
                guard !address.isEmpty, address != me, !audience.contains(address) else { continue }
                audience.append(address)
            }
            return audience
        }
        return nil
    }

    // Every bare address in a To/Cc header value, lowercased. A display name may itself contain a comma
    // when quoted ("Wright, Dan" <dan@x>), so a quoted region is held together rather than split inside.
    static func addresses(inHeader raw: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        var inAngles = false
        for ch in raw {
            switch ch {
            case "\"": inQuotes.toggle(); current.append(ch)
            case "<": inAngles = true; current.append(ch)
            case ">": inAngles = false; current.append(ch)
            case "," where !inQuotes && !inAngles:
                parts.append(current); current = ""
            default: current.append(ch)
            }
        }
        parts.append(current)
        return parts.map { email(from: $0) }.filter { !$0.isEmpty }
    }

    // The latest inbound reply's text from a threads.get (format=full) response: the NEWEST message
    // from someone other than Dan (skipping automated senders). Prefers text/plain, falls back to
    // stripped text/html; base64url-decoded and capped. Residual quoted history is left for the
    // classifier (#112) rather than perfectly stripped here. nil if there's no real reply with text.
    static func latestReplyBody(threadJSON data: Data, selfEmail: String, maxLength: Int = 6_000) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = obj["messages"] as? [[String: Any]] else { return nil }
        let me = email(from: selfEmail)
        for m in newestFirst(messages) {
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

    // Newest-first by Gmail's internalDate (epoch ms), since threads.get's array order isn't
    // guaranteed to be chronological. Ties, including messages with no internalDate at all, keep
    // their original order reversed, the same newest-last shape a real thread's array normally has.
    // Internal (not private): BounceDetection (#398) reuses this same chronological ordering so a
    // genuinely newer hard bounce is found instead of whichever bounce comes first in the array.
    static func newestFirst(_ messages: [[String: Any]]) -> [[String: Any]] {
        messages.enumerated()
            .sorted { a, b in
                let (dateA, dateB) = (internalDateMillis(a.element), internalDateMillis(b.element))
                return dateA != dateB ? dateA > dateB : a.offset > b.offset
            }
            .map(\.element)
    }

    private static func internalDateMillis(_ message: [String: Any]) -> Int64 {
        if let raw = message["internalDate"] as? String, let value = Int64(raw) { return value }
        if let raw = message["internalDate"] as? NSNumber { return raw.int64Value }
        return 0
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
