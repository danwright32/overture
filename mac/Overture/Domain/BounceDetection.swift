import Foundation

// Decides whether a Gmail thread carries a genuine HARD (permanent) bounce (#398): a message
// from a bounce-notification sender (mailer-daemon/postmaster) whose subject reads as a
// permanent failure, not a temporary delay. Pure so it's testable without the network; the
// live thread fetch lives in the integration layer (GmailReplyChecker). Deliberately
// conservative, sender AND subject must both match, and classification never touches the
// message body, so a still-reachable contact is never silenced by a soft bounce, an
// unrelated automated sender, or a real person's email that happens to mention "failure".
enum BounceDetection {
    private static let bounceSenderLocalParts = ["mailer-daemon", "postmaster"]

    static func isBounceSender(_ email: String) -> Bool {
        let local = email.lowercased().split(separator: "@").first.map(String.init) ?? email
        return bounceSenderLocalParts.contains { ReplyDetection.matchesToken(local, $0) }
    }

    // Gmail's own bounce notifications use a distinct subject for a permanent failure
    // ("Delivery Status Notification (Failure)", "Undelivered Mail Returned to Sender") versus
    // a temporary delay ("Delivery Status Notification (Delay)", "Delayed Mail"), so "delay"
    // anywhere in the subject always wins and rules out a hard bounce.
    static func isHardBounceSubject(_ subject: String) -> Bool {
        let s = subject.lowercased()
        guard !s.contains("delay") else { return false }
        return s.contains("failure") || s.contains("undelivered") || s.contains("delivery failed")
    }

    // The Gmail message id of a hard bounce in a threads.get (metadata, From + Subject headers)
    // response, or nil if there is none. A recipient's own thread is expected to carry at most
    // one bounce notification, so the first match is returned.
    static func hardBounceMessageId(threadJSON data: Data, selfEmail: String) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = obj["messages"] as? [[String: Any]] else { return nil }
        for m in messages {
            guard let payload = m["payload"] as? [String: Any],
                  let headers = payload["headers"] as? [[String: Any]] else { continue }
            let from = headers.first { ($0["name"] as? String)?.lowercased() == "from" }?["value"] as? String ?? ""
            let subject = headers.first { ($0["name"] as? String)?.lowercased() == "subject" }?["value"] as? String ?? ""
            let e = ReplyDetection.email(from: from)
            guard !e.isEmpty, isBounceSender(e), isHardBounceSubject(subject) else { continue }
            return m["id"] as? String
        }
        return nil
    }
}
