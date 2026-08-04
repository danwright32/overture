import Testing
import Foundation

// #2087, following #2086: Overture attaches Dan's Gmail signature to every outgoing pitch verbatim.
// The signature it was attaching wrapped itself in three divs styled `border:1px solid #fff`.
// On the white background Gmail authors signatures for, and on the white card the draft preview
// renders (#1203), those borders are invisible. To every recipient reading in a dark-mode mail
// client they are a hard white outline box around the whole signature. It shipped on real pitches
// for about two weeks and no surface in the product was able to show it, because the one surface
// that renders the signature renders it on the one background that hides it (L69).
//
// `GmailSignatureHealth.corruptionReason` (#1253) already refuses a CORRUPT signature. This is the
// different case it has no concept of: intact, sendable, and defective for part of the audience.
@Suite("A signature that only breaks on a dark background (#2087)")
struct GmailSignatureDarkBackgroundTests {

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "gmail-sig-dark-test-\(UUID().uuidString)")!
    }

    // The real thing, measured, not a shape invented to make the rule fire (L48).
    @Test func theSignatureThatShippedIsFlagged() {
        #expect(GmailSignatureHealth.darkBackgroundReason(Signature2086Fixture.asSent) != nil)
    }

    // And the same signature as the mail client sends it is silent. This is the half that keeps the
    // detector honest: the clean copy still carries `border:0px` on its social icons and `border="0"`
    // attributes on its table and images, so anything matching the word "border" alone would fire here
    // and make the rule useless.
    @Test func theMailClientsCopyOfTheSameSignatureIsSilent() {
        #expect(GmailSignatureHealth.darkBackgroundReason(Signature2086Fixture.asTheMailClientSendsIt) == nil)
    }

    // A signature with no border rules at all is silent, and so is a border in a colour that shows up
    // on both backgrounds, which is a border someone MEANT to draw.
    @Test func aVisibleBorderIsNotADefect() {
        #expect(GmailSignatureHealth.darkBackgroundReason("<div>Dan Wright</div>") == nil)
        #expect(GmailSignatureHealth.darkBackgroundReason(
            "<div style=\"border:1px solid #058c90\">Dan Wright</div>") == nil)
    }

    // The spellings Gmail actually emits for white, all three of which appear in the real signature or
    // are one edit away from it, plus near-white, which is the same defect a shade off.
    @Test func everySpellingOfWhiteCounts() {
        for colour in ["#fff", "#ffffff", "#FFF", "rgb(255,255,255)", "white", "#fdfdfd"] {
            #expect(GmailSignatureHealth.darkBackgroundReason(
                "<div style=\"border:1px solid \(colour)\">x</div>") != nil,
                "a \(colour) border is invisible on white and a box on dark")
        }
    }

    // A zero-width or absent border draws nothing on any background, and both spellings sit in the real
    // signature, so mistaking them for the defect would flag every clean signature Dan ever has.
    @Test func aBorderThatDrawsNothingIsNotADefect() {
        #expect(GmailSignatureHealth.darkBackgroundReason(
            "<div style=\"border:0px\">x</div>") == nil)
        #expect(GmailSignatureHealth.darkBackgroundReason(
            "<div style=\"border:none\">x</div>") == nil)
        #expect(GmailSignatureHealth.darkBackgroundReason(
            "<img border=\"0\" src=\"https://icon.example/x.png\">") == nil)
    }

    // L54: a guard may refuse only what the system genuinely cannot do. This signature sends perfectly
    // well, and every light-mode reader sees exactly what Dan intended, so flagging it must not take it
    // off the wire the way the corruption guard takes a corrupt one off. Falling back to the plain-text
    // sign-off here would make the product worse for the whole audience to spare part of it a border.
    @Test func flaggingItNeverStopsItBeingSent() {
        let d = freshDefaults()
        GmailSignatureStore.store(Signature2086Fixture.asSent, defaults: d)

        #expect(GmailSignatureStore.currentHTML(defaults: d) == Signature2086Fixture.asSent)
        #expect(GmailSignatureStore.currentSignature(defaults: d).html == Signature2086Fixture.asSent)
        #expect(GmailSignatureStore.currentDarkBackgroundIssue(defaults: d) != nil)
    }

    // L53: two independent checks must never share one status field, or a pass from one erases the
    // other's failure and the condition it watches becomes unreportable. These are genuinely different
    // findings with different consequences (one refuses, one warns), so each answers only for itself.
    @Test func theTwoChecksAnswerSeparately() {
        let corrupt = "<div>Dan Wright\\240he/they</div>"

        #expect(GmailSignatureHealth.corruptionReason(Signature2086Fixture.asSent) == nil)
        #expect(GmailSignatureHealth.darkBackgroundReason(Signature2086Fixture.asSent) != nil)

        #expect(GmailSignatureHealth.corruptionReason(corrupt) != nil)
        #expect(GmailSignatureHealth.darkBackgroundReason(corrupt) == nil)
    }

    // An empty cache is not a finding. Nothing stored means nothing to warn about, and a warning shown
    // against a signature that does not exist would be noise on every fresh install.
    @Test func noStoredSignatureIsNoFinding() {
        #expect(GmailSignatureStore.currentDarkBackgroundIssue(defaults: freshDefaults()) == nil)
    }
}
