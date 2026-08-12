import Testing
import Foundation
import SwiftData

// #2053: the send confirmation showed the PLAIN TEXT sign-off while the draft card beside it showed the
// styled signature.
//
// Dan: "I see my signature here but if I click send it disappears and does a plain text signature? that
// violates my rule of what I see on screen should be what's sent."
//
// Both are genuinely parts of the message (rfc822 builds multipart/alternative whenever a stored HTML
// signature exists), but a modern mail client displays the HTML part, so the styled version is what a
// recipient actually sees and the plain text one is a fallback almost nobody reads. The confirmation is
// captioned "The email that will send", so it has to preview the part that will be read (#2029's own
// purpose, L64), and two screens must not disagree about one email (#2018).
//
// The rule below is stated as: the confirmation and the draft card compose the SAME document, from the
// same two ingredients, through the same helper. Neither restates the composition, so this cannot pass by
// copying it.
@MainActor
@Suite("The confirmation previews the same email the draft card does (#2053)")
struct ConfirmationShowsTheStyledSignatureTests {
    // A signature shaped like Dan's real one: a styled HTML part AND a plain text fallback, which is the
    // only case where the two surfaces can disagree.
    private let sig = OutboundSignature(
        html: "<div><span style=\"color:#0f766e\">Dan Wright</span> (he/him)<br>"
            + "<a href=\"https://danwrightphotography.com\">danwrightphotography.com</a></div>",
        plainText: "Best,\nDan Wright\nDan Wright Photography")

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func show(_ ctx: ModelContext) -> (Prospect, Recipient) {
        let key = Prospect.makeNaturalKey(groupName: "G", performanceDate: "2026-09-01", venue: "V")
        let p = Prospect(naturalKey: key, groupName: "G", discipline: "choral", venue: "V",
                         performanceDate: "2026-09-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .approved, ingestedAt: Date())
        p.draftSubject = "Photographs of your September concert"
        p.draftBody = "Hello,\n\nI photograph performing arts in New York."
        ctx.insert(p)
        let r = Recipient(id: "marcus@org.example", email: "marcus@org.example", name: "Marcus Hale",
                          provenance: .presenter)
        p.recipients.append(r)
        ctx.insert(r)
        try? ctx.save()
        return (p, r)
    }

    // The whole rule as one assertion, against the composition the DRAFT CARD renders
    // (DraftSignaturePreview reads previewCardHTML of the pitch and the signature).
    @Test func theConfirmationComposesTheSameDocumentTheDraftCardRenders() throws {
        let ctx = ModelContext(try container())
        let (p, r) = show(ctx)

        let onTheCard = GmailMessage.previewCardHTML(body: try #require(OutgoingPitch.text(for: r, of: p)),
                                                     signature: sig)
        let c = try #require(SendConfirmation(prospect: p, signature: sig))
        let onTheConfirmation = GmailMessage.previewCardHTML(body: c.bodyBeforeSignOff,
                                                             signature: c.signature)

        #expect(onTheConfirmation == onTheCard)
        #expect(onTheConfirmation?.isEmpty == false, "there is a styled document to show at all")
    }

    // And what that document carries is the STYLED signature, which is the half of the message a
    // recipient's mail client actually displays.
    @Test func theStyledSignatureIsWhatTheConfirmationShows() throws {
        let ctx = ModelContext(try container())
        let (p, _) = show(ctx)

        let c = try #require(SendConfirmation(prospect: p, signature: sig))
        let shown = try #require(GmailMessage.previewCardHTML(body: c.bodyBeforeSignOff,
                                                              signature: c.signature))

        #expect(shown.contains(try #require(sig.html)))
        #expect(!shown.contains(sig.plainText),
                "the plain text fallback is not what a mail client displays, so it is not what Dan reviews")
    }

    // The plain text part is still exactly right, because it is still a real part of the message: it is
    // what a client with no HTML shows, and it is what the confirmation falls back to below.
    @Test func thePlainTextPartIsStillTheStringTheSendPathWouldHandGmail() throws {
        let ctx = ModelContext(try container())
        let (p, r) = show(ctx)

        let onTheWire = GmailMessage.previewBody(body: try #require(OutgoingPitch.text(for: r, of: p)),
                                                 signature: sig)
        let c = try #require(SendConfirmation(prospect: p, signature: sig))

        #expect(c.body == onTheWire)
    }

    // The fallback, which is the condition the draft card already handles: with no styled signature
    // stored there is no HTML part in the message at all, so the plain sign-off IS the email.
    @Test func withNoStyledSignatureStoredItFallsBackToThePlainSignOff() throws {
        let ctx = ModelContext(try container())
        let (p, _) = show(ctx)

        let c = try #require(SendConfirmation(prospect: p, signature: .plainFallback))

        #expect(GmailMessage.previewCardHTML(body: c.bodyBeforeSignOff, signature: c.signature) == nil)
        #expect(c.body.hasSuffix(OutboundSignature.plainFallback.plainText))
    }

    // The same defect in the two sheets that are not the cold draft. Fixed as a class, not an instance
    // (L30): a follow-up and a conversation note carry the styled signature on the wire too (#1144), so
    // their confirmations show it for the same reason.
    @Test func afollowUpConfirmationCarriesTheStyledSignatureToo() throws {
        let ctx = ModelContext(try container())
        let (p, r) = show(ctx)
        r.sentAt = Date()
        r.sendState = .sent

        let c = try #require(SendConfirmation(followUpFor: r, of: p, signature: sig))
        let shown = try #require(GmailMessage.previewCardHTML(body: c.bodyBeforeSignOff,
                                                              signature: c.signature))

        #expect(shown.contains(try #require(sig.html)))
    }

    @Test func aconversationNoteConfirmationCarriesTheStyledSignatureToo() throws {
        let ctx = ModelContext(try container())
        let (p, r) = show(ctx)
        r.sentAt = Date()
        r.sendState = .sent

        let c = try #require(SendConfirmation(closingNoteFor: r, of: p, signature: sig))
        let shown = try #require(GmailMessage.previewCardHTML(body: c.bodyBeforeSignOff,
                                                              signature: c.signature))

        #expect(shown.contains(try #require(sig.html)))
    }

    // The guard and its wiring are two claims (#887). Everything above passes with the sheet still
    // drawing the plain text string, which is exactly how the suite stayed green through this defect.
    @Test func theSheetPreviewsThroughTheSameViewTheDraftCardUses() {
        let source = SourceGuardHelper.source("Overture/UI/SendConfirmSheet.swift")
        #expect(!source.isEmpty)
        #expect(source.contains("DraftSignaturePreview("),
                "The confirmation must preview through the SAME view the draft card uses (#2053).")
        #expect(!source.contains("Text(confirmation.body)"),
                "Drawing the plain-text composition directly shows the fallback part of the message rather than the part a mail client displays (#2053).")
    }
}
