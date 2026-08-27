import Testing
import Foundation
import SwiftData

// #2145, step two: one reply confirmation, built from what a reply IS rather than from what kind of thing
// is being answered.
//
// An inquiry reply goes out today with no confirmation at all, which means Dan never sees the signature
// the send composes onto it, and the signature is applied to every outgoing mail whether or not he has
// read it. That is the #2086 class (a signature nobody previewed shipping to real recipients), and it
// cannot be closed until the confirmation stops being Prospect-shaped.
//
// The shared initializer takes an audience and a subject that have ALREADY been decided, so it cannot
// disagree with the rule that decided whether the send was allowed (L16, L70).
@MainActor
@Suite("One reply confirmation for either entity (#2145)")
struct SharedReplyConfirmationTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, Inquiry.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func show(_ ctx: ModelContext) -> Prospect {
        let p = Prospect(naturalKey: "k", groupName: "Every Voice Choirs", discipline: "choral",
                         venue: "Merkin Hall", performanceDate: "2026-10-31", sourceListingURL: nil, priorRelationship: "none", production: "self",
                         profile: "strong", coverage: "likely_uncovered", fitScore: 8, tier: "high",
                         fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil)
        ctx.insert(p)
        return p
    }

    private let sig = OutboundSignature(html: "<p>Dan Wright</p>", plainText: "Dan Wright")

    // MARK: the shared initializer

    // Everything the sheet shows comes from the ingredients it was handed, and the plain-text part is
    // composed the one way the wire composes it.
    @Test func aReplyConfirmationIsBuiltFromItsAudienceAndSubject() throws {
        let c = try #require(SendConfirmation(replyTo: ["marta@example.org"],
                                              subject: "Re: your inquiry",
                                              body: "Thursday works. I'll bring the 85mm.",
                                              signature: sig))
        #expect(c.from == .danWright)
        #expect(c.recipient == "marta@example.org")
        #expect(c.subject == "Re: your inquiry")
        #expect(c.bodyBeforeSignOff == "Thursday works. I'll bring the 85mm.")
        #expect(c.signature == sig)
        #expect(c.body == GmailMessage.previewBody(body: "Thursday works. I'll bring the 85mm.",
                                                   signature: sig))
    }

    // Everybody the answer reaches is named, since that is what Dan is approving (L64).
    @Test func everyAddressTheReplyReachesIsNamed() throws {
        let c = try #require(SendConfirmation(replyTo: ["nicole@evc.org", "chelsea@evc.org"],
                                              subject: "Re: October", body: "Tuesday works.",
                                              signature: sig))
        #expect(c.recipient.contains("nicole@evc.org"))
        #expect(c.recipient.contains("chelsea@evc.org"))
    }

    // Nothing to send is nothing to confirm, so a sheet is never built over a send that could not happen.
    @Test func nothingToSendBuildsNoSheet() {
        #expect(SendConfirmation(replyTo: [], subject: "Re: x", body: "Tuesday.", signature: sig) == nil)
        #expect(SendConfirmation(replyTo: ["m@x.org"], subject: "Re: x", body: "   ", signature: sig) == nil)
    }

    // A subject is required here too: the mail cannot be built without one, so a confirmation promising
    // to send it would be promising something impossible.
    @Test func aBlankSubjectBuildsNoSheet() {
        #expect(SendConfirmation(replyTo: ["m@x.org"], subject: "  ", body: "Tuesday.",
                                 signature: sig) == nil)
    }

    // MARK: the show's own reply, now expressed through it

    // The existing show path keeps producing exactly what it produced before, because it is now the same
    // composition with its audience and subject looked up first. Asserted field by field against the
    // shared initializer rather than against remembered values, so the two cannot drift apart.
    @Test func theShowsReplyIsTheSameConfirmationWithItsAudienceLookedUpFirst() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = Recipient(id: "nbecker@evc.org", email: "nbecker@evc.org", provenance: .act)
        r.replied = true
        r.replyAudience = ["nicole@evc.org", "chelsea@evc.org"]
        r.replyDraftSubject = "Re: Photographing the Pumpkin Singalong"
        p.addRecipient(r)

        let viaShow = try #require(SendConfirmation(replyFor: r, of: p, body: "Tuesday works.",
                                                    signature: sig))
        let viaShared = try #require(SendConfirmation(replyTo: SendGroup.replyAudience(of: r),
                                                      subject: SendService.replySubject(for: r, of: p),
                                                      body: "Tuesday works.", signature: sig))
        #expect(viaShow == viaShared)
    }

    // And an inquiry, which has no Prospect anywhere near it, reaches the same sheet through the same
    // audience helper it already sends through.
    @Test func anInquiryReachesTheSameSheetThroughTheSameAudienceHelper() throws {
        let ctx = ModelContext(try container())
        let i = Inquiry(source: .contactForm, inquirerName: "Marta Reyes",
                        inquirerEmail: "marta@example.org", eventName: "Winter recital")
        ctx.insert(i)

        let c = try #require(SendConfirmation(replyTo: SendGroup.replyAudience(of: i),
                                              subject: "Re: your inquiry", body: "Thursday works.",
                                              signature: sig))
        #expect(c.recipient == "marta@example.org")
    }
}
