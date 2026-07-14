import Testing
import Foundation
import SwiftData
@testable import Overture

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
                         performanceDate: "2027-07-01", sourceListingURL: nil, websiteURL: nil,
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

        let counts = DueWork.counts(prospects: prospects, now: sent.addingTimeInterval(10 * day),
                                    reminder: ConversationReminderConfig())

        #expect(counts.followUps == 1)
        #expect(counts.conversations == 0)
        #expect(counts.total == 1)
    }

    // The rule, in one place: the badge and the sheet header are the SAME number by construction, not by
    // two view bodies happening to agree.
    @Test func theTotalIsTheSumOfBothKinds() {
        let counts = DueWork.Counts(followUps: 3, conversations: 2)

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

        let counts = DueWork.counts(prospects: prospects, now: sent.addingTimeInterval(10 * day),
                                    reminder: ConversationReminderConfig())

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

    // The confirmation Dan reads before a send. It is a PROMISE about what the app will do, and it was
    // assembled inline in an alert closure where no test could read it.
    @Test func theFollowUpConfirmationPromisesExactlyOneEmailToOneContact() {
        let message = FollowUp.confirmMessage(recipient: "them@example.com", preview: "Subject: x\n\nBody")

        #expect(message.contains("To: them@example.com"))
        #expect(message.contains("Subject: x"))
        #expect(message.contains("This sends one follow-up right now, to this recipient only. Nothing else goes out."))
    }

    // The closing note does a SECOND thing (it also closes the lead out), and the sentence saying so was
    // appended by a ternary in a view. A confirmation that omits a consequence is the one that matters.
    @Test func aClosingNoteSaysItAlsoClosesTheLeadOut() {
        let closing = ConversationReminder.confirmMessage(recipient: "them@example.com",
                                                          preview: "Body", isClosing: true)
        let plain = ConversationReminder.confirmMessage(recipient: "them@example.com",
                                                        preview: "Body", isClosing: false)

        #expect(closing.contains("It also closes the lead out (kept warm for next time)."))
        #expect(plain.contains("This sends one message right now, to this recipient only."))
        #expect(!plain.contains("closes the lead out"))
    }
}
