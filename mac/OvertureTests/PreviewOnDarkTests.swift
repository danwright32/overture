import Testing
import Foundation

// #2086: the draft preview renders the outgoing email on a WHITE card, which is the one background a
// white border is invisible on. That is not a gap in the preview's honesty (it showed exactly what was
// sent) but a gap in what it is STRUCTURALLY ABLE to show: a defect that only appears on dark could be
// approved, and was, on every pitch for about two weeks, because the only surface rendering the
// signature rendered it on the background that hides it (L69).
//
// So the preview gains the other background. The detector shipped in #2087 says a signature looks wrong
// on dark; this lets Dan SEE it, which is the difference between being told and being shown, and it also
// covers the defects no detector anticipated.
@Suite("The draft preview on a dark background (#2086)")
struct PreviewOnDarkTests {
    private let body = "Hello there.\n\nDan"

    private func signature(_ html: String) -> OutboundSignature {
        OutboundSignature(html: html, plainText: "Dan Wright")
    }

    // The dark card is genuinely dark: a recipient reading in dark mode is the audience it stands in for.
    @Test func theDarkCardPutsTheEmailOnADarkSurface() throws {
        let card = try #require(GmailMessage.previewCardHTML(
            body: body, signature: signature(Signature2086Fixture.asSent), background: .dark))
        #expect(card.contains("background:\(PreviewBackground.dark.surfaceCSS)"))
        #expect(!card.contains("background:#ffffff"), "the dark card must not carry the white surface")
    }

    // The light card is untouched: it is what a Gmail signature is authored for, and #1203 chose true
    // white deliberately so a signature's own white divider rules stay invisible there.
    @Test func theLightCardStillRendersOnTrueWhite() throws {
        let card = try #require(GmailMessage.previewCardHTML(
            body: body, signature: signature(Signature2086Fixture.asSent), background: .light))
        #expect(card.contains("background:#ffffff"))
    }

    // THE test, and the reason both backgrounds exist: the dark card shows exactly what a dark-mode
    // recipient gets, defect and all. Overture now strips the border it CAN remove (#2086), so the case
    // this has to prove is the one it cannot: near-white styling that survives the strip shows up here,
    // on the background it goes wrong on, and nowhere else. A preview that only ever rendered on white
    // could not show this, which is the whole class L69 names.
    @Test func theDarkCardShowsWhatSurvivesTheStrip() throws {
        // A near-white BACKGROUND on the signature's own wrapper: not a border, so the stripper leaves it
        // (rewriting colours would be redesigning the signature), and invisible on the white card.
        let awkward = #"<div style="background:#fdfdfd;padding:4px">Dan Wright</div>"#
        let onDark = try #require(GmailMessage.previewCardHTML(
            body: body, signature: signature(awkward), background: .dark))
        let onLight = try #require(GmailMessage.previewCardHTML(
            body: body, signature: signature(awkward), background: .light))

        #expect(onDark.contains("background:#fdfdfd"), "the dark card renders it verbatim")
        // The card's own surface is what differs, and it is what makes the near-white block visible.
        #expect(onDark.contains("background:\(PreviewBackground.dark.surfaceCSS)"))
        #expect(onLight.contains("background:#ffffff"))
        // Same message either way: only the surface under it changes, so switching cannot mislead.
        #expect(onDark.replacingOccurrences(of: PreviewBackground.dark.surfaceCSS, with: "#ffffff")
                    .contains("Dan Wright"))
    }

    // What Overture removes on the way out is gone from the preview too, on BOTH backgrounds, because the
    // preview must show the message that ships and not the raw cached signature (L64).
    @Test func neitherBackgroundShowsTheBorderOvertureStrips() throws {
        for background in PreviewBackground.allCases {
            let card = try #require(GmailMessage.previewCardHTML(
                body: body, signature: signature(Signature2086Fixture.asSent), background: background))
            #expect(!card.contains("border:1px solid #fff"))
            #expect(!card.contains("border:1px solid rgb(255,255,255)"))
        }
    }

    // Both backgrounds carry the element the measuring script looks for, or switching to dark would
    // silently produce a preview that measures nothing and collapses (#2062).
    @Test func bothBackgroundsCarryTheMeasuredCardElement() throws {
        for background in PreviewBackground.allCases {
            let card = try #require(GmailMessage.previewCardHTML(
                body: body, signature: signature(Signature2086Fixture.asSent), background: background))
            #expect(card.contains(GmailMessage.previewCardElementID),
                    "\(background) must carry the measured element")
        }
    }

    // Neither background reaches the recipient: the wire message must not carry a page background of its
    // own. #1203 established this for the white card and it has to hold for the dark one too.
    @Test func neitherBackgroundReachesTheWireMessage() throws {
        let wire = try #require(GmailMessage.previewHTML(
            body: body, signature: signature(Signature2086Fixture.asSent)))
        for background in PreviewBackground.allCases {
            #expect(!wire.contains(background.surfaceCSS))
        }
        #expect(!wire.contains(GmailMessage.previewCardElementID))
    }

    // Which background the preview OPENS on. Light is the default, because that is what the signature is
    // authored for and what most readers see. A signature the detector has already judged wrong on dark
    // opens on dark instead: the evidence belongs in front of Dan without a click, at the one moment
    // there is something to look at. A control he has to discover is one he does not use (L49).
    @Test func aSignatureThatBreaksOnDarkOpensOnDark() {
        #expect(PreviewBackground.opening(for: Signature2086Fixture.asSent) == .dark)
    }

    @Test func acleanSignatureOpensOnLight() {
        #expect(PreviewBackground.opening(for: Signature2086Fixture.asTheMailClientSendsIt) == .light)
    }

    // No signature HTML at all is not a defect, so it opens on light like any clean one.
    @Test func noSignatureOpensOnLight() {
        #expect(PreviewBackground.opening(for: nil) == .light)
    }
}
