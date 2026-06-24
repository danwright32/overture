import Testing
import Foundation
@testable import Overture

// #84: the live send path (encode + POST, interpret success / api-error / auth-expired) is
// now testable through an injected fetch and an injected auth-expired hook, no network.
@Suite("Gmail send")
struct GmailSenderTests {
    private let mail = OutgoingMail(to: "presenter@example.org", subject: "Hello", body: "Body")

    private func fetch(_ status: Int, _ body: String) -> (URLRequest) async throws -> (Data, URLResponse) {
        { _ in
            (Data(body.utf8),
             HTTPURLResponse(url: URL(string: "https://gmail.googleapis.com")!,
                             statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    private actor AuthSpy {
        var fired = false
        func fire() { fired = true }
    }

    @Test func successReturnsThreadId() async throws {
        let receipt = try await GmailSender.performSend(
            mail: mail, fromName: "Dan Wright", fromEmail: "dan@x.org", token: "tok",
            fetch: fetch(200, #"{"threadId":"t123","id":"m1"}"#), onAuthExpired: {})
        #expect(receipt.threadId == "t123")
    }

    @Test func fallsBackToMessageIdWhenNoThreadId() async throws {
        let receipt = try await GmailSender.performSend(
            mail: mail, fromName: "Dan Wright", fromEmail: "dan@x.org", token: "tok",
            fetch: fetch(200, #"{"id":"m1"}"#), onAuthExpired: {})
        #expect(receipt.threadId == "m1")
    }

    @Test func apiErrorThrows() async {
        await #expect(throws: GmailSendError.self) {
            _ = try await GmailSender.performSend(
                mail: mail, fromName: "Dan Wright", fromEmail: "dan@x.org", token: "tok",
                fetch: fetch(500, "upstream boom"), onAuthExpired: {})
        }
    }

    @Test func a401SignalsAuthExpiredAndThrows() async {
        let spy = AuthSpy()
        await #expect(throws: GmailSendError.self) {
            _ = try await GmailSender.performSend(
                mail: mail, fromName: "Dan Wright", fromEmail: "dan@x.org", token: "tok",
                fetch: fetch(401, #"{"error":"invalid"}"#), onAuthExpired: { await spy.fire() })
        }
        #expect(await spy.fired)
    }

    @Test func aFirstSendMintsAndReturnsAMessageID() async throws {
        let receipt = try await GmailSender.performSend(
            mail: mail, fromName: "Dan Wright", fromEmail: "dan@danwrightphotography.com", token: "tok",
            fetch: fetch(200, #"{"threadId":"t1"}"#), onAuthExpired: {})
        #expect(receipt.messageID?.hasSuffix("@danwrightphotography.com>") == true)
    }

    private final class Captured: @unchecked Sendable { var body: Data? }

    private func base64urlDecode(_ s: String) -> String {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        return String(data: Data(base64Encoded: b) ?? Data(), encoding: .utf8) ?? ""
    }

    @Test func aFollowUpThreadsViaBodyThreadIdAndReplyHeaders() async throws {
        // #74: the threadId goes in the send body (Gmail appends to the conversation) and the raw
        // carries In-Reply-To (the client-side thread link).
        let captured = Captured()
        let fetch: (URLRequest) async throws -> (Data, URLResponse) = { req in
            captured.body = req.httpBody
            return (Data(#"{"threadId":"th-1","id":"m9"}"#.utf8),
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let followUp = OutgoingMail(to: "t@y.org", subject: "Re: Hello", body: "nudge",
                                    inReplyTo: "<orig@x.org>", threadId: "th-1")
        let receipt = try await GmailSender.performSend(
            mail: followUp, fromName: "Dan", fromEmail: "dan@x.org", token: "tok",
            fetch: fetch, onAuthExpired: {})

        #expect(receipt.threadId == "th-1")
        let json = try JSONSerialization.jsonObject(with: captured.body!) as! [String: Any]
        #expect(json["threadId"] as? String == "th-1")
        #expect(base64urlDecode(json["raw"] as! String).contains("In-Reply-To: <orig@x.org>"))
    }
}
