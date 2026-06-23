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
}
