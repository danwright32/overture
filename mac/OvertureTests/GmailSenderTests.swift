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
}
