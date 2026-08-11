import Testing
import Foundation
import SwiftData

// #2050. Dan, on being shown that approving moved his draft to a second screen with its own Send button:
// "I think as soon as I click approve I should get a confirmation that I want to send it and go straight
// through that action. There's no real reason to approve it again on another screen."
//
// So approving stops being a state Dan parks a show in and becomes the first half of one action: press
// the button, read the confirmation sheet that names exactly who it reaches and what it says, and send.
// The approved-but-unsent state still exists, because a send can fail, but nothing Dan does on purpose
// leaves a show sitting in it.
//
// The failure path is the half worth guarding hardest: a send that throws must leave the show APPROVED
// (so it can be retried) and still somewhere Dan can find it, which is what #2050 was filed about.
private final class RecordingSender: MailSender, @unchecked Sendable {
    private(set) var sent: [OutgoingMail] = []
    var error: Error?
    func send(_ mail: OutgoingMail) async throws -> SentReceipt {
        if let error { throw error }
        sent.append(mail)
        return SentReceipt(threadId: "t-recorded", messageID: "<recorded@x.org>")
    }
}

@MainActor
@Suite("Approving and sending are one action (#2050)")
struct ApproveAndSendIsOneActionTests {
    private let today = ScoutTestClock.stageNavigationAnchor
    private let now = Date(timeIntervalSince1970: 1_768_000_000)

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func draftedShow(_ ctx: ModelContext, contacts: Int = 1,
                             together: Bool = false, subject: String? = "Photographing your concert") -> Prospect {
        let p = Prospect(naturalKey: "k", groupName: "Aurora Strings", discipline: "music",
                         venue: "Weill Recital Hall", performanceDate: "2026-09-19", sourceListingURL: nil,
                         websiteURL: nil, priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .drafted)
        p.draftSubject = subject
        p.draftBody = "I photograph performances and would love to cover this."
        p.sendsTogetherOverride = together
        ctx.insert(p)
        for i in 0..<contacts {
            let r = Recipient(id: "c\(i)", email: "c\(i)@org.example", name: "Person \(i)",
                              role: "Manager", provenance: .act)
            r.prospect = p
            p.recipients.append(r)
            ctx.insert(r)
        }
        try? ctx.save()
        return p
    }

    private func item(_ p: Prospect) -> QueueItem {
        QueueModel.items(from: [p], now: now).first { $0.id == p.naturalKey }!
    }

    private func stage(_ ctx: ModelContext) throws -> StageFocus? {
        let all = try ctx.fetch(FetchDescriptor<Prospect>())
        let reachedOutKeys = Set(ReachedOutQueue.activeWithDates(from: all, now: now)
            .map(\.prospect.naturalKey))
        return StageNavigation.stage(containing: "k", in: all, reachedOutKeys: reachedOutKeys,
                                     context: .at(today, now: now))
    }

    // MARK: - The confirmation Dan reads before anything is committed

    // #2015's guard stays exactly as it was for every caller that has not said it is approving: a card or
    // a screen may not name the people an unapproved draft would reach. Opening the final-review sheet is
    // the one caller that legitimately asks the question before approval, and it has to say so out loud.
    @Test func anUnapprovedDraftStillRefusesToNameItsRecipientsUnlessTheCallerIsApproving() throws {
        let ctx = try context()
        let p = draftedShow(ctx)

        #expect(SendConfirmation(prospect: p, signature: .none) == nil)
        #expect(SendConfirmation(prospect: p, approving: true, signature: .none) != nil)
    }

    // L64: what Dan reads on that sheet must be exactly what ships, including WHO it goes to. The sheet is
    // now built one step earlier than the send, so this asserts the two still name the same people: the
    // group the sheet lists is the group the send reaches once the show is approved.
    @Test func theSheetNamesExactlyWhoTheSendWillReach() throws {
        let ctx = try context()
        let p = draftedShow(ctx, contacts: 2, together: true)

        let sheet = SendConfirmation(prospect: p, approving: true, signature: .none)
        p.status = .approved
        let actuallyReached = SendGroup.pendingGroup(of: p).compactMap(\.email).joined(separator: ", ")

        #expect(sheet?.recipient == actuallyReached)
        #expect(sheet?.recipient.contains("c0@org.example") == true)
        #expect(sheet?.recipient.contains("c1@org.example") == true)
    }

