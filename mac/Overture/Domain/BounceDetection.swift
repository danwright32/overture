import Foundation

// Decides whether a Gmail thread carries a genuine HARD (permanent) bounce (#398): a message
// from a bounce-notification sender (mailer-daemon/postmaster) whose subject reads as a
// permanent failure, not a temporary delay. Pure so it's testable without the network; the
// live thread fetch lives in the integration layer (GmailReplyChecker). Deliberately
// conservative, sender AND subject must both match, and classification never touches the
// message body, so a still-reachable contact is never silenced by a soft bounce, an
// unrelated automated sender, or a real person's email that happens to mention "failure".
enum BounceDetection {

    // #2888: the body of a Gmail `threads.get`, read through the shared reader so a 200 whose body does
    // not decode is counted rather than reading as NO BOUNCE, which would report a pitch that bounced as
    // delivered.
    private static let endpoint = "gmail.threads.get"

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

    // A soft/temporary delay ("Delivery Status Notification (Delay)", "Delayed Mail"): a mailbox
    // that's temporarily full or a delivery still being retried, not a permanent failure (#656).
    static func isDelaySubject(_ subject: String) -> Bool {
        subject.lowercased().contains("delay")
    }

    // Shared by hardBounceMessageId and delayMessageId: the Gmail message id of the newest
    // bounce-sender message whose subject matches `predicate`, or nil if there is none. A
    // recipient can carry more than one bounce notification on the same thread (a dismissed false
    // positive followed by a genuinely new bounce, #398), and threads.get's array order isn't
    // guaranteed to be chronological, so this sorts by internalDate (ReplyDetection.newestFirst,
    // the same precedent latestReplyId uses) rather than returning whichever notice happens to
    // come first in the array.
    private static func newestBounceSenderMessageId(threadJSON data: Data,
                                                    matching predicate: (String) -> Bool) -> String? {
        guard let obj = ResponseBody.json(data, from: Self.endpoint).value,
              let messages = obj["messages"] as? [[String: Any]] else { return nil }
        for m in ReplyDetection.newestFirst(messages) {
            guard let payload = m["payload"] as? [String: Any],
                  let headers = payload["headers"] as? [[String: Any]] else { continue }
            let from = headers.first { ($0["name"] as? String)?.lowercased() == "from" }?["value"] as? String ?? ""
            let subject = headers.first { ($0["name"] as? String)?.lowercased() == "subject" }?["value"] as? String ?? ""
            let e = ReplyDetection.email(from: from)
            guard !e.isEmpty, isBounceSender(e), predicate(subject) else { continue }
            return m["id"] as? String
        }
        return nil
    }

    // The Gmail message id of the newest hard bounce in a threads.get (metadata, From + Subject
    // headers) response, or nil if there is none.
    static func hardBounceMessageId(threadJSON data: Data, selfEmail: String) -> String? {
        newestBounceSenderMessageId(threadJSON: data, matching: isHardBounceSubject)
    }

    // The Gmail message id of the newest soft/temporary delay notice, or nil if there is none
    // (#656). Purely a read: callers must never let this affect isSilent or follow-up eligibility
    // the way a hard bounce does.
    static func delayMessageId(threadJSON data: Data, selfEmail: String) -> String? {
        newestBounceSenderMessageId(threadJSON: data, matching: isDelaySubject)
    }
}
