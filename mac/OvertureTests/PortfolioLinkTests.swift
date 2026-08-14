import Testing
import Foundation

// #2723: every outgoing pitch named the portfolio as plain text and never as a link.
//
// The HTML part is built by escaping the drafted body and turning newlines into `<br>`, so
// `danwrightphotography.com` reached the recipient as ordinary characters with no anchor around it.
// Whether it rendered as clickable was left entirely to the recipient's own mail client's URL detection,
// and a bare hostname with no scheme is the weakest form for that. That sentence is the proof behind
// every cold pitch (one portfolio link, always the site itself, #1832), so a recipient whose client does
// not detect it got a pitch with no way through to the work.
//
// The anchor goes in the `text/html` part ONLY. The `text/plain` part stays prose, because prose is what
// that part is for and a raw `<a href>` in it would be visible markup.
@Suite("Portfolio link")
struct PortfolioLinkTests {
    // A signature carrying its OWN anchor to the same site, deliberately: it is what Dan's real Gmail
    // signature does, and it is what proves the substitution touches only the body.
    private let signature = OutboundSignature(
        html: "<div>Dan Wright<br><a href=\"https://danwrightphotography.com\">danwrightphotography.com</a></div>",
        plainText: "Best,\nDan Wright")
    private let host = DraftCheck.allowedLinkHost

    private func rfc822(_ body: String, signature: OutboundSignature? = nil) -> String {
        GmailMessage.rfc822(fromName: "Dan Wright", fromEmail: "dan@danwrightphotography.com",
                            to: ["them@example.com"], subject: "Photographing your show.",
                            body: body, signature: signature ?? self.signature)
    }

