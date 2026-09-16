import Testing
import Foundation
import SwiftData

// #885: "what is due" was defined twice, in two views.
//
// RootView's toolbar badge summed FollowUp.dueRecipients and ConversationReminder.dueRecipients in its
// own body; FollowUpsView's header count summed the same two, separately, in its own. The two agreed
// only because they happened to read the same stored settings, and nothing anywhere asserted that they
// did. That is the #863 shape exactly: a rule stated in two view bodies is a rule no test can reach, and
// the number Dan navigates by (the pill he clicks) and the number he lands on (the sheet's header) could
// drift apart with nothing to catch it.
//
// One definition, beside the data, testable.
@MainActor
@Suite("Due work (#885)")
struct DueWorkTests {
    private func makeContext() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private let sent = Date(timeIntervalSince1970: 1_780_000_000)
    private let day: TimeInterval = 86_400

    // A lead emailed, never answered, and past its gap: the silent nudge is due.
    private func silentLead(_ context: ModelContext) -> Prospect {
        let p = Prospect(naturalKey: "k", groupName: "G", discipline: "choral", venue: "V",
                         performanceDate: "2027-07-01", sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .contacted)
        p.sentAt = sent
        context.insert(p)
        let silent = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        silent.sendState = .sent
        silent.sentAt = sent
        p.setRecipients([silent])
        return p
    }

    @Test func dueCountsTheSilentFollowUpsAndTheConversationRemindersTogether() throws {
        let context = try makeContext()
        _ = silentLead(context)
        let prospects = try context.fetch(FetchDescriptor<Prospect>())

        let counts = DueWork.counts(prospects: prospects, inquiries: [], now: sent.addingTimeInterval(10 * day), replyRunAlive: false)

        #expect(counts.followUps == 1)
        #expect(counts.afterTheShow == 0)
        #expect(counts.total == 1)
    }

    // The rule, in one place: the badge and the sheet header are the SAME number by construction, not by
    // two view bodies happening to agree.
    @Test func theTotalIsTheSumOfBothKinds() {
        let counts = DueWork.Counts(followUps: 3, afterTheShow: 2)

        #expect(counts.total == 5)
    }

    // A lead nobody has emailed yet is not due for a follow-up to an email that never went.
    @Test func nothingSentMeansNothingDue() throws {
        let context = try makeContext()
        let p = silentLead(context)
        p.sentAt = nil
        for r in p.recipients {
            r.sendState = .pending
            r.sentAt = nil
        }
        let prospects = try context.fetch(FetchDescriptor<Prospect>())

        let counts = DueWork.counts(prospects: prospects, inquiries: [], now: sent.addingTimeInterval(10 * day), replyRunAlive: false)

        #expect(counts.total == 0)
    }
}

// #885: the nudge counter, and the two sentences that promise what a Send will actually do.
@MainActor
@Suite("Follow-up copy (#885)")
struct FollowUpCopyTests {

    // THE bug this tranche exists for. `followUpCount` is a 0-based stored count, and the label Dan reads
    // ("nudge 2 of 2") and the email body a stranger reads (`attempt:`) each applied their own `+ 1`, in
    // two different files, with nothing asserting they agreed. If they drift, the row says one thing and
    // the email says another, and the person who finds out is the recipient.
    @Test func theAttemptNumberIsDerivedOnceAndTheLabelAndTheEmailShareIt() {
        #expect(FollowUp.attempt(after: 0) == 1)
        #expect(FollowUp.attempt(after: 1) == 2)
    }

    @Test func theNudgeLabelNamesTheContactAndWhichAttemptThisIs() {
        let label = FollowUp.nudgeLabel(email: "them@example.com", followUpCount: 0,
                                        config: FollowUpConfig(gapDays: 6, maxFollowUps: 2))

        #expect(label == "them@example.com · nudge 1 of 2")
    }

