import Testing
import Foundation
@testable import Overture

// #84: the live send path (encode + POST, interpret success / api-error / auth-expired) is
// now testable through an injected fetch and an injected auth-expired hook, no network.
@Suite("Gmail send")
struct GmailSenderTests {
    private let mail = OutgoingMail(to: "presenter@example.org", subject: "Hello", body: "Body")

    private func fetch(_ status: Int, _ body: String) -> @Sendable (URLRequest) async throws -> (Data, URLResponse) {
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

    // #483: a 2xx response whose body cannot be parsed at all must never fall through as a
    // silent empty threadId; it has to come back flagged so the recipient can be marked
    // degraded instead of quietly dropped from reply watching forever.
    @Test func unparseableBodyFlagsTheReceiptAsDegradedInsteadOfEmpty() async throws {
        let receipt = try await GmailSender.performSend(
            mail: mail, fromName: "Dan Wright", fromEmail: "dan@x.org", token: "tok",
            fetch: fetch(200, "not json at all"), onAuthExpired: {})
        #expect(receipt.threadId == "")
        #expect(receipt.threadIdDegraded == true)
    }

    // A body that parses fine but carries neither key is the same failure mode: nothing to
    // recover a threadId from, so it must be flagged too, not just silently emptied.
    @Test func bodyWithNeitherThreadIdNorIdFlagsTheReceiptAsDegraded() async throws {
        let receipt = try await GmailSender.performSend(
            mail: mail, fromName: "Dan Wright", fromEmail: "dan@x.org", token: "tok",
            fetch: fetch(200, #"{"labelIds":["SENT"]}"#), onAuthExpired: {})
        #expect(receipt.threadId == "")
        #expect(receipt.threadIdDegraded == true)
    }

    @Test func aNormalSuccessIsNeverFlaggedAsDegraded() async throws {
        let receipt = try await GmailSender.performSend(
            mail: mail, fromName: "Dan Wright", fromEmail: "dan@x.org", token: "tok",
            fetch: fetch(200, #"{"threadId":"t123","id":"m1"}"#), onAuthExpired: {})
        #expect(receipt.threadIdDegraded == false)
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

    // #145: the Send button calls GmailSender.send ON THE MAIN ACTOR. With the async send path
    // this completes; the old synchronous semaphore bridge would have hung the main thread right
    // here (the deadlock). Token + fetch are injected so there's no network or live auth. If this
    // test ever hangs instead of completing, the blocking bridge has regressed.
    @MainActor
    @Test func sendOnTheMainActorCompletesWithInjectedTokenAndFetch() async throws {
        let sender = GmailSender(fromEmail: "dan@danwrightphotography.com")
        let receipt = try await sender.send(
            mail, token: { "tok" }, fetch: fetch(200, #"{"threadId":"t-main","id":"m1"}"#))
        #expect(receipt.threadId == "t-main")
        #expect(receipt.messageID?.hasSuffix("@danwrightphotography.com>") == true)
    }

    @MainActor
    @Test func sendOnTheMainActorSurfacesAuthExpired() async {
        // The token is valid but Gmail rejects it (401): send must surface authExpired without
        // hanging, so the app can prompt a reconnect.
        let sender = GmailSender(fromEmail: "dan@x.org")
        await #expect(throws: GmailSendError.self) {
            _ = try await sender.send(
                mail, token: { "stale" }, fetch: fetch(401, #"{"error":"invalid"}"#), onAuthExpired: {})
        }
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
