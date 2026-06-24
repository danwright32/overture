import Foundation

// Builds the wire form the Gmail API expects: an RFC 2822 message, base64url-encoded,
// posted as {"raw": ...} to users/me/messages/send. Pure and testable; the network
// call and OAuth token live in GmailSender (the next slice).

enum GmailMessage {
    // base64url with no padding, as the Gmail API requires for the `raw` field.
    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // A minimal text/plain RFC 2822 message. From is the authorized sender; the
    // subject is RFC 2047 encoded only when it contains non-ASCII (e.g. an accented
    // org name) so headers stay 7-bit clean.
    static func rfc822(fromName: String, fromEmail: String, to: String, subject: String, body: String,
                       messageID: String? = nil, inReplyTo: String? = nil) -> String {
        let headerSubject = isASCII(subject) ? subject : encodedWord(subject)
        var headers = [
            "From: \(fromName) <\(fromEmail)>",
            "To: \(to)",
            "Subject: \(headerSubject)",
        ]
        // #74: thread a follow-up onto the original. Message-ID stamps the first send so the
        // nudge can point In-Reply-To/References at it, which is what makes mail clients (and
        // Gmail's reply detection) treat the reply as part of the same conversation.
        if let messageID { headers.append("Message-ID: \(messageID)") }
        if let inReplyTo {
            headers.append("In-Reply-To: \(inReplyTo)")
            headers.append("References: \(inReplyTo)")
        }
        headers += [
            "MIME-Version: 1.0",
            "Content-Type: text/plain; charset=UTF-8",
            "Content-Transfer-Encoding: 8bit",
            "",
            body,
        ]
        return headers.joined(separator: "\r\n")
    }

    static func rawField(fromName: String, fromEmail: String, to: String, subject: String, body: String,
                         messageID: String? = nil, inReplyTo: String? = nil) -> String {
        base64url(Data(rfc822(fromName: fromName, fromEmail: fromEmail, to: to, subject: subject, body: body,
                              messageID: messageID, inReplyTo: inReplyTo).utf8))
    }

    // A fresh RFC 2822 Message-ID under the sender's domain, e.g. <UUID@danwrightphotography.com>.
    static func newMessageID(senderEmail: String) -> String {
        let domain = senderEmail.split(separator: "@").last.map(String.init) ?? "overture.local"
        return "<\(UUID().uuidString)@\(domain)>"
    }

    private static func isASCII(_ s: String) -> Bool { s.allSatisfy { $0.isASCII } }

    // RFC 2047 encoded-word: =?UTF-8?B?<base64>?=
    private static func encodedWord(_ s: String) -> String {
        "=?UTF-8?B?\(Data(s.utf8).base64EncodedString())?="
    }
}