    // A contact with no email is a real state (Prep found nobody), and the row still has to render.
    @Test func aContactWithNoEmailStillReads() {
        let label = FollowUp.nudgeLabel(email: nil, followUpCount: 1,
                                        config: FollowUpConfig(gapDays: 6, maxFollowUps: 2))

        #expect(label == "no contact · nudge 2 of 2")
    }

    // #948: the exact subject and body a follow-up nudge sends, in one shared place read by both the
    // sender and the confirmation sheet. The subject must be the REPLY subject (what threads and what
    // actually goes out), not the standalone nudge subject the old confirm preview showed.
    @Test func theFollowUpNudgeContentUsesTheReplySubjectThatActuallySends() {
        let content = FollowUp.nudgeContent(originalSubject: "Photographs for the Quartet",
                                            groupName: "The Quartet", contactName: "Marcus",
                                            venue: "Weill Recital Hall", followUpCount: 0)

        #expect(content.subject == "Re: Photographs for the Quartet")
        #expect(content.subject
                == FollowUp.replySubject(originalSubject: "Photographs for the Quartet", groupName: "The Quartet"))
        #expect(content.body
                == FollowUp.nudgeBody(contactName: "Marcus", groupName: "The Quartet",
                                      venue: "Weill Recital Hall", attempt: 1))
    }

    // #2710: a test stood here on `nudgeContent`, which composed the closing note's subject and body
    // and answered nil for the close-out prompt. Both the function and the email are gone: after the show
    // there is nothing to compose, so there is no content to be marked closing or refused.
}

// #3890: a reply waiting on Dan's answer is due work.
//
// #2115 specified the Dock and menu bar count as "follow-ups due plus conversations owing a response",
// and #2397 took the conversation half out of `DueWork.Counts.total` without replacing it, so from
// 2026-08-10 no reply ever put a number on either surface. On 2026-09-14 three people were waiting on an
// answer and the published count read 0. Dan's call, 2026-09-15: replies JOIN the Due list, so the badge
// number is still one derivation with a row behind every unit of it (L16).
@MainActor
@Suite("Replies waiting on an answer are due work (#3890)")
struct RepliesWaitingAreDueWorkTests {
    private func makeContext() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self, Inquiry.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private let sent = Date(timeIntervalSince1970: 1_780_000_000)   // 2026-05-28
    private let day: TimeInterval = 86_400

