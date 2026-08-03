import Testing
import Foundation

// Extracting the latest inbound reply's text from a Gmail threads.get (format=full) response (#181),
// so the reply can be handed to the classify workflow (#112). Forgiving by design: prefer text/plain,
// fall back to HTML stripped, decode base64url, cap length, and leave residual quoted history for the
// classifier (Claude) rather than chasing perfect quote-stripping in Swift.
@Suite("Reply body extraction")
struct ReplyBodyTests {
    private let me = "dan@danwrightphotography.com"

    // Gmail base64url: URL-safe alphabet, no padding (what the API returns in body.data).
    private func b64url(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // A threads.get JSON with the given messages, each a (from, mimeType, text). Single-part bodies;
    // the multipart helper below builds the alternative case.
    private func thread(_ messages: [(from: String, mime: String, text: String)]) -> Data {
        let msgs = messages.map { m in
            """
            {"payload":{"headers":[{"name":"From","value":"\(m.from)"}],"mimeType":"\(m.mime)","body":{"data":"\(b64url(m.text))"}}}
            """
        }.joined(separator: ",")
        return Data("{\"messages\":[\(msgs)]}".utf8)
    }

    @Test func extractsAPlainTextReply() {
        let data = thread([(me, "text/plain", "Original pitch."),
                           ("Emma <emma@org.example>", "text/plain", "Yes, we'd like to book.")])
        #expect(ReplyDetection.latestReplyBody(threadJSON: data, selfEmail: me) == "Yes, we'd like to book.")
    }

    @Test func prefersThePlainTextPartOfAMultipartReply() {
        let plain = b64url("The plain part.")
        let html = b64url("<p>The HTML part.</p>")
        let json = """
        {"messages":[{"payload":{"headers":[{"name":"From","value":"emma@org.example"}],"mimeType":"multipart/alternative","parts":[{"mimeType":"text/plain","body":{"data":"\(plain)"}},{"mimeType":"text/html","body":{"data":"\(html)"}}]}}]}
        """
        #expect(ReplyDetection.latestReplyBody(threadJSON: Data(json.utf8), selfEmail: me) == "The plain part.")
    }

    @Test func fallsBackToStrippedHtmlWhenNoPlainPart() {
        let data = thread([("emma@org.example", "text/html", "<p>Hi Dan,</p><p>Sounds great.</p>")])
        let body = ReplyDetection.latestReplyBody(threadJSON: data, selfEmail: me)
        #expect(body?.contains("Sounds great.") == true)
        #expect(body?.contains("<p>") == false)   // tags stripped
    }

    @Test func picksTheNewestInboundMessage() {
        let data = thread([(me, "text/plain", "Pitch."),
                           ("emma@org.example", "text/plain", "We're interested."),
                           (me, "text/plain", "Great, here are details."),
                           ("emma@org.example", "text/plain", "Confirmed, let's book.")])
        #expect(ReplyDetection.latestReplyBody(threadJSON: data, selfEmail: me) == "Confirmed, let's book.")
    }

    // #482: array position 0 is chronologically newest here (internalDate "3000" beats "2000"),
    // the opposite of the usual oldest-first shape, so picking by position would return the
    // older text instead of the newer one.
    @Test func picksTheNewestInboundMessageByInternalDateNotArrayPosition() {
        let newer = b64url("Newest, by date.")
        let older = b64url("Older, by date.")
        let json = """
        {"messages":[
          {"internalDate":"3000","payload":{"headers":[{"name":"From","value":"emma@org.example"}],"mimeType":"text/plain","body":{"data":"\(newer)"}}},
          {"internalDate":"2000","payload":{"headers":[{"name":"From","value":"emma@org.example"}],"mimeType":"text/plain","body":{"data":"\(older)"}}}
        ]}
        """
        #expect(ReplyDetection.latestReplyBody(threadJSON: Data(json.utf8), selfEmail: me) == "Newest, by date.")
    }

    @Test func skipsAutomatedSendersAndReturnsNilWhenNoRealReply() {
        let data = thread([(me, "text/plain", "Pitch."),
                           ("no-reply@org.example", "text/plain", "This is an automated response.")])
        #expect(ReplyDetection.latestReplyBody(threadJSON: data, selfEmail: me) == nil)
    }

    @Test func capsAnOverlongBody() {
        let huge = String(repeating: "a", count: 20_000)
        let data = thread([("emma@org.example", "text/plain", huge)])
        let body = ReplyDetection.latestReplyBody(threadJSON: data, selfEmail: me)
        #expect((body?.count ?? 0) <= 6_000)
    }
}
