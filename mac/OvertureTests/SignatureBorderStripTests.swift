import Testing
import Foundation

// #2086: taking the invisible border OFF THE WIRE.
//
// Dan's Gmail signature carries three wrapper divs styled `border:1px solid #fff`. They are invisible on
// the white background Gmail authors signatures for and a hard white outline box to every recipient
// reading in dark mode, and they went out on real pitches for about two weeks.
//
// The route through Gmail Settings was tried on 2026-08-04 and cannot reach them: the wrappers come from
// the signature generator's markup (the `min-width:600px` shape, the icon.signature.email images), so
// they ride along with any copy of the rendered signature, and Gmail's editor offers no way to select a
// wrapper or set a border colour. A refetch after Dan re-pasted the signature returned a genuinely
// different value (2,087 to 2,481 characters, so the edit landed) with all three border rules byte
// identical. Dan's call, 2026-08-04: Overture strips them on the way out.
//
// The stripper is defined as "removes exactly what the detector flags", reusing the #2087 predicate
// rather than a second opinion about what counts, so detection and removal can never disagree about a
// border. The fixed point below is that definition made testable.
@Suite("Stripping the invisible border off the wire (#2086)")
struct SignatureBorderStripTests {
    private let body = "Hello there.\n\nDan"

    private func signature(_ html: String) -> OutboundSignature {
        OutboundSignature(html: html, plainText: "Dan Wright")
    }

    // The fixed point: what the detector flags is what the stripper removes, so a signature that has been
    // through it can never still be flagged. Measured against the REAL signature, not a shaped one (L48).
    @Test func strippingLeavesNothingTheDetectorStillFlags() {
        let stripped = GmailSignatureHealth.strippingInvisibleBorders(Signature2086Fixture.asSent)
        #expect(GmailSignatureHealth.darkBackgroundReason(Signature2086Fixture.asSent) != nil,
                "the real signature must trip the detector, or this test proves nothing")
        #expect(GmailSignatureHealth.darkBackgroundReason(stripped) == nil)
    }

    // It removes the borders and NOTHING else. A stripper that quietly ate the name, the link or the
    // icons would be worse than the box it removes.
    @Test func strippingLeavesTheRestOfTheSignatureIntact() {
        let stripped = GmailSignatureHealth.strippingInvisibleBorders(Signature2086Fixture.asSent)
        #expect(stripped.contains("Dan Wright"))
        #expect(stripped.contains("he/they"))
        #expect(stripped.contains("www.danwrightphotography.com"))
        #expect(stripped.contains("icon.signature.email/social/facebook-rounded-medium-FFFFFF-333333.png"))
        #expect(stripped.contains("icon.signature.email/social/instagram-rounded-medium-FFFFFF-333333.png"))
        // The layout the wrappers carried survives them: only the border declaration goes.
        #expect(stripped.contains("min-width:600px"))
        // The icons' own `border:0px` and `border="0"` paint nothing and are not this defect, so they stay.
        #expect(stripped.contains("border:0px"))
        #expect(stripped.contains("border=\"0\""))
    }

    // A signature with nothing to strip comes back byte for byte, so the stripper cannot churn a clean
    // signature or quietly reformat one.
    @Test func aCleanSignatureIsReturnedUnchanged() {
        let clean = Signature2086Fixture.asTheMailClientSendsIt
        #expect(GmailSignatureHealth.strippingInvisibleBorders(clean) == clean)
    }

    // A border someone can SEE is a border someone chose, so it survives. This is the line between
    // removing a defect and rewriting Dan's signature.
    @Test func aBorderThatIsActuallyVisibleIsKept() {
        let html = #"<div style="border:1px solid #333333">Dan</div>"#
        #expect(GmailSignatureHealth.strippingInvisibleBorders(html) == html)
    }

    // THE test: the message that actually goes to the recipient. Everything above is about the helper;
    // this is about the wire.
    @Test func theSentMessageCarriesNoInvisibleBorder() {
        let mail = GmailMessage.rfc822(fromName: "Dan Wright", fromEmail: "dan@example.com",
                                       to: ["someone@example.com"], subject: "Hello", body: body,
                                       signature: signature(Signature2086Fixture.asSent))
        #expect(!mail.contains("border:1px solid #fff"))
        #expect(!mail.contains("border:1px solid rgb(255,255,255)"))
        // And it is still a real signed message, not one gutted by the strip.
        #expect(mail.contains("Dan Wright"))
        #expect(mail.contains("www.danwrightphotography.com"))
    }

    // L64: what Dan reviews and approves must be exactly what ships. The preview renders the stripped
    // signature too, so the card is not showing him a message different from the one that goes out.
    @Test func thePreviewShowsTheSameStrippedSignatureThatShips() throws {
        let sig = signature(Signature2086Fixture.asSent)
        let card = try #require(GmailMessage.previewCardHTML(body: body, signature: sig, background: .dark))
        #expect(!card.contains("border:1px solid #fff"))
        #expect(!card.contains("border:1px solid rgb(255,255,255)"))
    }

    // Once Overture has removed it, the warning stops: it is computed on what SHIPS, not on the raw
    // cached copy, so Dan is never scolded about a defect the product has already handled (L11, a message
    // may claim only what its check actually measured).
    @Test func theWarningIsSilentOnceOvertureHasRemovedTheBorder() {
        let sig = signature(Signature2086Fixture.asSent)
        #expect(GmailSignatureHealth.darkBackgroundReason(Signature2086Fixture.asSent) != nil)
        #expect(sig.sendableHTML.flatMap(GmailSignatureHealth.darkBackgroundReason) == nil)
    }

    // The stripper removes BORDERS and does not touch colours. A near-white text or background is also
    // near-invisible on white, and rewriting either would be redesigning Dan's signature rather than
    // removing a defect from it, so those are left for the dark preview to reveal and for him to judge.
    @Test func theStripperTakesBordersAndLeavesColoursAlone() {
        let html = #"<div style="border:1px solid #fff;background:#fefefe"><span style="color:#fdfdfd">Dan</span></div>"#
        let stripped = GmailSignatureHealth.strippingInvisibleBorders(html)
        #expect(!stripped.contains("border:1px solid #fff"), "the border it can fix goes")
        #expect(stripped.contains("background:#fefefe"))
        #expect(stripped.contains("color:#fdfdfd"))
    }

    // A signature with no HTML at all is not a defect and must not become one.
    @Test func noSignatureStripsToNothing() {
        #expect(OutboundSignature.none.sendableHTML == nil)
        #expect(OutboundSignature.plainFallback.sendableHTML == nil)
    }
}