    // A draft that cannot send has no sheet to open, whatever the caller claims. #2052's missing subject
    // is the live example: the placeholder was the detection, so it must stop the action (L67).
    @Test func aDraftThatCannotSendHasNoSheetEvenWhenApproving() throws {
        let ctx = try context()
        let p = draftedShow(ctx, subject: nil)
        #expect(SendConfirmation(prospect: p, approving: true, signature: .none) == nil)
    }

    // MARK: - Confirming it

    @Test func confirmingADraftedShowApprovesAndSendsItInOneStep() async throws {
        let ctx = try context()
        let p = draftedShow(ctx)
        let sender = RecordingSender()
        let feedback = ActionFeedback()
        var cleared: [String] = []

        ProspectMutations.approveAndSend(item(p), prospects: [p], context: ctx, feedback: feedback,
                                         sender: sender, markSending: { _ in },
                                         clearSending: { cleared.append($0) }, onNeedsReconnect: {})

        // Approving is synchronous, so the show is committed before the network work even starts.
        #expect(p.status == .approved)
        while cleared.isEmpty { await Task.yield() }
        #expect(sender.sent.count == 1)
        #expect(p.status == .contacted)
        #expect(p.sentAt != nil)
    }

    // An already-approved show (one whose send failed, or Dan's stranded one from before this change)
    // takes the same path and is not approved twice.
    @Test func anAlreadyApprovedShowSendsWithoutBeingReApproved() async throws {
        let ctx = try context()
        let p = draftedShow(ctx)
        p.status = .approved
        let sender = RecordingSender()
        var cleared: [String] = []

        ProspectMutations.approveAndSend(item(p), prospects: [p], context: ctx, feedback: ActionFeedback(),
                                         sender: sender, markSending: { _ in },
                                         clearSending: { cleared.append($0) }, onNeedsReconnect: {})

        while cleared.isEmpty { await Task.yield() }
        #expect(sender.sent.count == 1)
        #expect(p.status == .contacted)
    }

    // MARK: - The failure path

    // The send throws. The show must keep the approval (so the retry has something to retry), record the
    // error, and above all still be somewhere Dan can reach: leaving it approved and unsent in a stage no
    // pill points at is exactly the disappearance #2050 was filed about.
    @Test func aFailedSendLeavesTheShowApprovedRecordedAndStillReachable() async throws {
        let ctx = try context()
        let p = draftedShow(ctx)
        let sender = RecordingSender()
        sender.error = NSError(domain: "gmail", code: 500,
                               userInfo: [NSLocalizedDescriptionKey: "Gmail refused it"])
        var cleared: [String] = []

        ProspectMutations.approveAndSend(item(p), prospects: [p], context: ctx, feedback: ActionFeedback(),
                                         sender: sender, markSending: { _ in },
                                         clearSending: { cleared.append($0) }, onNeedsReconnect: {})

        while cleared.isEmpty { await Task.yield() }
        #expect(sender.sent.isEmpty)
        #expect(p.status == .approved)
        #expect(p.sentAt == nil)
        #expect(p.sendError != nil)
        #expect(try stage(ctx) == .review)
    }

    // MARK: - #2012: a disabled button always says why

    // With one button, everything that holds a send holds it BEFORE approval, so every explanation has to
    // speak on an unapproved draft. Dan met the opposite: a lint-blocked draft showed a greyed Approve and
    // no reason at all, because the sentences were gated on the state pressing it would have produced.
    @Test func theReasonADraftCannotSendIsSaidBeforeApproving() {
        #expect(DraftReviewNotes.noSubject(subject: nil) != nil)
        #expect(DraftReviewNotes.noSubject(subject: "   ") != nil)
        #expect(DraftReviewNotes.noSubject(subject: "A real subject") == nil)

        #expect(DraftReviewNotes.noSendableEmail(hasPendingRecipient: false, hasAnyEmailContact: false) != nil)
        #expect(DraftReviewNotes.noSendableEmail(hasPendingRecipient: true, hasAnyEmailContact: true) == nil)
    }

    // #843: the same finding must not appear twice on one screen. The gate by the button names the lint
    // blocker, and it is now shown whether or not the show is approved, so the flags near the body step
    // aside on the same rule rather than only after an approval that no longer happens separately.
    @Test func aBlockingLintFindingIsShownOnceNotTwice() {
        #expect(DraftReviewNotes.showsBlockingFlagsNearBody(lintBlocked: true) == false)
        #expect(DraftReviewNotes.showsBlockingFlagsNearBody(lintBlocked: false) == true)
    }
}
