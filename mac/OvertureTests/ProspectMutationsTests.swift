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

    // #361: after a successful send, onSent reports whether that send EMPTIED the show (no pending
    // recipient left). The queue uses this to play the leaving delight only when the row actually
    // departs: a single-recipient show is fully sent in one go.
    @Test func performSendReportsFullySentWhenTheLastRecipientGoes() async throws {
        let ctx = ModelContext(try container())
        let p = makeProspect(ctx, status: .approved)
        p.draftSubject = "S"; p.draftBody = "Hi"
        p.recipients = [Recipient(id: "act@example.com", email: "act@example.com", provenance: .act)]
        try? ctx.save()
        let sender = RecordingSender()
        var sentReports: [(String, Bool)] = []

        ProspectMutations.performSend("k", prospects: [p], context: ctx, feedback: ActionFeedback(), sender: sender,
                                      markSending: { _ in }, clearSending: { _ in },
                                      onNeedsReconnect: {},
                                      onSent: { id, fullySent in sentReports.append((id, fullySent)) })

        while sentReports.isEmpty { await Task.yield() }
        #expect(sentReports.count == 1)
        #expect(sentReports.first?.0 == "k")
        #expect(sentReports.first?.1 == true)
    }

    // #361: a multi-recipient show still has someone pending after one send, so onSent reports NOT
    // fully sent, and the row stays in the queue (no leaving delight yet).
    @Test func performSendReportsNotFullySentWhileARecipientRemains() async throws {
        let ctx = ModelContext(try container())
        let p = makeProspect(ctx, status: .approved)
        p.draftSubject = "S"; p.draftBody = "Hi"
        p.recipients = [
            Recipient(id: "act@example.com", email: "act@example.com", provenance: .act),
            Recipient(id: "pres@example.com", email: "pres@example.com", provenance: .presenter),
        ]
        try? ctx.save()
        let sender = RecordingSender()
        var sentReports: [(String, Bool)] = []

        ProspectMutations.performSend("k", prospects: [p], context: ctx, feedback: ActionFeedback(), sender: sender,
                                      markSending: { _ in }, clearSending: { _ in },
                                      onNeedsReconnect: {},
                                      onSent: { id, fullySent in sentReports.append((id, fullySent)) })

        while sentReports.isEmpty { await Task.yield() }
        #expect(sentReports.first?.1 == false)
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

    // #718: overriding records the EXACT current draft body, so a later edit to different text
    // silently invalidates it (Recipient.isSendablePending/Prospect.isSalutationReviewOverridden
    // compare against this stored copy, not a bare boolean).
    @Test func overrideSalutationReviewRecordsTheCurrentDraftBody() throws {
        let ctx = ModelContext(try container())
        let p = makeProspect(ctx)
        p.draftBody = "Hi 2026 season, here is what we offer."
        p.draftNeedsSalutationReview = true
        try? ctx.save()
        let feedback = ActionFeedback()

        ProspectMutations.overrideSalutationReview(QueueItem(p), prospects: [p], context: ctx, feedback: feedback)

        #expect(p.draftSalutationReviewOverriddenBody == "Hi 2026 season, here is what we offer.")
        #expect(p.isSalutationReviewOverridden == true)
    }

    // #789: overriding the draft-lint block records the EXACT outgoing text of each BLOCKED, still
    // PENDING recipient. A clean recipient must gain no override (a stale one would silently wave
    // through a future bad edit to its text), and an already-sent one is left alone entirely.
    @Test func overrideDraftLintRecordsOnlyTheBlockedPendingRecipientsText() throws {
        let ctx = ModelContext(try container())
        let p = makeProspect(ctx)
        p.draftBody = "See my work at https://smugmug.com/dan."
        let blocked = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        let clean = Recipient(id: "p@perf.example", email: "p@perf.example", provenance: .performer)
        clean.overrideBody = "I photograph performing arts. Work at danwrightphotography.com/music."
        let alreadySent = Recipient(id: "b@present.example", email: "b@present.example", provenance: .presenter)
        alreadySent.sendState = .sent
        p.setRecipients([blocked, clean, alreadySent])
        try? ctx.save()
        let feedback = ActionFeedback()

        ProspectMutations.overrideDraftLint(QueueItem(p), prospects: [p], context: ctx, feedback: feedback)

        #expect(blocked.lintOverriddenBody == "See my work at https://smugmug.com/dan.")
        #expect(blocked.isSendablePending)
        #expect(clean.lintOverriddenBody == nil)
        #expect(alreadySent.lintOverriddenBody == nil)
    }

    // #367: the per-prospect re-prep action applies the requested mode and saves.
    // #1143: it now also LAUNCHES a scoped Prep run; an injected launch seam keeps this hermetic.
    @Test func reprepAppliesTheRequestedModeAndSaves() throws {
        let ctx = ModelContext(try container())
        let p = makeProspect(ctx, status: .drafted)
        p.draftBody = "Hi"
        try? ctx.save()
        let feedback = ActionFeedback()

        ProspectMutations.reprep(QueueItem(p), mode: .contactsOnly, prospects: [p], context: ctx, feedback: feedback,
                                 startPrep: { _, _, _ in })

        #expect(p.reprepContactsRequested == true)
        #expect(p.reprepDraftRequested == false)
        #expect(feedback.message != nil)
    }

    // #1143: clicking Re-prep must actually launch a Prep run scoped to JUST that prospect's key,
    // not merely flip the flag and wait for some future run.
    @Test func reprepLaunchesAScopedPrepRunForJustThatProspect() throws {
        let ctx = ModelContext(try container())
        let p = makeProspect(ctx, key: "only-me", status: .drafted)
        p.draftBody = "Hi"
        try? ctx.save()
        let feedback = ActionFeedback()

        var launchedKeys: [Set<String>] = []
        ProspectMutations.reprep(QueueItem(p), mode: .both, prospects: [p], context: ctx, feedback: feedback,
                                 startPrep: { _, _, keys in launchedKeys.append(keys) })

        #expect(launchedKeys == [["only-me"]])   // launched exactly once, scoped to this show
        #expect(p.reprepContactsRequested == true)
        #expect(feedback.message != nil)
    }

    // #1143 / CLAUDE.md "assume it runs twice": a second click (or a run already in flight) must not
    // launch a second run. The guard is startPrep's own in-flight marker, reused here: the first click
    // creates it, the second throws .alreadyRunning and no second launch happens.
    @Test func reprepDoesNotLaunchTwiceWhenARunIsAlreadyInFlight() throws {
        let ctx = ModelContext(try container())
        let p = makeProspect(ctx, key: "twice", status: .drafted)
        p.draftBody = "Hi"
        try? ctx.save()
        let feedback = ActionFeedback()

        let base = FileManager.default.temporaryDirectory.appendingPathComponent("reprep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let marker = base.appendingPathComponent("prep-running")
        let queue = base.appendingPathComponent("queue.json")

        var launches = 0
        // Route the seam through the REAL startPrep so the real marker guard is exercised, with every
        // file location pointed at the temp dir so nothing touches the live handoff directory.
        let seam: @MainActor (ModelContext, Date, Set<String>) throws -> Void = { ctx, now, keys in
            _ = try PrepQueueService.startPrep(from: ctx, now: now, includedKeys: keys,
                                               queueURL: queue, markerURL: marker,
                                               voiceFeedbackURL: base.appendingPathComponent("voice.json"),
                                               recentOpenersURL: base.appendingPathComponent("openers.json"),
                                               cancelURL: base.appendingPathComponent("prep-cancel"),
                                               launch: { launches += 1 })
        }

        ProspectMutations.reprep(QueueItem(p), mode: .both, prospects: [p], context: ctx, feedback: feedback, startPrep: seam)
        ProspectMutations.reprep(QueueItem(p), mode: .both, prospects: [p], context: ctx, feedback: feedback, startPrep: seam)

        #expect(launches == 1)                       // the in-flight marker blocked the second launch
        #expect(p.reprepContactsRequested == true)   // the flag is still recorded for the next run
        #expect(feedback.message != nil)             // and the "already running" case is surfaced, not silent
    }

    // #1143: a draft-only re-prep of a show already emailed has nothing to redraft (ReprepRequest gates
    // the draft half on sentAt == nil), so there is no dead work to launch. Fail-loud, not a phantom run.
    @Test func reprepDraftOnlyOnAnAlreadySentShowLaunchesNothing() throws {
        let ctx = ModelContext(try container())
        let p = makeProspect(ctx, key: "sent", status: .approved)
        p.draftBody = "Hi"
        p.sentAt = Date(timeIntervalSince1970: 10)
        try? ctx.save()
        let feedback = ActionFeedback()

        var launches = 0
        ProspectMutations.reprep(QueueItem(p), mode: .draftOnly, prospects: [p], context: ctx, feedback: feedback,
                                 startPrep: { _, _, _ in launches += 1 })

        #expect(launches == 0)                     // nothing to redraft, so no run
        #expect(p.reprepDraftRequested == false)   // and the draft half was never granted
        #expect(feedback.message != nil)           // Dan is told why, not left with a silent no-op
    }

    // #367: the bulk action only touches prospects that already have a draft and aren't in a
    // terminal state; a fresh queued-undrafted prospect is already covered by the normal flow and
    // must not get double-flagged, and a partially/fully sent one only ever gets the contacts half.
    @Test func bulkReprepOnlyTouchesEligibleAlreadyDraftedProspects() throws {
        let ctx = ModelContext(try container())
        let drafted = makeProspect(ctx, key: "drafted", status: .drafted)
        drafted.draftBody = "Hi"
        let approvedSent = makeProspect(ctx, key: "approved-sent", status: .approved)
        approvedSent.draftBody = "Hi"
        approvedSent.sentAt = Date(timeIntervalSince1970: 10)
        let freshQueued = makeProspect(ctx, key: "fresh", status: .queued)   // no draft yet
        let contacted = makeProspect(ctx, key: "contacted", status: .contacted)
        contacted.draftBody = "Hi"
        try? ctx.save()
        let feedback = ActionFeedback()

        ProspectMutations.bulkReprep(.both, prospects: [drafted, approvedSent, freshQueued, contacted],
                                     context: ctx, feedback: feedback)

        #expect(drafted.reprepDraftRequested == true)
        #expect(drafted.reprepContactsRequested == true)
        #expect(approvedSent.reprepDraftRequested == false)   // already sent: draft half refused
        #expect(approvedSent.reprepContactsRequested == true)
        #expect(freshQueued.reprepDraftRequested == false)    // not eligible for bulk re-prep
        #expect(freshQueued.reprepContactsRequested == false)
        #expect(contacted.reprepDraftRequested == false)      // terminal status: untouched
        #expect(contacted.reprepContactsRequested == false)
        #expect(feedback.message != nil)
    }

    // #733: guard against repeatedly re-prepping the same prospect. Bulk silently skips anything
    // already pending or served within the cooldown, rather than a per-prospect confirm dialog.
    @Test func bulkReprepSkipsAlreadyPendingAndInCooldownProspects() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 1_000_000)
        let ready = makeProspect(ctx, key: "ready", status: .drafted)
        ready.draftBody = "Hi"
        let alreadyPending = makeProspect(ctx, key: "pending", status: .drafted)
        alreadyPending.draftBody = "Hi"
        alreadyPending.reprepDraftRequested = true
        let inCooldown = makeProspect(ctx, key: "cooldown", status: .drafted)
        inCooldown.draftBody = "Hi"
        inCooldown.reprepLastServedAt = now.addingTimeInterval(-3600)   // 1h ago, well within 24h
        try? ctx.save()
        let feedback = ActionFeedback()

        ProspectMutations.bulkReprep(.both, prospects: [ready, alreadyPending, inCooldown],
                                     context: ctx, feedback: feedback, now: now)

        #expect(ready.reprepDraftRequested == true)
        #expect(ready.reprepContactsRequested == true)
        #expect(alreadyPending.reprepContactsRequested == false)   // untouched: already pending
        #expect(inCooldown.reprepDraftRequested == false)          // untouched: in cooldown
        #expect(inCooldown.reprepContactsRequested == false)
    }

    @Test func bulkReprepAllEligibleSkippedGivesADistinctMessage() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 1_000_000)
        let inCooldown = makeProspect(ctx, key: "cooldown", status: .drafted)
        inCooldown.draftBody = "Hi"
        inCooldown.reprepLastServedAt = now.addingTimeInterval(-3600)
        try? ctx.save()
        let feedback = ActionFeedback()

        ProspectMutations.bulkReprep(.both, prospects: [inCooldown], context: ctx, feedback: feedback, now: now)

        #expect(inCooldown.reprepDraftRequested == false)
        #expect(feedback.message != nil)
        #expect(feedback.message != ActionAck.bulkReprepNothingEligible)   // distinct from "nothing has a draft at all"
    }

    // #388: dismissing a specific contact's venue-match guess clears it for THAT recipient only.
    @Test func dismissVenueMatchClearsTheFlagForThatRecipient() throws {
        let ctx = ModelContext(try container())
        let p = makeProspect(ctx)
        let flagged = Recipient(id: "r1", email: "publicrelations@carnegiehall.example", provenance: .presenter)
        flagged.looksLikeVenue = true
        p.recipients = [flagged]
        try? ctx.save()
        let feedback = ActionFeedback()

        ProspectMutations.dismissVenueMatch(QueueItem(p), "r1", prospects: [p], context: ctx, feedback: feedback)

        #expect(p.recipients.first?.looksLikeVenueDismissed == true)
    }

    // #722: same shape as dismissVenueMatch above, for a suspected press/media contact.
    @Test func dismissPressContactMatchClearsTheFlagForThatRecipient() throws {
        let ctx = ModelContext(try container())
        let p = makeProspect(ctx)
        let flagged = Recipient(id: "r1", email: "press@venue.example", provenance: .presenter)
        flagged.looksLikePressContact = true
        p.recipients = [flagged]
        try? ctx.save()
        let feedback = ActionFeedback()

        ProspectMutations.dismissPressContactMatch(QueueItem(p), "r1", prospects: [p], context: ctx, feedback: feedback)

        #expect(p.recipients.first?.looksLikePressContactDismissed == true)
    }
}
