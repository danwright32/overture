import Testing
import Foundation


// #2928: the one Gmail fixture builder, at file scope.
private let senderGmail = GmailFixture(selfEmail: "dan@x.org", threadId: "t1")
// #84: the live send path (encode + POST, interpret success / api-error / auth-expired) is
// now testable through an injected fetch and an injected auth-expired hook, no network.
@Suite("Gmail send")
struct GmailSenderTests {
    private let mail = OutgoingMail(to: ["presenter@example.org"], subject: "Hello", body: "Body")!

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

    // #2647: the send is now TWO calls, a POST that sends and a GET that reads the real Message-ID
    // back, so a stub has to answer both. Routed on the HTTP method rather than on the URL, because
    // what distinguishes them is what they DO; a URL match would still pass if the readback were
    // pointed at the wrong message.
    private func sendThenReadBack(sendBody: String,
                                  readBackStatus: Int = 200,
                                  readBackBody: Data) -> @Sendable (URLRequest) async throws -> (Data, URLResponse) {
        { req in
            let isSend = req.httpMethod == "POST"
            let body = isSend ? Data(sendBody.utf8) : readBackBody
            let status = isSend ? 200 : readBackStatus
            return (body,
                    HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    // The shape Gmail actually returns for
    // users/me/messages/<id>?format=metadata&metadataHeaders=Message-ID. #2928: through the one builder,
    // so it carries the `labelIds`, `threadId` and `internalDate` every real `messages.get` returns.
    private func metadata(messageID: String) -> Data {
        senderGmail.message(.init(from: "dan@x.org", messageID: messageID, id: "m1"))
    }

    // A plain successful read back, for the tests whose subject is the SEND request and which only
    // need the second call answered.
    private func readBackResponse(for req: URLRequest) -> (Data, URLResponse) {
        (metadata(messageID: "<real@mail.gmail.com>"),
         HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
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

    // #2647: the Message-ID Overture keeps is the one GMAIL assigned, read back off the sent message,
    // never one Overture minted. Gmail discards a client-supplied Message-ID on
    // users/me/messages/send and stamps its own (@mail.gmail.com), so a minted value has never been on
    // the wire and every In-Reply-To later written from it is a dangling reference that only Gmail's
    // own server-side threading papers over.
    @Test func theStoredMessageIDIsTheOneGmailAssignedNotOneOvertureMinted() async throws {
        let receipt = try await GmailSender.performSend(
            mail: mail, fromName: "Dan Wright", fromEmail: "dan@danwrightphotography.com", token: "tok",
            fetch: sendThenReadBack(sendBody: #"{"threadId":"t1","id":"m1"}"#,
                                    readBackBody: metadata(messageID: "<real-abc@mail.gmail.com>")),
            onAuthExpired: {})
        #expect(receipt.messageID == "<real-abc@mail.gmail.com>")
        #expect(receipt.messageIDDegraded == false)
    }

    // The read back GET must ask for the message Gmail just created, by the id the SEND returned. A
    // readback pointed at anything else would still produce a plausible id, so the request itself is
    // what has to be asserted.
    @Test func theReadBackAsksForTheIdTheSendReturned() async throws {
        let seen = CapturedURLs()
        _ = try await GmailSender.performSend(
            mail: mail, fromName: "Dan", fromEmail: "dan@x.org", token: "tok",
            fetch: { req in
                if req.httpMethod != "POST" { seen.record(req.url?.absoluteString ?? "") }
                let body = req.httpMethod == "POST"
                    ? Data(#"{"threadId":"t1","id":"gmail-id-42"}"#.utf8)
                    : self.metadata(messageID: "<real@mail.gmail.com>")
                return (body,
                        HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            },
            onAuthExpired: {})
        let url = try #require(seen.urls.first)
        #expect(url.contains("/messages/gmail-id-42"))
        #expect(url.contains("format=metadata"))
        #expect(url.contains("metadataHeaders=Message-ID"))
    }

    // #2647 point 2: failing to read the real id back is LOUD, never a silent fall back to a minted
    // value. A minted id would look exactly like a real one to every reader downstream while being a
    // reference to a message that exists nowhere, so nothing is better than something here (L11).
    @Test func aFailedReadBackFlagsTheReceiptRatherThanInventingAMessageID() async throws {
        let receipt = try await GmailSender.performSend(
            mail: mail, fromName: "Dan Wright", fromEmail: "dan@danwrightphotography.com", token: "tok",
            fetch: sendThenReadBack(sendBody: #"{"threadId":"t1","id":"m1"}"#,
                                    readBackStatus: 404,
                                    readBackBody: Data(#"{"error":"not found"}"#.utf8)),
            onAuthExpired: {})
        #expect(receipt.threadId == "t1")   // the send itself succeeded, so this is not a send failure
        #expect(receipt.messageID == nil)
        #expect(receipt.messageIDDegraded == true)
    }

    // A 200 whose body carries no Message-ID header is the same failure: nothing to store.
    @Test func aReadBackWithNoMessageIDHeaderIsDegradedNotEmptyString() async throws {
        let receipt = try await GmailSender.performSend(
            mail: mail, fromName: "Dan", fromEmail: "dan@x.org", token: "tok",
            fetch: sendThenReadBack(sendBody: #"{"threadId":"t1","id":"m1"}"#,
                                    readBackBody: senderGmail.message(
                                        .init(from: "dan@x.org", subject: "Hello", id: "m1"))),
            onAuthExpired: {})
        #expect(receipt.messageID == nil)
        #expect(receipt.messageIDDegraded == true)
    }

    // Gmail spells it Message-Id in some responses. The header name is case insensitive per RFC 2822,
    // so matching it exactly would degrade a send that was perfectly fine.
    @Test func theMessageIDHeaderIsMatchedCaseInsensitively() async throws {
        let receipt = try await GmailSender.performSend(
            mail: mail, fromName: "Dan", fromEmail: "dan@x.org", token: "tok",
            fetch: sendThenReadBack(sendBody: #"{"threadId":"t1","id":"m1"}"#,
                                    readBackBody: senderGmail.message(
                                        .init(from: "dan@x.org", id: "m1",
                                              extraHeaders: [(name: "Message-Id",
                                                              value: "<mixed@mail.gmail.com>")]))),
            onAuthExpired: {})
        #expect(receipt.messageID == "<mixed@mail.gmail.com>")
        #expect(receipt.messageIDDegraded == false)
    }

    // #2647 point 3: nothing mints a Message-ID onto the outgoing message any more, because Gmail
    // throws it away. A header that is ignored on the wire and then believed in the store is worse
    // than no header at all.
    @Test func theSentMessageCarriesNoMintedMessageIDHeader() async throws {
        let captured = Captured()
        _ = try await GmailSender.performSend(
            mail: mail, fromName: "Dan", fromEmail: "dan@danwrightphotography.com", token: "tok",
            fetch: { req in
                if req.httpMethod == "POST" { captured.body = req.httpBody }
                let body = req.httpMethod == "POST"
                    ? Data(#"{"threadId":"t1","id":"m1"}"#.utf8)
                    : self.metadata(messageID: "<real@mail.gmail.com>")
                return (body,
                        HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            },
            onAuthExpired: {})
        let json = try JSONSerialization.jsonObject(with: captured.body!) as! [String: Any]
        #expect(!base64urlDecode(json["raw"] as! String).contains("Message-ID:"))
    }

    // A send whose threadId could not be read AND whose Message-ID could not be read is degraded on
    // BOTH counts, each on its own flag. One flag standing for two independent checks would let a
    // pass on either erase the other's failure (L53).
    @Test func theTwoDegradedFlagsAreIndependent() async throws {
        let receipt = try await GmailSender.performSend(
            mail: mail, fromName: "Dan", fromEmail: "dan@x.org", token: "tok",
            fetch: fetch(200, #"{"labelIds":["SENT"]}"#), onAuthExpired: {})
        #expect(receipt.threadIdDegraded == true)
        #expect(receipt.messageIDDegraded == true)
    }

    private final class CapturedURLs: @unchecked Sendable {
        private(set) var urls: [String] = []
        func record(_ u: String) { urls.append(u) }
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
            mail, token: { "tok" },
            fetch: sendThenReadBack(sendBody: #"{"threadId":"t-main","id":"m1"}"#,
                                    readBackBody: metadata(messageID: "<main@mail.gmail.com>")))
        #expect(receipt.threadId == "t-main")
        #expect(receipt.messageID == "<main@mail.gmail.com>")
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
        // #2647: only the SEND's body is captured. The read back GET that follows it carries no body,
        // so recording every request would overwrite the thing under test with nil.
        let fetch: (URLRequest) async throws -> (Data, URLResponse) = { req in
            guard req.httpMethod == "POST" else { return self.readBackResponse(for: req) }
            captured.body = req.httpBody
            return (Data(#"{"threadId":"th-1","id":"m9"}"#.utf8),
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let followUp = OutgoingMail(to: ["t@y.org"], subject: "Re: Hello", body: "nudge",
                                    inReplyTo: "<orig@x.org>", threadId: "th-1")!
        let receipt = try await GmailSender.performSend(
            mail: followUp, fromName: "Dan", fromEmail: "dan@x.org", token: "tok",
            fetch: fetch, onAuthExpired: {})

        #expect(receipt.threadId == "th-1")
        let json = try JSONSerialization.jsonObject(with: captured.body!) as! [String: Any]
        #expect(json["threadId"] as? String == "th-1")
        #expect(base64urlDecode(json["raw"] as! String).contains("In-Reply-To: <orig@x.org>"))
    }

    // #1144: a styled signature is attached to the outgoing message (multipart/alternative with the HTML
    // part carrying the markup).
    @Test func aStyledSignatureIsAttachedToTheSentMessage() async throws {
        let captured = Captured()
        let fetch: (URLRequest) async throws -> (Data, URLResponse) = { req in
            guard req.httpMethod == "POST" else { return self.readBackResponse(for: req) }
            captured.body = req.httpBody
            return (Data(#"{"threadId":"t","id":"m"}"#.utf8),
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        _ = try await GmailSender.performSend(
            mail: mail, fromName: "Dan", fromEmail: "dan@x.org", token: "tok",
            signature: OutboundSignature(html: "<b style=\"color:teal\">Dan Wright</b>", plainText: "Best"),
            fetch: fetch, onAuthExpired: {})

        let json = try JSONSerialization.jsonObject(with: captured.body!) as! [String: Any]
        let raw = base64urlDecode(json["raw"] as! String)
        #expect(raw.contains("multipart/alternative"))
        #expect(raw.contains("<b style=\"color:teal\">Dan Wright</b>"))
    }

    // The failure path: with no styled signature available, the send still carries the plain-text sign-off
    // rather than going out signature-less silently.
    @Test func withoutAStyledSignatureTheSendStillCarriesThePlainSignoff() async throws {
        let captured = Captured()
        let fetch: (URLRequest) async throws -> (Data, URLResponse) = { req in
            guard req.httpMethod == "POST" else { return self.readBackResponse(for: req) }
            captured.body = req.httpBody
            return (Data(#"{"threadId":"t","id":"m"}"#.utf8),
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        _ = try await GmailSender.performSend(
            mail: mail, fromName: "Dan", fromEmail: "dan@x.org", token: "tok",
            signature: .plainFallback, fetch: fetch, onAuthExpired: {})

        let json = try JSONSerialization.jsonObject(with: captured.body!) as! [String: Any]
        let raw = base64urlDecode(json["raw"] as! String)
        #expect(!raw.contains("multipart/alternative"))
        #expect(raw.contains("Best,"))
        #expect(raw.contains("Dan Wright Photography"))
    }
}
