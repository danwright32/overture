import Testing
import Foundation
import SwiftUI
import ViewInspector
@testable import Overture

// #2086, superseding #2087's warning.
//
// #2087 put a sentence beside the preview telling Dan to fix his signature in Gmail Settings, because the
// preview rendered on a white card and was structurally unable to show a white border. On 2026-08-04 that
// instruction turned out to be impossible to follow: the bordered wrappers come from the signature
// generator's markup, so they ride along with any copy of the rendered signature, and Gmail's editor
// offers no way to select a wrapper or set a border colour. A refetch after Dan re-pasted his signature
// returned a genuinely different value with all three border rules byte identical.
//
// So the sentence is gone and Overture strips the borders instead (Dan's call). What this suite pins now
// is the pair of claims that replaced it: the preview no longer says the thing that cannot be acted on,
// and the message it renders no longer carries the defect on EITHER background.
@Suite("What the preview shows once Overture strips the border (#2086)")
struct SignatureDarkBackgroundWarningTests {
    private let body = "I photograph performing arts in New York."

    private func signature(_ html: String) -> OutboundSignature {
        OutboundSignature(html: html, plainText: OutboundSignature.plainFallback.plainText)
    }

    private func texts(_ view: DraftSignaturePreview) throws -> [String] {
        try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
    }

    // The instruction that could not be followed is gone from the surface Dan reads. Asserted on the
    // words themselves rather than on a symbol name, so deleting the constant cannot make this vacuous.
    @Test func thePreviewNoLongerTellsDanToEditTheSignatureInGmail() throws {
        let shown = try texts(DraftSignaturePreview(draftBody: body,
                                                    signature: signature(Signature2086Fixture.asSent)))
        #expect(!shown.contains { $0.localizedCaseInsensitiveContains("Edit it in Gmail settings") })
        #expect(!shown.contains { $0.localizedCaseInsensitiveContains("white box around your signature") })
    }

    // And the reason it is gone: the defect is not in the message any more. The strip is proven on the
    // wire in SignatureBorderStripTests; this is the same claim about the thing actually rendered on
    // screen, which is what Dan approves (L64).
    @Test func theRenderedPreviewCarriesNoInvisibleBorderOnEitherBackground() throws {
        let sig = signature(Signature2086Fixture.asSent)
        for background in PreviewBackground.allCases {
            let card = try #require(GmailMessage.previewCardHTML(body: body, signature: sig,
                                                                 background: background))
            #expect(!card.contains("border:1px solid #fff"))
            #expect(!card.contains("border:1px solid rgb(255,255,255)"))
        }
    }

    // The plain sign-off path has no styled signature at all, so it must not acquire either the switch or
    // a warning about styling it does not have.
    @Test func theplainSignOffShowsNoStylingControlsAtAll() throws {
        let view = DraftSignaturePreview(draftBody: body, signature: .plainFallback)
        #expect((try? view.inspect().find(ViewType.Picker.self)) == nil)
        let shown = try texts(view)
        #expect(!shown.contains { $0.localizedCaseInsensitiveContains("dark mode") })
    }
}
