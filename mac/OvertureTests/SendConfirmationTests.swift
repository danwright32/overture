import Testing
import Foundation
import SwiftData
@testable import Overture

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

    @Test func buildsRecipientAndSubjectFromAnApprovedProspect() throws {
        let ctx = ModelContext(try container())
        let p = make(ctx)
        let c = SendConfirmation(prospect: p)
        #expect(c?.recipient == "to@org.org")
        #expect(c?.subject == "A photo of your June concert")
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
}
