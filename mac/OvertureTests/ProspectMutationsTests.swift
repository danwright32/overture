import Testing
import Foundation
import SwiftData
@testable import Overture

@MainActor
@Suite("ProspectMutations")
struct ProspectMutationsTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func makeProspect(_ ctx: ModelContext, key: String = "k", status: ReviewStatus = .new) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: "Aurora Strings", discipline: "music", venue: "Weill Recital Hall",
                         performanceDate: "2026-08-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil, status: status)
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    @Test func setStatusUpdatesStatusAndDismissReason() throws {
        let ctx = ModelContext(try container())
        let p = makeProspect(ctx)
        let feedback = ActionFeedback()
        ProspectMutations.setStatus(QueueItem(p), .dismissed, .notInterested,
                                    prospects: [p], context: ctx, feedback: feedback)
        #expect(p.status == .dismissed)
        #expect(p.dismissReasonRaw == DismissReason.notInterested.rawValue)
    }

    @Test func markContactSetsResolutionAndResumesPausedRecipients() throws {
        let ctx = ModelContext(try container())
        let p = makeProspect(ctx)
        let recipient = Recipient(id: "r1", email: "act@example.com", provenance: .act)
        recipient.sendStateRaw = SendState.suppressed.rawValue
        recipient.suppressionReasonRaw = RecipientSuppressionReason.declined.rawValue
        p.recipients = [recipient]
        try? ctx.save()
        let feedback = ActionFeedback()

        ProspectMutations.markContact(QueueItem(p), "r1", .declinedSoft, false,
                                      prospects: [p], context: ctx, feedback: feedback)

        #expect(p.recipients.first?.resolution == .declinedSoft)
    }

    @Test func confirmBookingSetsOutcomeAndSuppressesUntriedRecipients() throws {
        let ctx = ModelContext(try container())
        let p = makeProspect(ctx)
        let untried = Recipient(id: "r2", email: "presenter@example.com", provenance: .presenter)
        untried.sendStateRaw = SendState.pending.rawValue
        p.recipients = [untried]
        try? ctx.save()
        let feedback = ActionFeedback()

        ProspectMutations.confirmBooking(QueueItem(p), prospects: [p], context: ctx, feedback: feedback)

        #expect(p.outcome == .booked)
        #expect(p.outcomeSourceRaw == OutcomeSource.manual.rawValue)
        #expect(p.recipients.first?.sendState == .suppressed)
    }

    @Test func addRecipientManuallyCreatesAFreshRecipient() throws {
        let ctx = ModelContext(try container())
        let p = makeProspect(ctx)
        let feedback = ActionFeedback()

        ProspectMutations.addRecipientManually(QueueItem(p), email: "jane@newcontact.example", name: "Jane Doe",
                                                prospects: [p], context: ctx, feedback: feedback)

        #expect(p.recipients.map(\.id) == ["jane@newcontact.example"])
        #expect(p.recipients.first?.name == "Jane Doe")
        #expect(p.recipients.first?.provenance == .manual)
        #expect(feedback.message == "Added Jane Doe. 1 recipient on Aurora Strings now.")
    }

    @Test func addRecipientManuallyBlocksAnActiveDuplicate() throws {
        let ctx = ModelContext(try container())
        let p = makeProspect(ctx)
        let existing = Recipient(id: "jane@example.com", email: "jane@example.com", provenance: .act)
        existing.sendState = .sent
        p.recipients = [existing]
        try? ctx.save()
        let feedback = ActionFeedback()

        ProspectMutations.addRecipientManually(QueueItem(p), email: "jane@example.com", name: "Jane Doe",
                                                prospects: [p], context: ctx, feedback: feedback)

        #expect(p.recipients.count == 1)
        #expect(feedback.message == "Jane Doe is already a recipient on Aurora Strings.")
    }

    @Test func addRecipientManuallyResumesARemovedContact() throws {
        let ctx = ModelContext(try container())
        let p = makeProspect(ctx)
        let removed = Recipient(id: "jane@example.com", email: "jane@example.com", provenance: .act)
        removed.sendState = .suppressed
        removed.suppressionReason = .removedByDan
        removed.sentAt = Date()
        p.recipients = [removed]
        try? ctx.save()
        let feedback = ActionFeedback()

        ProspectMutations.addRecipientManually(QueueItem(p), email: "jane@example.com", name: "Jane Doe",
                                                prospects: [p], context: ctx, feedback: feedback)

        #expect(p.recipients.count == 1)
        #expect(p.recipients.first?.sendState == .sent)
        #expect(p.recipients.first?.suppressionReasonRaw == nil)
        #expect(feedback.message == "Resumed pursuing Jane Doe on Aurora Strings.")
    }

    @Test func addRecipientManuallyResumesAnUntriedDeclinedContactAsStillPending() throws {
        let ctx = ModelContext(try container())
        let p = makeProspect(ctx)
        let untried = Recipient(id: "jane@example.com", email: "jane@example.com", provenance: .act)
        untried.sendState = .suppressed
        untried.suppressionReason = .declined
        p.recipients = [untried]
        try? ctx.save()
        let feedback = ActionFeedback()

        ProspectMutations.addRecipientManually(QueueItem(p), email: "jane@example.com", name: "Jane Doe",
                                                prospects: [p], context: ctx, feedback: feedback)

        #expect(p.recipients.count == 1)
        #expect(p.recipients.first?.sendState == .pending)
        #expect(p.recipients.first?.sentAt == nil)
        #expect(feedback.message == "Resumed pursuing Jane Doe on Aurora Strings.")
    }

    @Test func removeRecipientManuallyDeletesAPendingOneAndAcknowledges() throws {
        let ctx = ModelContext(try container())
        let p = makeProspect(ctx)
        let pending = Recipient(id: "jane@example.com", email: "jane@example.com", provenance: .act)
        p.recipients = [pending]
        try? ctx.save()
        let feedback = ActionFeedback()

        ProspectMutations.removeRecipientManually(QueueItem(p), "jane@example.com", "Jane Doe",
                                                   prospects: [p], context: ctx, feedback: feedback)

        #expect(p.recipients.isEmpty)
        #expect(feedback.message == "Removed Jane Doe from Aurora Strings.")
    }

    @Test func removeRecipientManuallySuppressesASentOneAndAcknowledges() throws {
        let ctx = ModelContext(try container())
        let p = makeProspect(ctx)
        let sent = Recipient(id: "jane@example.com", email: "jane@example.com", provenance: .act)
        sent.sendState = .sent
        p.recipients = [sent]
        try? ctx.save()
        let feedback = ActionFeedback()

        ProspectMutations.removeRecipientManually(QueueItem(p), "jane@example.com", "Jane Doe",
                                                   prospects: [p], context: ctx, feedback: feedback)

        #expect(p.recipients.count == 1)
        #expect(p.recipients.first?.sendState == .suppressed)
        #expect(p.recipients.first?.suppressionReason == .removedByDan)
        #expect(feedback.message == "Removed Jane Doe from Aurora Strings.")
    }
}
