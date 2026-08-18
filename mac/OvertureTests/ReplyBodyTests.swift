import Testing
import Foundation

// #2928: the one Gmail fixture builder, at file scope.
private let replyBodyGmail = GmailFixture(selfEmail: "dan@danwrightphotography.com")

// Extracting the latest inbound reply's text from a Gmail threads.get (format=full) response (#181),
// so the reply can be handed to the classify workflow (#112). Forgiving by design: prefer text/plain,
// fall back to HTML stripped, decode base64url, cap length, and leave residual quoted history for the
// classifier (Claude) rather than chasing perfect quote-stripping in Swift.
@Suite("Reply body extraction")
struct ReplyBodyTests {
    private let me = "dan@danwrightphotography.com"

    // #2928: every fixture here comes from the one builder, which base64url-encodes the body the way
    // Gmail does and carries `labelIds`, `id`, `threadId` and `internalDate` on every message.
    private func thread(_ messages: [(from: String, mime: String, text: String)]) -> Data {
        replyBodyGmail.thread(messages.map { m in
            m.mime == "text/html"
                ? GmailFixture.Message(from: m.from, html: m.text)
                : GmailFixture.Message(from: m.from, text: m.text)
        })
    }

    @Test func extractsAPlainTextReply() {
        let data = thread([(me, "text/plain", "Original pitch."),
                           ("Emma <emma@org.example>", "text/plain", "Yes, we'd like to book.")])
        #expect(ReplyDetection.latestReplyBody(threadJSON: data, selfEmail: me) == "Yes, we'd like to book.")
    }

    @Test func prefersThePlainTextPartOfAMultipartReply() {
        // Both parts present is what the builder produces for a message given text AND html.
        let json = replyBodyGmail.thread([
            .init(from: "emma@org.example", text: "The plain part.", html: "<p>The HTML part.</p>"),
        ])
        #expect(ReplyDetection.latestReplyBody(threadJSON: json, selfEmail: me) == "The plain part.")
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
        let json = replyBodyGmail.thread([
            .init(from: "emma@org.example", internalDateMillis: 3000, text: "Newest, by date."),
            .init(from: "emma@org.example", internalDateMillis: 2000, text: "Older, by date."),
        ])
        #expect(ReplyDetection.latestReplyBody(threadJSON: json, selfEmail: me) == "Newest, by date.")
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
