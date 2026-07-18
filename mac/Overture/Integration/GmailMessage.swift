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

    // copy-inventory:ignore-start  RFC822 headers: a mail server reads these, not Dan (#915)

    // An RFC 2822 message. From is the authorized sender; the subject is RFC 2047 encoded only when it
    // contains non-ASCII (e.g. an accented org name) so headers stay 7-bit clean. #1144: when the
    // signature carries HTML the message is multipart/alternative (a text/plain part plus a text/html part
    // that renders the styled Gmail signature); otherwise it stays a single text/plain part. The sign-off
    // is appended HERE, once, so no body producer carries its own.
    static func rfc822(fromName: String, fromEmail: String, to: String, subject: String, body: String,
                       signature: OutboundSignature = .none, boundary: String? = nil,
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
        let plainBody = signature.plainText.isEmpty ? body : body + "\n\n" + signature.plainText
        if let html = signature.html, !html.isEmpty {
            let b = boundary ?? freshBoundary()
            headers += [
                "MIME-Version: 1.0",
                "Content-Type: multipart/alternative; boundary=\"\(b)\"",
                "",
                "--\(b)",
                "Content-Type: text/plain; charset=UTF-8",
                "Content-Transfer-Encoding: 8bit",
                "",
                plainBody,
                "--\(b)",
                "Content-Type: text/html; charset=UTF-8",
                "Content-Transfer-Encoding: 8bit",
                "",
                htmlDocument(body: body, signatureHTML: html),
                "--\(b)--",
            ]
        } else {
            headers += [
                "MIME-Version: 1.0",
                "Content-Type: text/plain; charset=UTF-8",
                "Content-Transfer-Encoding: 8bit",
                "",
                plainBody,
            ]
        }
        return headers.joined(separator: "\r\n")
    }

    // The text/html part: the drafted body, HTML-escaped and newline-to-<br> so it can't inject markup and
    // its line breaks survive, followed by the styled signature (already HTML, inserted verbatim).
    private static func htmlDocument(body: String, signatureHTML: String) -> String {
        let escaped = htmlEscape(body).replacingOccurrences(of: "\n", with: "<br>\n")
        return "<div>\(escaped)</div><br>\n\(signatureHTML)"
    }

    private static func htmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")   // must be first
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // A unique MIME boundary. Not derived from the content, so it can never appear inside either part.
    private static func freshBoundary() -> String { "=_Overture_\(UUID().uuidString)" }
    // copy-inventory:ignore-end

    static func rawField(fromName: String, fromEmail: String, to: String, subject: String, body: String,
                         signature: OutboundSignature = .none,
                         messageID: String? = nil, inReplyTo: String? = nil) -> String {
        base64url(Data(rfc822(fromName: fromName, fromEmail: fromEmail, to: to, subject: subject, body: body,
                              signature: signature,
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
