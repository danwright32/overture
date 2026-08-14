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

    // #1157: the plain-text body with the sign-off appended: the exact text the recipient's text/plain
    // part carries. The draft-review card previews THIS, so what Dan approves is what goes out. It is the
    // single definition of how the sign-off is appended, shared by the send path (rfc822) and the preview,
    // so the two can never drift. No literal copy of its own (the words come from OutboundSignature).
    static func previewBody(body: String, signature: OutboundSignature) -> String {
        signature.plainText.isEmpty ? body : body + "\n\n" + signature.plainText
    }

    // #1203: the text/html document the send path embeds, exposed so the draft-review card can render the
    // STYLED signature a rich mail client shows, not the plain-text fallback. nil when there is no HTML
    // signature, so the card falls back to previewBody. The single html composition, shared by BOTH the
    // card and the send path (rfc822), so the styled preview can never drift from the wire message.
    static func previewHTML(body: String, signature: OutboundSignature) -> String? {
        // #2086: sendableHTML, not html. This is the ONE composition both the wire (rfc822) and both
        // preview surfaces go through, so stripping here is what makes the invisible border impossible to
        // send and guarantees the card shows the same message that ships.
        guard let html = signature.sendableHTML, !html.isEmpty else { return nil }
        return htmlDocument(body: body, signatureHTML: html)
    }

    // #1203 (Dan's visual check, 2026-07-20): the draft-review card previews the email as a recipient's
    // inbox shows it, on a WHITE background. A Gmail signature is authored for a white email body (dark
    // text, dark icons), so rendered on Overture's dark card its text is unreadable (Dan saw the teal name
    // and dark lines vanish). This wraps the SAME previewHTML content on white, for the card ONLY. It is
    // never the wire html part: a real email must not carry its own page background, so rfc822 keeps using
    // previewHTML and this wrapper never reaches the recipient. nil (like previewHTML) when there is no HTML
    // signature, so the card falls back to previewBody.
    // copy-inventory:ignore-start  a light card surface for the outbound email's own HTML, not Overture's voice (#1203)
    // The card element's id. Named once here, where the card is emitted, because the preview's measuring
    // script has to find this exact element: two places naming it separately would drift into a preview
    // measuring nothing, silently (#2062).
    static let previewCardElementID = "overture-preview-card"

    // #2086: which background the card draws is now the caller's, because a preview with only ONE
    // background cannot show styling that is invisible on that background and glaring on the other. The
    // colours themselves live on PreviewBackground, so the two surfaces that render this cannot end up
    // disagreeing about what "dark" looks like. The content is IDENTICAL on both: the card never
    // sanitises the signature, or the preview would stop being a preview.
    static func previewCardHTML(body: String, signature: OutboundSignature,
                                background: PreviewBackground = .light) -> String? {
        guard let inner = previewHTML(body: body, signature: signature) else { return nil }
        // A contained, rounded CARD floating on the (transparent) chrome, framed so it reads as a real
        // inbox preview rather than the edge-to-edge slab Dan found jarring (2026-07-20). On light the
        // surface is true white on purpose: a Gmail signature's own divider rules are authored white
        // (#fff) to vanish on a white email body, so an off-white card wrongly reveals them as grey lines.
        // overflow:hidden clips the fixed-width (often 600px) signature to the card's rounded bounds with
        // nothing bleeding off the right edge.
        return "<style>html,body{background:transparent;margin:0;padding:8px}</style>"
            + "<div id=\"\(previewCardElementID)\" "
            + "style=\"background:\(background.surfaceCSS);color:\(background.inkCSS);padding:16px;"
            + "border-radius:10px;overflow:hidden;"
            + "border:\(background.frameCSS);box-shadow:0 1px 4px rgba(0,0,0,0.25)\">\(inner)</div>"
    }
    // copy-inventory:ignore-end

    // copy-inventory:ignore-start  RFC822 headers: a mail server reads these, not Dan (#915)

    // An RFC 2822 message. From is the authorized sender; the subject is RFC 2047 encoded only when it
    // contains non-ASCII (e.g. an accented org name) so headers stay 7-bit clean. #1144: when the
    // signature carries HTML the message is multipart/alternative (a text/plain part plus a text/html part
    // that renders the styled Gmail signature); otherwise it stays a single text/plain part. The sign-off
    // is appended HERE, once, so no body producer carries its own.
    static func rfc822(fromName: String, fromEmail: String, to: [String], subject: String, body: String,
                       signature: OutboundSignature = .none, boundary: String? = nil,
                       messageID: String? = nil, inReplyTo: String? = nil,
                       references: String? = nil) -> String {
        let headerSubject = isASCII(subject) ? subject : encodedWord(subject)
        var headers = [
            "From: \(fromName) <\(fromEmail)>",
            // #2030: several people ride ONE `To:` line, comma separated, which is what RFC 2822 means by
            // an address list. Joined here, beside the header, so there is one definition of it.
            "To: \(to.joined(separator: ", "))",
            "Subject: \(headerSubject)",
        ]
        // #74: thread a follow-up onto the original. Message-ID stamps the first send so the
        // nudge can point In-Reply-To/References at it, which is what makes mail clients (and
        // Gmail's reply detection) treat the reply as part of the same conversation.
        if let messageID { headers.append("Message-ID: \(messageID)") }
        if let inReplyTo { headers.append("In-Reply-To: \(inReplyTo)") }
        // #2648: References is the WHOLE ancestry, oldest first, not the parent restated. It used to be
        // written as the single `inReplyTo` value, so a third message on a conversation named only the
        // second and a client walking the chain had no link back to the first.
        //
        // Falling back to `inReplyTo` when no chain is supplied keeps the old behaviour as the floor: the
        // parent's id alone is an incomplete References but a valid one, and it is strictly better than
        // dropping the header for a caller that has not been taught the chain yet.
        if let refs = references ?? inReplyTo, !refs.isEmpty {
            headers.append("References: \(refs)")
        }
        let plainBody = previewBody(body: body, signature: signature)
        if let htmlPart = previewHTML(body: body, signature: signature) {
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
                htmlPart,
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
        let escaped = linkPortfolio(in: htmlEscape(body).replacingOccurrences(of: "\n", with: "<br>\n"))
        return "<div>\(escaped)</div><br>\n\(signatureHTML)"
    }

    // #2723: the portfolio address, as a real link.
    //
    // That sentence is the proof behind every cold pitch (one portfolio link, always the site itself,
    // #1832), and it went out as ordinary characters, so whether the recipient could reach the work at all
    // was left to their mail client's own URL detection. A bare hostname with no scheme is the weakest
    // form for that.
    //
    // Three things this gets right, and each is the reason it is written the way it is.
    //
    // It runs AFTER escaping, and only over the BODY. `htmlEscape` deliberately does not escape quotes, so
    // drafted text reaching an attribute could break out of the href; escaping first means the only thing
    // that can end up in the href is the constant below. The signature is separate and already HTML, so it
    // is never re-linked and no nested anchor is possible.
    //
    // It matches the CANONICAL HOST, not URL-shaped text. The draft lint forbids every other host
    // (`DraftCheck.allowedLinkHost`, and `src/lib/prepEval.ts` on the other side), so there is exactly one
    // address this can ever be about, and matching a shape instead would link things the pitch merely
    // mentions (L104). The host is read from that same constant rather than spelled again here, so the
    // rule and the thing it recognises cannot drift (L41).
    //
    // It wraps whatever the drafter wrote WHOLE, scheme and `www.` included, while always pointing at the
    // canonical https address. A link that reads as one thing and points at another is worse than no link,
    // and leaving a `https://` fragment outside the anchor looks like a rendering fault.
    //
    // The boundaries on either side are the L104 half, and they are about what must be PRESERVED rather
    // than what must be caught. Without the lookbehind, `dan@danwrightphotography.com` in a body would
    // have its domain linked and the local part left dangling outside the anchor; without the lookahead, a
    // longer name beginning with the host would be cut in half. A shape matcher over prose matches more
    // than its target, and an over-match reads exactly like the feature working.
    private static func linkPortfolio(in escapedHTML: String) -> String {
        let host = NSRegularExpression.escapedPattern(for: DraftCheck.allowedLinkHost)
        guard let re = try? NSRegularExpression(
            pattern: "(?<![\\w@.-])(?:https?://)?(?:www\\.)?\(host)(?![\\w-])",
            options: [.caseInsensitive]) else { return escapedHTML }
        let range = NSRange(escapedHTML.startIndex..., in: escapedHTML)
        return re.stringByReplacingMatches(
            in: escapedHTML, range: range,
            withTemplate: "<a href=\"https://\(DraftCheck.allowedLinkHost)\">$0</a>")
    }

    private static func htmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")   // must be first
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // A unique MIME boundary. Not derived from the content, so it can never appear inside either part.
    private static func freshBoundary() -> String { "=_Overture_\(UUID().uuidString)" }
    // copy-inventory:ignore-end

    static func rawField(fromName: String, fromEmail: String, to: [String], subject: String, body: String,
                         signature: OutboundSignature = .none,
                         messageID: String? = nil, inReplyTo: String? = nil,
                         references: String? = nil) -> String {
        base64url(Data(rfc822(fromName: fromName, fromEmail: fromEmail, to: to, subject: subject, body: body,
                              signature: signature,
                              messageID: messageID, inReplyTo: inReplyTo,
                              references: references).utf8))
    }

    // A fresh RFC 2822 Message-ID under the sender's domain, e.g. <UUID@danwrightphotography.com>.
    static func newMessageID(senderEmail: String) -> String {
        return "<\(UUID().uuidString)@\(messageIDDomain(senderEmail: senderEmail))>"
    }

    // #2649: does this stored id look like one OVERTURE minted rather than one Gmail assigned? It is the
    // question the threading repair selects on, and it lives here, beside the minting above, so the test
    // and the thing it recognises cannot drift into disagreeing (L41).
    //
    // The reasoning it encodes: Gmail discards a supplied Message-ID and stamps its own under
    // `mail.gmail.com`, which is what #2647 now reads back. An id under the SENDER's own domain is
    // therefore one nothing on the wire ever carried, and is exactly what needs repairing. Note this is a
    // recogniser for a value we wrote ourselves, not a claim about what Gmail will do next: an identifier
    // handed to somebody else's system is a request, never a fact (L127), which is why the send path reads
    // its id back rather than trusting the one it offered.
    static func isLocallyMintedMessageID(_ messageID: String?, senderEmail: String) -> Bool {
        guard let raw = messageID?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            // Nothing stored at all: the next follow-up references nothing either, so it needs the same
            // repair and is selected by the same predicate.
            return true
        }
        return raw.lowercased().hasSuffix("@\(messageIDDomain(senderEmail: senderEmail))>".lowercased())
    }

    private static func messageIDDomain(senderEmail: String) -> String {
        senderEmail.split(separator: "@").last.map(String.init) ?? "overture.local"
    }

    private static func isASCII(_ s: String) -> Bool { s.allSatisfy { $0.isASCII } }

    // RFC 2047 encoded-word: =?UTF-8?B?<base64>?=
    private static func encodedWord(_ s: String) -> String {
        "=?UTF-8?B?\(Data(s.utf8).base64EncodedString())?="
    }
}
