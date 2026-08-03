import Testing
import Foundation
import SwiftData
@testable import Overture

// #2010. Dan's rule, 2026-08-03, on learning the app adds a greeting he cannot see:
//
//   "Basically, i want whatever is in the text box that I see to be what's sent. There should never be
//    any hidden addition that I cannot see in the app"
//
// The email used to be assembled at send from three pieces, two of which appeared nowhere in the app: a
// greeting, and an "Attn:" block that only shows up for a generic inbox. So a draft he read and approved
// was not the thing that went out, and typing his own greeting into the body sent two.
//
// Now the opening is a real, visible, editable field per contact, prefilled with exactly what Overture
// would have composed. Send adds nothing: the email is the opening, then the body.
@MainActor
@Suite("What Dan sees is what sends (#2010)")
struct WhatYouSeeIsWhatSendsTests {

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func prospect(_ ctx: ModelContext, body: String = "I photograph performing arts in New York.")
    -> Prospect {
        let p = Prospect(naturalKey: "k|2026-09-12|weill", groupName: "Aurora Strings",
                         discipline: "music", venue: "Weill Recital Hall", performanceDate: "2026-09-12",
                         sourceListingURL: nil, websiteURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 5, tier: "mid", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil)
        p.draftBody = body
        p.draftSubject = "Photography for your September concert"
        ctx.insert(p)
        return p
    }

    private func recipient(_ ctx: ModelContext, on p: Prospect, email: String, name: String?,
                           method: String? = nil, provenance: RecipientProvenance = .presenter)
    -> Recipient {
        let r = Recipient(id: email, email: email, name: name, provenance: provenance,
                          contactMethodRaw: method)
        p.recipients.append(r)
        ctx.insert(r)
        return r
    }

    // The whole rule, as one assertion: nothing reaches the outgoing email that was not on screen.
    @Test func thesentEmailIsExactlyTheOpeningPlusTheBody() throws {
        let ctx = try context()
        let p = prospect(ctx)
        let r = recipient(ctx, on: p, email: "sarah@aurora.example", name: "Sarah Chen")

        let sent = try #require(OutgoingPitch.text(for: r, of: p))

        #expect(sent == r.outgoingOpening + "\n\n" + p.draftBody!,
                "the email must be the visible opening and the visible body, and nothing else")
    }

    // Unedited, the opening is exactly what the app used to add silently, so nothing about a normal
    // pitch changes. This is what makes the field safe to leave alone.
    @Test func theopeningDefaultsToWhatOvertureWouldHaveComposed() throws {
        let ctx = try context()
        let p = prospect(ctx)
        let r = recipient(ctx, on: p, email: "sarah@aurora.example", name: "Sarah Chen")

        #expect(r.outgoingOpening == "Hi Sarah,")
    }

    // The "Attn:" block was the more surprising of the two hidden additions, because it appears only for
    // some addresses. It is part of the opening now, so it is visible wherever it applies.
    @Test func agenericInboxShowsItsAttnLineAndImpersonalGreetingInTheOpening() throws {
        let ctx = try context()
        let p = prospect(ctx)
        let r = recipient(ctx, on: p, email: "info@aurora.example", name: "Sarah Chen",
                          method: ContactMethod.genericInbox.rawValue)

        #expect(r.outgoingOpening.contains("Attn: Sarah Chen"))
        #expect(r.outgoingOpening.contains("Hello,"))
        let sent = try #require(OutgoingPitch.text(for: r, of: p))
        #expect(sent == r.outgoingOpening + "\n\n" + p.draftBody!)
    }

    // Dan's own words on how he wants to use it: "if it's multiple i just don't touch it but if it's
    // single and I want to update it I can". An edited opening is used verbatim, with no re-composition
    // on top of it.
    @Test func aneditedOpeningIsSentExactlyAsTyped() throws {
        let ctx = try context()
        let p = prospect(ctx)
        let r = recipient(ctx, on: p, email: "sarah@aurora.example", name: "Sarah Chen")
        r.openingOverride = "Sarah, hello again,"

        #expect(r.outgoingOpening == "Sarah, hello again,")
        let sent = try #require(OutgoingPitch.text(for: r, of: p))
        #expect(sent.hasPrefix("Sarah, hello again,\n\n"))
        #expect(!sent.contains("Hi Sarah,"), "Overture must not add its own greeting on top of his")
    }

    // Why the opening is per CONTACT rather than per show: editing it on a show with two contacts must
    // never address the second person by the first one's name.
    @Test func editingOneContactsOpeningLeavesTheOthersAlone() throws {
        let ctx = try context()
        let p = prospect(ctx)
        let sarah = recipient(ctx, on: p, email: "sarah@aurora.example", name: "Sarah Chen")
        let john = recipient(ctx, on: p, email: "john@aurora.example", name: "John Reid")
        sarah.openingOverride = "Sarah, hello again,"

        #expect(sarah.outgoingOpening == "Sarah, hello again,")
        #expect(john.outgoingOpening == "Hi John,", "the other contact keeps his own opening")
    }

    // Clearing the field goes back to Overture's own opening rather than sending an email with no
    // greeting at all. An empty opening is a mistake, not an instruction.
    @Test func clearingTheOpeningRestoresOverturesOwn() throws {
        let ctx = try context()
        let p = prospect(ctx)
        let r = recipient(ctx, on: p, email: "sarah@aurora.example", name: "Sarah Chen")
        r.openingOverride = "   "

        #expect(r.outgoingOpening == "Hi Sarah,")
    }

    // The copy path and the send path must never differ, which is what OutgoingPitch exists for. A
    // performer's own second-person draft still wins over the shared body, unchanged.
    @Test func aperformersOwnDraftStillWinsAndKeepsItsOpening() throws {
        let ctx = try context()
        let p = prospect(ctx)
        let r = recipient(ctx, on: p, email: "act@band.example", name: "Nina Ford", provenance: .performer)
        r.overrideBody = "Nina, I photograph performing arts in New York."

        let sent = try #require(OutgoingPitch.text(for: r, of: p))
        #expect(sent == r.outgoingOpening + "\n\nNina, I photograph performing arts in New York.")
    }
}
