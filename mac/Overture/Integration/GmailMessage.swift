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
    static func rfc822(fromName: String, fromEmail: String, to: String, subject: String, body: String) -> String {
        let headerSubject = isASCII(subject) ? subject : encodedWord(subject)
        return [
            "From: \(fromName) <\(fromEmail)>",
            "To: \(to)",
            "Subject: \(headerSubject)",
            "MIME-Version: 1.0",
            "Content-Type: text/plain; charset=UTF-8",
            "Content-Transfer-Encoding: 8bit",
            "",
            body,
        ].joined(separator: "\r\n")
    }

    static func rawField(fromName: String, fromEmail: String, to: String, subject: String, body: String) -> String {
        base64url(Data(rfc822(fromName: fromName, fromEmail: fromEmail, to: to, subject: subject, body: body).utf8))
    }

    private static func isASCII(_ s: String) -> Bool { s.allSatisfy { $0.isASCII } }

    // RFC 2047 encoded-word: =?UTF-8?B?<base64>?=
    private static func encodedWord(_ s: String) -> String {
        "=?UTF-8?B?\(Data(s.utf8).base64EncodedString())?="
    }
}
