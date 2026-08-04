import Testing
import Foundation
import SwiftUI
import ViewInspector
@testable import Overture

// #2087, the half that decides whether any of this reaches Dan. A detector nobody reads is a field with
// a writer and no consumer (L46), and the check it sits beside is already exactly that: nothing in the
// app calls `currentSignatureIssue`, so #1253's corrupt-signature finding has never once been on screen.
// This one is wired to the surface where the defect is invisible by construction: the draft preview,
// which renders the signature on a white card (#1203) and so is structurally unable to show a white
// border (L69). The sentence beside it is the only thing that can.
//
// Wired inside DraftSignaturePreview rather than at either call site, so the draft review card and the
// send confirmation sheet get it from one implementation and a third preview surface cannot be added
// without it (L30).
//
// @MainActor: inspecting a SwiftUI view must run on the main actor, as every ViewInspector suite here does.
@MainActor
@Suite("The preview says when the signature only breaks on dark (#2087)")
struct SignatureDarkBackgroundWarningTests {
    private let body = "I photograph performing arts in New York."

    private func signature(_ html: String) -> OutboundSignature {
        OutboundSignature(html: html, plainText: OutboundSignature.plainFallback.plainText)
    }

    private func texts(_ view: DraftSignaturePreview) throws -> [String] {
        try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
    }

    // The signature that actually shipped for two weeks. Dan is looking at a preview that cannot show
    // the problem, so the preview has to say it.
    @Test func theRealSignatureThatShippedWarnsBesideThePreview() throws {
        let view = DraftSignaturePreview(draftBody: body,
                                         signature: signature(Signature2086Fixture.asSent))

        #expect(try texts(view).contains(GmailCopy.signatureLooksWrongOnDark))
    }

    // And a signature with nothing wrong with it says nothing at all. A warning that shows on every
    // draft whatever the signature holds is a warning Dan stops reading (L36).
    @Test func acleanSignatureSaysNothing() throws {
        let view = DraftSignaturePreview(
            draftBody: body,
            signature: signature(Signature2086Fixture.asTheMailClientSendsIt))

        #expect(!(try texts(view).contains(GmailCopy.signatureLooksWrongOnDark)))
    }

    // With no styled signature at all there is nothing to be wrong, and the plain sign-off path must not
    // acquire a warning about styling it does not have.
    @Test func theplainSignOffSaysNothingEither() throws {
        let view = DraftSignaturePreview(draftBody: body, signature: .plainFallback)

        #expect(!(try texts(view).contains(GmailCopy.signatureLooksWrongOnDark)))
    }

    // The sentence has to say what a dark-mode reader sees AND what to do about it, because the fix is
    // not in Overture: the signature lives in Gmail's own settings and only Dan can change it.
    @Test func theSentenceNamesBothTheEffectAndTheFix() {
        let copy = GmailCopy.signatureLooksWrongOnDark
        #expect(copy.localizedCaseInsensitiveContains("dark mode"))
        #expect(copy.localizedCaseInsensitiveContains("Gmail"))
    }
}
