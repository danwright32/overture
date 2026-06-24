import Testing
import Foundation
@testable import Overture

@Suite("Gmail message encoding")
struct GmailMessageTests {
    @Test func base64urlHasNoUnsafeCharacters() {
        // Bytes that would produce +, /, = in standard base64.
        let data = Data([0xFB, 0xFF, 0xBF, 0x00])
        let encoded = GmailMessage.base64url(data)
        #expect(!encoded.contains("+"))
        #expect(!encoded.contains("/"))
        #expect(!encoded.contains("="))
    }

    @Test func rfc822CarriesHeadersAndBody() {
        let msg = GmailMessage.rfc822(
            fromName: "Dan Wright", fromEmail: "dan@danwrightphotography.com",
            to: "emma@org.org", subject: "Photographing the choir", body: "Hi Emma,\n\nText.")
        #expect(msg.contains("From: Dan Wright <dan@danwrightphotography.com>"))
        #expect(msg.contains("To: emma@org.org"))
        #expect(msg.contains("Subject: Photographing the choir"))
        #expect(msg.contains("Content-Type: text/plain; charset=UTF-8"))
        #expect(msg.contains("\r\n\r\nHi Emma,"))   // blank line then body, CRLF
    }

    @Test func nonAsciiSubjectIsRFC2047Encoded() {
        let msg = GmailMessage.rfc822(
            fromName: "Dan", fromEmail: "d@x.com", to: "t@y.org",
            subject: "Café Quartet at Carnegie", body: "b")
        #expect(msg.contains("Subject: =?UTF-8?B?"))
        #expect(!msg.contains("Subject: Café"))     // raw non-ASCII not in the header
    }

    @Test func rawFieldRoundTripsBackToTheMessage() {
        let raw = GmailMessage.rawField(
            fromName: "Dan", fromEmail: "d@x.com", to: "t@y.org", subject: "Hello", body: "Body text")
        // Reverse base64url and confirm the message decodes.
        var b64 = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        let decoded = String(data: Data(base64Encoded: b64)!, encoding: .utf8)!
        #expect(decoded.contains("Subject: Hello"))
        #expect(decoded.contains("Body text"))
    }

    @Test func messageIDHeaderIsIncludedWhenProvided() {
        // #74: the first send stamps a Message-ID so a later follow-up can reference it.
        let msg = GmailMessage.rfc822(
            fromName: "Dan", fromEmail: "d@x.com", to: "t@y.org",
            subject: "Hello", body: "b", messageID: "<abc@x.com>")
        #expect(msg.contains("Message-ID: <abc@x.com>"))
    }

    @Test func replyHeadersThreadTheFollowUp() {
        // A follow-up sets In-Reply-To and References to the original so it reads as a Re:.
        let msg = GmailMessage.rfc822(
            fromName: "Dan", fromEmail: "d@x.com", to: "t@y.org",
            subject: "Re: Hello", body: "b", inReplyTo: "<orig@x.com>")
        #expect(msg.contains("In-Reply-To: <orig@x.com>"))
        #expect(msg.contains("References: <orig@x.com>"))
    }

    @Test func omitsThreadingHeadersWhenNotProvided() {
        let msg = GmailMessage.rfc822(fromName: "Dan", fromEmail: "d@x.com", to: "t@y.org",
                                      subject: "Hello", body: "b")
        #expect(!msg.contains("Message-ID:"))
        #expect(!msg.contains("In-Reply-To:"))
    }

    @Test func newMessageIDIsBracketedAndUsesTheSenderDomain() {
        let id = GmailMessage.newMessageID(senderEmail: "dan@danwrightphotography.com")
        #expect(id.hasPrefix("<"))
        #expect(id.hasSuffix("@danwrightphotography.com>"))
    }
}
