import Testing
import Foundation
import SwiftData

// #49: before a manual send actually goes out, Dan sees exactly what will be emailed.
// SendConfirmation is the pure value behind that confirm step: it can only be built for
// a prospect that would genuinely send (same guard as SendService.sendOne), and it
// carries the precise recipient + subject to show. No confirmation => nothing to send.
@MainActor
@Suite("Send confirmation")
struct SendConfirmationTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func make(_ ctx: ModelContext, status: ReviewStatus = .approved,
                      email: String? = "to@org.org", subject: String? = "A photo of your June concert",
                      body: String? = "Hi", sentAt: Date? = nil) -> Prospect {
        let key = Prospect.makeNaturalKey(groupName: "G", performanceDate: "2026-07-01", venue: "V")
        let p = Prospect(naturalKey: key, groupName: "G", discipline: "choral", venue: "V",
                         performanceDate: "2026-07-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 7, tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: status, ingestedAt: Date())
        p.draftSubject = subject
        p.draftBody = body
        p.sentAt = sentAt
        ctx.insert(p)
        // Confirmation now reads the next pending recipient (#394). Seed the act recipient directly,
        // so sentAt -> already-sent state too.
        if let id = Recipient.makeId(email: email, formURL: nil) {
            let r = Recipient(id: id, email: email, provenance: .act)
            r.sentAt = sentAt
            r.sendState = sentAt != nil ? .sent : .pending
            p.setRecipients([r])
        }
        try? ctx.save()
        return p
    }

    // #2029. The sheet's preview is captioned "The email that will send" (SendConfirmCopy.previewLabel),
    // and it was not: it showed `prospect.draftBody` alone, so the greeting Dan can see on the draft, the
    // `Attn:` block a generic inbox gets, a performer's own letter, and his sign-off were all absent from
    // the one screen he reads before a real email leaves. A caption is a claim (L21, L64).
    //
    // Every test below states the same rule from a different angle: the string in the sheet is the string
    // the send path hands Gmail, composed by the SAME two helpers, so the two cannot drift.
    @MainActor
    @Suite("The confirmation shows the email that will send (#2029)")
    struct ShowsTheRealEmail {
        private let sig = OutboundSignature(html: nil, plainText: "Best,\nDan")

        private func container() throws -> ModelContainer {
            try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                               configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        }

        @discardableResult
        private func show(_ ctx: ModelContext, body: String = "I photograph performing arts in New York.")
        -> Prospect {
            let key = Prospect.makeNaturalKey(groupName: "G", performanceDate: "2026-07-01", venue: "V")
            let p = Prospect(naturalKey: key, groupName: "G", discipline: "choral", venue: "V",
                             performanceDate: "2026-07-01", sourceListingURL: nil, websiteURL: nil,
                             priorRelationship: "none", production: "self", profile: "strong",
                             coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                             matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                             status: .approved, ingestedAt: Date())
            p.draftSubject = "Photography for your June concert"
            p.draftBody = body
            ctx.insert(p)
            return p
        }

        @discardableResult
        private func contact(_ ctx: ModelContext, on p: Prospect, email: String, name: String?,
                             method: String? = nil, provenance: RecipientProvenance = .presenter)
        -> Recipient {
            let r = Recipient(id: email, email: email, name: name, provenance: provenance,
                              contactMethodRaw: method)
            p.recipients.append(r)
            ctx.insert(r)
            try? ctx.save()
            return r
        }

        // The whole rule as one assertion, against the two helpers the send path itself uses
        // (SendService.deliver composes OutgoingPitch.text, and GmailMessage.rfc822 appends the sign-off
        // through previewBody). Neither is restated here, so this cannot pass by copying the old logic.
        @Test func isTheStringTheSendPathWouldHandGmail() throws {
            let ctx = ModelContext(try container())
            let p = show(ctx)
            let r = contact(ctx, on: p, email: "marcus@org.org", name: "Marcus Hale")

            let onTheWire = GmailMessage.previewBody(body: try #require(OutgoingPitch.text(for: r, of: p)),
                                                     signature: sig)
            let c = try #require(SendConfirmation(prospect: p, signature: sig))

            #expect(c.body == onTheWire)
        }

        // The greeting was the first of the two hidden pieces #2010 made visible on the draft. It was still
        // missing HERE, on the last screen before the send.
        @Test func carriesTheGreetingDanCanSeeOnTheDraft() throws {
            let ctx = ModelContext(try container())
            let p = show(ctx)
            contact(ctx, on: p, email: "marcus@org.org", name: "Marcus Hale")

            let c = try #require(SendConfirmation(prospect: p, signature: sig))

            #expect(c.body.hasPrefix("Hi Marcus,\n\n"))
        }

        // The `Attn:` block is the more surprising piece, because it appears only for a generic inbox.
        @Test func carriesTheAttnBlockAGenericInboxGets() throws {
            let ctx = ModelContext(try container())
            let p = show(ctx)
            contact(ctx, on: p, email: "info@org.org", name: "Marcus Hale",
                    method: ContactMethod.genericInbox.rawValue)

            let c = try #require(SendConfirmation(prospect: p, signature: sig))

            #expect(c.body.contains("Attn: Marcus Hale"))
            #expect(c.body.contains("Hello,"))
        }

        // An opening Dan typed himself is what sends, so it is what the confirmation must show.
        @Test func carriesDansOwnOpeningWhenHeWroteOne() throws {
            let ctx = ModelContext(try container())
            let p = show(ctx)
            let r = contact(ctx, on: p, email: "marcus@org.org", name: "Marcus Hale")
            r.openingOverride = "Marcus, hello again,"

            let c = try #require(SendConfirmation(prospect: p, signature: sig))

            #expect(c.body.hasPrefix("Marcus, hello again,\n\n"))
            #expect(!c.body.contains("Hi Marcus,"), "Overture must not show a greeting it will not send")
        }

        // A directly-addressed performer receives their OWN second-person letter (#641/#789), not the
        // shared third-person body. Showing the shared one would preview an email that never sends.
        @Test func carriesAPerformersOwnLetterNotTheSharedBody() throws {
            let ctx = ModelContext(try container())
            let p = show(ctx, body: "The shared third-person body.")
            let r = contact(ctx, on: p, email: "nina@band.example", name: "Nina Ford", provenance: .performer)
            r.overrideBody = "Nina, I photograph performing arts in New York."

            let c = try #require(SendConfirmation(prospect: p, signature: sig))

            #expect(c.body.contains("Nina, I photograph performing arts in New York."))
            #expect(!c.body.contains("The shared third-person body."))
        }

        // The failure path, and the one most likely to be silently wrong: when no styled Gmail signature
        // is stored, the send path still appends the plain-text sign-off rather than sending unsigned
        // (#1144/#1689). The preview has to show that fallback, not an unsigned email.
        @Test func carriesThePlainSignOffWhenNoStyledSignatureIsStored() throws {
            let ctx = ModelContext(try container())
            let p = show(ctx)
            contact(ctx, on: p, email: "marcus@org.org", name: "Marcus Hale")

            let c = try #require(SendConfirmation(prospect: p, signature: .plainFallback))

            #expect(c.body.hasSuffix(OutboundSignature.plainFallback.plainText))
        }

        // The same defect, in the two sheets that are not the cold draft: both showed their nudge text
        // without the sign-off that the send appends. Fixed as a class, not an instance (L30).
        @Test func afollowUpConfirmationCarriesTheSignOff() throws {
            let ctx = ModelContext(try container())
            let p = show(ctx)
            let r = contact(ctx, on: p, email: "marcus@org.org", name: "Marcus Hale")
            r.sentAt = Date()
            r.sendState = .sent

            let c = try #require(SendConfirmation(followUpFor: r, of: p, signature: sig))

            #expect(c.body.hasSuffix(sig.plainText))
        }

        @Test func aconversationNoteConfirmationCarriesTheSignOff() throws {
            let ctx = ModelContext(try container())
            let p = show(ctx)
            let r = contact(ctx, on: p, email: "marcus@org.org", name: "Marcus Hale")
            r.sentAt = Date()
            r.sendState = .sent

            let c = try #require(SendConfirmation(conversationNudgeFor: r, of: p, kind: .closing,
                                                  signature: sig))

            #expect(c.body.hasSuffix(sig.plainText))
        }
    }

    @Test func buildsRecipientAndSubjectFromAnApprovedProspect() throws {
        let ctx = ModelContext(try container())
        let p = make(ctx)
        let c = SendConfirmation(prospect: p)
        #expect(c?.recipient == "to@org.org")
        #expect(c?.subject == "A photo of your June concert")
    }

    // #360: the confirmation also carries the exact email body about to send, so the branded sheet
    // can preview it, and the From identity, which must be the one true sending identity.
    @Test func carriesTheDraftBodyAndTheSendingIdentity() throws {
        let ctx = ModelContext(try container())
        // #2029: the drafted text is no longer the WHOLE preview (it is the opening, the body, then the
        // sign-off, exactly as the email is assembled), so this asserts the drafted text is carried and
        // leaves the composition itself to the ShowsTheRealEmail suite above. The signature is passed in
        // rather than read from this Mac's stored one, so the test cannot depend on machine state (L2).
        let c = SendConfirmation(prospect: make(ctx, body: "Hi Marcus,\n\nI'd love to photograph the evening."),
                                 signature: .none)
        #expect(c?.body.contains("Hi Marcus,\n\nI'd love to photograph the evening.") == true)
        #expect(c?.from == SendIdentity.danWright)
    }

    @Test func fallsBackWhenSubjectIsMissingOrBlank() throws {
        let ctx = ModelContext(try container())
        #expect(SendConfirmation(prospect: make(ctx, subject: nil))?.subject == "(no subject)")
        #expect(SendConfirmation(prospect: make(ctx, subject: "   "))?.subject == "(no subject)")
    }

    @Test func refusesToBuildForSomethingThatWouldNotSend() throws {
        let ctx = ModelContext(try container())
        #expect(SendConfirmation(prospect: make(ctx, status: .drafted)) == nil)   // not approved
        #expect(SendConfirmation(prospect: make(ctx, email: nil)) == nil)         // no contact
        #expect(SendConfirmation(prospect: make(ctx, email: "")) == nil)          // blank contact
        #expect(SendConfirmation(prospect: make(ctx, body: nil)) == nil)          // no draft
        #expect(SendConfirmation(prospect: make(ctx, sentAt: Date())) == nil)     // already sent
    }

    // #394: on a multi-recipient show the confirm step targets the NEXT pending recipient, and once
    // every recipient is sent there is nothing left to confirm (the partial-send gate).
    @Test func targetsTheNextPendingRecipientThenRefusesWhenAllSent() throws {
        let ctx = ModelContext(try container())
        let key = Prospect.makeNaturalKey(groupName: "G", performanceDate: "2026-07-01", venue: "V")
        let p = Prospect(naturalKey: key, groupName: "G", discipline: "choral", venue: "V",
                         performanceDate: "2026-07-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 7, tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .approved, ingestedAt: Date())
        p.draftSubject = "S"; p.draftBody = "Hi"
        ctx.insert(p)
        let act = Recipient(id: "emma@act.example", email: "emma@act.example", name: "Emma", provenance: .act)
        let presenter = Recipient(id: "noah@p.example", email: "noah@p.example", name: "Noah", provenance: .presenter)
        p.setRecipients([act, presenter])
        try? ctx.save()

        // The act is the first pending recipient.
        #expect(SendConfirmation(prospect: p)?.recipient == "emma@act.example")

        // Mark the act sent: the confirm step now points at the presenter.
        act.sendState = .sent; act.sentAt = Date()
        #expect(SendConfirmation(prospect: p)?.recipient == "noah@p.example")

        // Both sent: nothing left to confirm.
        presenter.sendState = .sent; presenter.sentAt = Date()
        #expect(SendConfirmation(prospect: p) == nil)
    }

    // #948: the draft confirmation carries the draft heading and reassurance, so the one generalized
    // sheet can present it without hardcoding those words.
    @Test func theDraftConfirmationCarriesItsOwnHeadingAndReassurance() throws {
        let ctx = ModelContext(try container())
        let c = SendConfirmation(prospect: make(ctx))
        #expect(c?.title == "Send this email now?")
        #expect(c?.reassurance == "This sends one email right now, to this recipient only. Nothing else goes out.")
    }

    // #948: a follow-up confirmation shows exactly what SendService.sendFollowUp will send. The subject
    // is the REPLY subject (what threads), not the standalone nudge subject the old alert previewed, and
    // From is the one true sending identity.
    @Test func aFollowUpConfirmationShowsExactlyWhatWillSend() throws {
        let ctx = ModelContext(try container())
        let p = make(ctx, subject: "Photographs for G")
        let r = p.recipients.first!
        r.name = "Marcus"

        // #2029: `.none` is the empty sign-off, so this keeps asserting the nudge text EXACTLY while the
        // sign-off itself is covered by afollowUpConfirmationCarriesTheSignOff above.
        let c = SendConfirmation(followUpFor: r, of: p, signature: .none)
        #expect(c?.from == SendIdentity.danWright)
        #expect(c?.recipient == "to@org.org")
        #expect(c?.title == "Send this follow-up now?")
        #expect(c?.reassurance == "This sends one follow-up right now, to this recipient only. Nothing else goes out.")
        #expect(c?.subject == FollowUp.replySubject(originalSubject: "Photographs for G", groupName: "G"))
        #expect(c?.body == FollowUp.nudgeContent(originalSubject: "Photographs for G", groupName: "G",
                                                 contactName: "Marcus", venue: "V", followUpCount: 0).body)
    }

    // #948: a closing note's reassurance names the SECOND thing it does (it closes the lead out); an
    // active note's does not. A prompt kind is not sendable, so it yields no confirmation.
    @Test func aConversationNoteConfirmationSaysWhatAClosingNoteAlsoDoes() throws {
        let ctx = ModelContext(try container())
        let p = make(ctx, subject: "Photographs for G")
        let r = p.recipients.first!

        let active = SendConfirmation(conversationNudgeFor: r, of: p, kind: .active(.interested))
        #expect(active?.title == "Send this note now?")
        #expect(active?.reassurance == "This sends one message right now, to this recipient only.")

        let closing = SendConfirmation(conversationNudgeFor: r, of: p, kind: .closing)
        #expect(closing?.reassurance
                == "This sends one message right now, to this recipient only. It also closes the lead out (kept warm for next time).")

        #expect(SendConfirmation(conversationNudgeFor: r, of: p, kind: .needsState) == nil)
    }
}
