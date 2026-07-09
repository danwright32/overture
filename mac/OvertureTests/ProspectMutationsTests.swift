import Testing
import Foundation
import SwiftData
@testable import Overture

// #468 (SUP-006): a fake MailSender so performSend/sendReply/sendFollowUp/sendConversationNudge
// are testable without hitting the real network or the GmailAuthManager.shared singleton, the
// same reason SendServiceTests.swift keeps its own fakes local to that file.
private final class RecordingSender: MailSender, @unchecked Sendable {
    private(set) var sent: [OutgoingMail] = []
    func send(_ mail: OutgoingMail) async throws -> SentReceipt {
        sent.append(mail)
        return SentReceipt(threadId: "t-recorded", messageID: "<recorded@x.org>")
    }
}

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

    // #652: mirrors markContact's exact pattern (updateRecipient then resumePausedRecipients), since
    // setting a recipient's conversation state is Dan actively engaging with that contact by hand,
    // the same signal markContact already treats as "resume this show's other paused siblings".
    @Test func setRecipientConversationStateSetsItAndResumesPausedRecipients() throws {
        let ctx = ModelContext(try container())
        let p = makeProspect(ctx)
        let target = Recipient(id: "r1", email: "act@example.com", provenance: .act)
        let paused = Recipient(id: "r2", email: "presenter@example.com", provenance: .presenter)
        paused.sendStateRaw = SendState.pending.rawValue
        paused.pausedByReply = true
        p.recipients = [target, paused]
        try? ctx.save()
        let feedback = ActionFeedback()

        ProspectMutations.setRecipientConversationState(QueueItem(p), "r1", .wantsToBook,
                                                         prospects: [p], context: ctx, feedback: feedback)

        let updated = p.recipients.first { $0.id == "r1" }
        #expect(updated?.conversationState == .wantsToBook)
        #expect(updated?.conversationStateSource == .manual)
        #expect(p.recipients.first { $0.id == "r2" }?.pausedByReply == false)   // sibling resumed
    }

    @Test func confirmRecipientConversationStateMakesItManualAndResetsTheReminderClock() throws {
        let ctx = ModelContext(try container())
        let p = makeProspect(ctx)
        let target = Recipient(id: "r1", email: "act@example.com", provenance: .act)
        target.conversationState = .interested
        target.conversationStateSource = .auto
        target.conversationRemindedAt = Date(timeIntervalSince1970: 1)
        p.recipients = [target]
        try? ctx.save()
        let feedback = ActionFeedback()

        ProspectMutations.confirmRecipientConversationState(QueueItem(p), "r1",
                                                            prospects: [p], context: ctx, feedback: feedback)

        let updated = p.recipients.first { $0.id == "r1" }
        #expect(updated?.conversationStateSource == .manual)
        #expect(updated?.conversationRemindedAt == nil)
    }

    @Test func remindRecipientLaterReanchorsOnlyThatRecipientsClock() throws {
        let ctx = ModelContext(try container())
        let p = makeProspect(ctx)
        let target = Recipient(id: "r1", email: "act@example.com", provenance: .act)
        target.conversationState = .interested
        let sibling = Recipient(id: "r2", email: "presenter@example.com", provenance: .presenter)
        p.recipients = [target, sibling]
        try? ctx.save()
        let feedback = ActionFeedback()

        ProspectMutations.remindRecipientLater(QueueItem(p), "r1",
                                               prospects: [p], context: ctx, feedback: feedback)

        #expect(p.recipients.first { $0.id == "r1" }?.conversationRemindedAt != nil)
        #expect(p.recipients.first { $0.id == "r2" }?.conversationRemindedAt == nil)
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

    // MARK: - #468 (SUP-006) markSending/clearSending timing, via an injectable sender

    @Test func performSendMarksSendingImmediatelyAndClearsAfterTheSendCompletes() async throws {
        let ctx = ModelContext(try container())
        let p = makeProspect(ctx, status: .approved)
        p.draftSubject = "S"; p.draftBody = "Hi"
        let r = Recipient(id: "act@example.com", email: "act@example.com", provenance: .act)
        p.recipients = [r]
        try? ctx.save()
        let feedback = ActionFeedback()
        let sender = RecordingSender()
        var marked: [String] = []
        var cleared: [String] = []

        ProspectMutations.performSend("k", prospects: [p], context: ctx, feedback: feedback, sender: sender,
                                      markSending: { marked.append($0) }, clearSending: { cleared.append($0) },
                                      onNeedsReconnect: {})

        #expect(marked == ["k"])       // fired synchronously, before the async send even starts
        #expect(cleared.isEmpty)       // not yet: the send hasn't completed

        while cleared.isEmpty { await Task.yield() }
        #expect(cleared == ["k"])
        #expect(sender.sent.count == 1)
        #expect(p.status == .contacted)
    }

    @Test func sendReplyMarksSendingImmediatelyAndClearsAfterTheSendCompletes() async throws {
        let ctx = ModelContext(try container())
        let p = makeProspect(ctx)
        let r = Recipient(id: "r1", email: "act@example.com", provenance: .act)
        r.sendState = .sent; r.replied = true; r.replyDraftBody = "Glad to help."
        p.recipients = [r]
        try? ctx.save()
        let feedback = ActionFeedback()
        let sender = RecordingSender()
        var marked: [String] = []
        var cleared: [String] = []

        ProspectMutations.sendReply(QueueItem(p), "r1", prospects: [p], context: ctx, feedback: feedback, sender: sender,
                                    markSending: { marked.append($0) }, clearSending: { cleared.append($0) },
                                    onNeedsReconnect: {})

        #expect(marked == ["r1"])
        #expect(cleared.isEmpty)

        while cleared.isEmpty { await Task.yield() }
        #expect(cleared == ["r1"])
        #expect(sender.sent.count == 1)
        #expect(r.replyDraftBody == nil)   // consumed on send
    }

    @Test func sendFollowUpMarksSendingImmediatelyAndClearsAfterTheSendCompletes() async throws {
        let ctx = ModelContext(try container())
        let p = makeProspect(ctx)
        let r = Recipient(id: "r1", email: "act@example.com", provenance: .act)
        r.sendState = .sent; r.sentAt = Date(timeIntervalSince1970: 100)
        p.recipients = [r]
        try? ctx.save()
        let feedback = ActionFeedback()
        let sender = RecordingSender()
        var marked: [String] = []
        var cleared: [String] = []

        ProspectMutations.sendFollowUp("k", "r1", prospects: [p], context: ctx, feedback: feedback, sender: sender,
                                       markSending: { marked.append($0) }, clearSending: { cleared.append($0) })

        #expect(marked == ["r1"])
        #expect(cleared.isEmpty)

        while cleared.isEmpty { await Task.yield() }
        #expect(cleared == ["r1"])
        #expect(sender.sent.count == 1)
        #expect(r.followUpCount == 1)
    }

    @Test func sendConversationNudgeMarksSendingImmediatelyAndClearsAfterTheSendCompletes() async throws {
        let ctx = ModelContext(try container())
        let p = makeProspect(ctx)
        let r = Recipient(id: "r1", email: "act@example.com", provenance: .act)
        r.sendState = .sent; r.sentAt = Date(timeIntervalSince1970: 100)
        p.recipients = [r]
        try? ctx.save()
        let feedback = ActionFeedback()
        let sender = RecordingSender()
        var marked: [String] = []
        var cleared: [String] = []

        ProspectMutations.sendConversationNudge("k", "r1", isClosing: false, prospects: [p], context: ctx, feedback: feedback,
                                                sender: sender,
                                                markSending: { marked.append($0) }, clearSending: { cleared.append($0) })

        #expect(marked == ["r1"])
        #expect(cleared.isEmpty)

        while cleared.isEmpty { await Task.yield() }
        #expect(cleared == ["r1"])
        #expect(sender.sent.count == 1)
        #expect(r.conversationRemindedAt != nil)
    }
}