    private func show(_ context: ModelContext, key: String = "k", date: String = "2027-07-01",
                      contacts: [String]) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: "G", discipline: "choral", venue: "V",
                         performanceDate: date, sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .contacted)
        p.sentAt = sent
        context.insert(p)
        p.setRecipients(contacts.map { email in
            let r = Recipient(id: email, email: email, provenance: .act)
            r.sendState = .sent
            r.sentAt = sent
            r.gmailThreadId = "t-\(email)"
            r.gmailMessageId = "<\(email)>"
            return r
        })
        return p
    }

    private func rows(_ context: ModelContext, now: Date) throws -> DueWork.Rows {
        DueWork.rows(prospects: try context.fetch(FetchDescriptor<Prospect>()),
                     inquiries: try context.fetch(FetchDescriptor<Inquiry>()),
                     now: now, replyRunAlive: false)
    }

    @Test func aReplyNobodyHasAnsweredIsCountedAndListed() throws {
        let context = try makeContext()
        let p = show(context, contacts: ["a@act.example"])
        p.recipients[0].reopenOnReply(at: sent.addingTimeInterval(day))

        let rows = try rows(context, now: sent.addingTimeInterval(2 * day))
        #expect(rows.repliesToAnswer.count == 1)
        #expect(rows.counts.repliesToAnswer == 1)
        #expect(rows.counts.total == 1)
        #expect(rows.rendered == rows.counts.total)
    }

    // Reply detection marks every contact on a shared thread as replied, so a joint email one person
    // answered is one conversation to answer, never one per contact on it.
    @Test func oneReplyOnAJointEmailIsOneThingToAnswer() throws {
        let context = try makeContext()
        let p = show(context, contacts: ["a@act.example", "b@act.example"])
        for r in p.recipients {
            r.sendGroupId = "g1"
            r.reopenOnReply(at: sent.addingTimeInterval(day))
        }

        #expect(try rows(context, now: sent.addingTimeInterval(2 * day)).counts.repliesToAnswer == 1)
    }

    // Answered, it stops asking. Written to again afterwards, it asks again: the second half of every
    // conversation has to reach the badge as well as the first.
    @Test func anAnsweredReplyLeavesAndASecondReplyReturns() throws {
        let context = try makeContext()
        let p = show(context, contacts: ["a@act.example"])
        let r = p.recipients[0]
        r.reopenOnReply(at: sent.addingTimeInterval(day))
        r.recordAnswerSent(now: sent.addingTimeInterval(2 * day))
        #expect(try rows(context, now: sent.addingTimeInterval(3 * day)).counts.repliesToAnswer == 0)

        r.reopenOnReply(at: sent.addingTimeInterval(4 * day))
        #expect(try rows(context, now: sent.addingTimeInterval(5 * day)).counts.repliesToAnswer == 1)
    }

    @Test func aHireInquiryWaitingOnAnAnswerIsCounted() throws {
        let context = try makeContext()
        let i = Inquiry(source: .contactForm, inquirerName: "Marta Reyes",
                        inquirerEmail: "marta@example.org", eventName: "Winter recital")
        context.insert(i)
        i.replied = true
        i.repliedAt = sent

        let rows = try rows(context, now: sent.addingTimeInterval(day))
        #expect(rows.counts.repliesToAnswer == 1)
        #expect(rows.rendered == rows.counts.total)
    }

    // Dan's call, 2026-09-15: a passed show whose reply is unanswered is ONE thing, the answer. How the
    // show ended is asked once he has answered, never as a second row over the same person.
    @Test func aPassedShowWithAnUnansweredReplyIsCountedOnceAsTheReply() throws {
        let context = try makeContext()
        let p = show(context, date: "2026-06-01", contacts: ["a@act.example"])
        let r = p.recipients[0]
        r.reopenOnReply(at: sent.addingTimeInterval(day))
        let afterTheShow = sent.addingTimeInterval(10 * day)

        let owed = try rows(context, now: afterTheShow)
        #expect(owed.counts.repliesToAnswer == 1)
        #expect(owed.counts.afterTheShow == 0)
        #expect(owed.counts.total == 1)

        r.recordAnswerSent(now: afterTheShow)
        let answered = try rows(context, now: afterTheShow.addingTimeInterval(60))
        #expect(answered.counts.repliesToAnswer == 0)
        #expect(answered.counts.afterTheShow == 1)
    }

    // A reply whose requested draft died is already listed, as the stalled draft with its own remedy, so
    // it is not listed a second time as a reply.
    @Test func aReplyWhoseDraftStalledIsListedOnceAsTheStalledDraft() throws {
        let context = try makeContext()
        let p = show(context, contacts: ["a@act.example"])
        let r = p.recipients[0]
        r.reopenOnReply(at: sent.addingTimeInterval(day))
        r.replyDraftRequestedAt = sent.addingTimeInterval(day)

        let rows = try rows(context, now: sent.addingTimeInterval(5 * day))
        #expect(rows.counts.stalledReplyDrafts == 1)
        #expect(rows.counts.repliesToAnswer == 0)
        #expect(rows.counts.total == 1)
    }

    // A booked show's conversation has succeeded, which is the rollup `Prospect.hasUnhandledReply` has
    // always excluded.
    @Test func aBookedShowsReplyIsNotDue() throws {
        let context = try makeContext()
        let p = show(context, contacts: ["a@act.example"])
        p.recipients[0].reopenOnReply(at: sent.addingTimeInterval(day))
        // The same fixture counts before the booking, so the zero below is the booking's doing (L159).
        #expect(try rows(context, now: sent.addingTimeInterval(2 * day)).counts.repliesToAnswer == 1)
        p.outcome = .booked

        #expect(try rows(context, now: sent.addingTimeInterval(2 * day)).counts.repliesToAnswer == 0)
    }
}