    // The whole point, on the shape the drafter actually writes: a bare host in running prose.
    @Test func theHtmlPartLinksThePortfolio() {
        let html = try! #require(GmailMessage.previewHTML(
            body: "You can see more at danwrightphotography.com if it helps.", signature: signature))

        #expect(html.contains("<a href=\"https://\(host)\">\(host)</a>"))
    }

    // And the plain-text part is untouched. A recipient reading the text alternative gets prose, not
    // markup, which is the whole reason a multipart message has two of them.
    @Test func thePlainTextPartCarriesNoMarkup() {
        let body = "You can see more at \(host) if it helps."
        let plain = GmailMessage.previewBody(body: body, signature: signature)

        #expect(!plain.contains("<a href"))
        #expect(plain.contains("at \(host) if"))
    }

    // A sentence usually ends. The anchor must not swallow the full stop after the host, which would put
    // the period inside the link text and, worse, inside the href if the match were sloppier.
    @Test func aTrailingFullStopStaysOutsideTheLink() {
        let html = try! #require(GmailMessage.previewHTML(
            body: "Recent work is at \(host).", signature: signature))

        #expect(html.contains("<a href=\"https://\(host)\">\(host)</a>."))
    }

    // The drafter is told to write the site itself, but it can reach the same place three ways. All of
    // them are wrapped WHOLE, and all of them get the same canonical href, so the link never points
    // somewhere different from what it reads as, and no fragment is left dangling outside the anchor.
    @Test func everySpellingOfTheHostIsWrappedWhole() {
        for written in ["https://\(host)", "http://\(host)", "www.\(host)", "https://www.\(host)"] {
            let html = try! #require(GmailMessage.previewHTML(
                body: "See \(written) for more.", signature: signature))
            #expect(html.contains("<a href=\"https://\(host)\">\(written)</a>"),
                    "\(written) was not wrapped as a whole")
        }
    }

    // Case is not meaning in a hostname, and a drafter that capitalises a sentence-initial host must not
    // silently ship an unlinked one.
    @Test func theHostMatchesWhateverItsCase() {
        let html = try! #require(GmailMessage.previewHTML(
            body: "DanWrightPhotography.com has the full set.", signature: signature))

        #expect(html.contains("<a href=\"https://\(host)\">DanWrightPhotography.com</a>"))
    }

    // The reason the substitution runs AFTER escaping, not before. `htmlEscape` does not escape quotes, so
    // drafted text must never reach an attribute: if it could, a body carrying a quote would break out of
    // the href. This drives that case directly.
    @Test func draftedTextNeverReachesTheHref() {
        let html = try! #require(GmailMessage.previewHTML(
            body: "They said \"see danwrightphotography.com\" <today>.", signature: signature))

        // Exactly one href, and it is the constant.
        #expect(html.components(separatedBy: "href=").count - 1 == 2)   // the body's, plus the signature's
        #expect(html.contains("<a href=\"https://\(host)\">\(host)</a>"))
        // The angle brackets from the body are still escaped, so nothing the draft said became markup.
        #expect(html.contains("&lt;today&gt;"))
    }

    // The signature is already HTML and is inserted verbatim, so it must not be re-linked: a nested anchor
    // is invalid and renders unpredictably. Only the BODY is substituted.
    @Test func theSignaturesOwnLinkIsLeftAlone() {
        let html = try! #require(GmailMessage.previewHTML(body: "No portfolio mention here.",
                                                          signature: signature))

        #expect(!html.contains("<a href=\"https://\(host)\"><a"))
        #expect(html.components(separatedBy: "<a href=").count - 1 == 1)
    }

    // The case the issue asks to cover explicitly: no HTML signature at all. The message is then a single
    // plain-text part, there is no html part to put an anchor in, and nothing here may invent one.
    @Test func aMessageWithNoHtmlSignatureGetsNoAnchorAndStillSends() {
        // `OutboundSignature.none` spelled in full on purpose: written as a bare `.none` against the
        // optional parameter below, Swift resolves it to `Optional.none` and the helper silently falls
        // back to the HTML signature, so this test passed while exercising the opposite case.
        #expect(GmailMessage.previewHTML(body: "See \(host).", signature: OutboundSignature.none) == nil)

        let wire = rfc822("See \(host).", signature: OutboundSignature.none)
        #expect(wire.contains("Content-Type: text/plain"))
        #expect(!wire.contains("multipart/alternative"))
        #expect(!wire.contains("<a href"))
    }

    // What ships and what Dan approves are the same composition, which is why the substitution lives in
    // `htmlDocument` rather than at the send path: the card would otherwise show him an unlinked pitch and
    // send a linked one (L64).
    @Test func theCardShowsTheSameLinkTheWireCarries() {
        let body = "Recent work is at \(host)."
        let card = try! #require(GmailMessage.previewCardHTML(body: body, signature: signature))
        let wire = rfc822(body)

        #expect(card.contains("<a href=\"https://\(host)\">\(host)</a>"))
        #expect(wire.contains("<a href=\"https://\(host)\">\(host)</a>"))
    }

    // The over-match this is most likely to make, and the reason the pattern has a lookbehind. An address
    // in the body shares the host, and linking its domain would leave the local part dangling outside the
    // anchor and point a link at a website from what reads as an email address. Built from the fixtures it
    // must PRESERVE, not only the ones it must catch (L104).
    @Test func anAddressOnTheSameDomainIsNotTurnedIntoAWebsiteLink() {
        let html = try! #require(GmailMessage.previewHTML(
            body: "Reach me at dan@\(host) any time.", signature: signature))

        #expect(html.contains("Reach me at dan@\(host) any time."))
        // The only anchor in the message is the signature's own.
        #expect(html.components(separatedBy: "<a href=").count - 1 == 1)
    }

    // The other end of the same rule: a longer name that merely BEGINS with the host must not be cut in
    // half, with the first part linked and the rest left as text.
    @Test func aLongerNameBeginningWithTheHostIsNotCutInHalf() {
        let html = try! #require(GmailMessage.previewHTML(
            body: "Not to be confused with \(host)pany.", signature: signature))

        #expect(html.contains("with \(host)pany."))
        #expect(html.components(separatedBy: "<a href=").count - 1 == 1)
    }

    // A body that never names the portfolio is left exactly as it was. Without this the check above could
    // be satisfied by something that rewrote every message.
    @Test func aBodyWithoutThePortfolioIsUnchanged() {
        let html = try! #require(GmailMessage.previewHTML(
            body: "I photograph performing arts in New York.", signature: signature))

        #expect(html.contains("<div>I photograph performing arts in New York.</div>"))
    }
}
