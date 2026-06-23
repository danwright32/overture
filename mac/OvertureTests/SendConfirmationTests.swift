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
        try ModelContainer(for: Schema([Prospect.self]),
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
        p.contactEmail = email
        p.draftSubject = subject
        p.draftBody = body
        p.sentAt = sentAt
        ctx.insert(p)
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
}
