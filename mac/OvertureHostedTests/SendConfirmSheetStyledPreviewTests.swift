import Testing
import Foundation
import SwiftData
import SwiftUI
import ViewInspector
@testable import Overture

// #2053, the rendering half of the claim. The pure suite proves the confirmation CARRIES the ingredients
// that compose the styled document; only a rendered sheet can show it actually puts them on screen, which
// is the half that was wrong (every model test passed while the sheet drew the plain-text string).
//
// @MainActor: inspecting a SwiftUI view must run on the main actor, or it crashes intermittently
// depending on the parallel runner's thread. Every ViewInspector suite in this repo carries it.
@Suite("The send sheet renders the styled preview (#2053)")
struct SendConfirmSheetStyledPreviewTests {
    private let sig = OutboundSignature(
        html: "<div><span style=\"color:#0f766e\">Dan Wright</span> (he/him)</div>",
        plainText: "Best,\nDan Wright\nDan Wright Photography")

    private func confirmation(signature: OutboundSignature) throws -> SendConfirmation {
        let ctx = ModelContext(try ModelContainer(
            for: Schema([Prospect.self, Recipient.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
        let key = Prospect.makeNaturalKey(groupName: "G", performanceDate: "2026-09-01", venue: "V")
        let p = Prospect(naturalKey: key, groupName: "G", discipline: "choral", venue: "V",
                         performanceDate: "2026-09-01", sourceListingURL: nil,
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
        return try #require(SendConfirmation(prospect: p, signature: signature))
    }

    // The preview on the last screen before a real email leaves is the same view the draft card uses, so
    // the two cannot show different versions of one message.
    @Test func thePreviewIsTheSameViewTheDraftCardUses() throws {
        let sheet = SendConfirmSheet(confirmation: try confirmation(signature: sig),
                                     onSend: {}, onCancel: {})

        let preview = try sheet.inspect().find(DraftSignaturePreview.self).actualView()

        #expect(preview.signature == sig)
        #expect(GmailMessage.previewCardHTML(body: preview.draftBody, signature: preview.signature) != nil,
                "the view is handed a body and a signature that genuinely compose a styled document")
    }

    // With no styled signature stored there is no HTML part to show, and the sheet still previews through
    // the same view, which renders the plain sign-off itself rather than leaving the sheet blank.
    @Test func withNoStyledSignatureTheSamePreviewShowsThePlainSignOff() throws {
        let sheet = SendConfirmSheet(confirmation: try confirmation(signature: .plainFallback),
                                     onSend: {}, onCancel: {})

        let preview = try sheet.inspect().find(DraftSignaturePreview.self).actualView()
        let texts = try sheet.inspect().findAll(ViewType.Text.self).map { try $0.string() }

        #expect(GmailMessage.previewCardHTML(body: preview.draftBody,
                                             signature: preview.signature) == nil)
        #expect(texts.contains { $0.hasSuffix(OutboundSignature.plainFallback.plainText) },
                "the sign-off the email will carry is on screen, not a blank preview")
    }
}
