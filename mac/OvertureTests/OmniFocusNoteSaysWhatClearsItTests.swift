import Testing
import Foundation
import SwiftData

// #2901 / #2952: what the OmniFocus note has to say beyond naming the show.
//
// #2901: the note named the lead, the contact, the due day, the venue, the performance date and a deep
// link, and said nothing about what actually retires the task. Ticking it off in OmniFocus does not
// (#2899), and the obvious thing to reach for instead, closing the show out, does not either (#2900). On
// 2026-08-17 that cost a session's diagnosis: the only route to the answer was reading
// `Recipient.hasUnhandledReply` and working backwards to its writers.
//
// #2952: and once a reply is answered, the triage task completes and what remains is a follow-up whose
// note said nothing about the conversation that already happened. OmniFocus is the one surface Dan reads
// away from the Mac, so that is where missing context costs most.
@MainActor
@Suite("What the OmniFocus note says beyond the show (#2901, #2952)")
struct OmniFocusNoteSaysWhatClearsItTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: AppSchema.schema,
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    // The performance date is derived from `now`, never a literal: a fixture whose meaning is the
    // RELATIONSHIP between a stored date and the clock has to pin both ends, or real time walks it into a
    // different case and the test goes on asserting about a state nobody chose (L130).
    private func showWithReply(handled: Date?, showDaysAgo: Int, in ctx: ModelContext,
                               now: Date) -> Prospect {
        let showDay = EasternDate.dayString(from: now.addingTimeInterval(TimeInterval(-showDaysAgo) * 86_400))
        let p = Prospect(naturalKey: "aurora|\(showDay)|carnegie", groupName: "Aurora Strings",
                         discipline: "music", venue: "Carnegie Hall", performanceDate: showDay,
                         sourceListingURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 9, tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil)
        let r = Recipient(id: "hello@aurorastrings.test", email: "hello@aurorastrings.test",
                          name: "Ada Whitfield", role: "Manager", provenance: .act)
        r.sentAt = now.addingTimeInterval(-20 * 86_400)
        r.gmailMessageId = "gmail-1"   // hasProvenOutreach, which the post-event prompt requires
        r.sendState = .sent
        r.replied = true
        r.repliedAt = now.addingTimeInterval(-5 * 86_400)
        r.inboundReplySentAt = now.addingTimeInterval(-5 * 86_400)
        r.replyHandledAt = handled
        p.addRecipient(r)
        ctx.insert(p)
        return p
    }

    // Every kind answers the question, so a task of any kind carries it. Enumerated over the kinds
    // themselves rather than the two this suite happens to build, so a third kind added later is judged
    // here rather than shipping with nothing to say.
    @Test func everyKindOfTaskSaysWhatClearsIt() {
        for kind in [OmniFocusSync.DesiredTask.Kind.replyTriage, .postEventPrompt] {
            #expect(kind.whatClearsIt.contains("Clears when:"),
                    Comment(rawValue: "\(kind.rawValue) does not say what retires it"))
            // And what ticking it off in OmniFocus does, which differs by kind and is the half the first
            // draft of this got wrong in the confident direction.
            #expect(kind.whatClearsIt.contains("Ticking this off here"),
                    Comment(rawValue: "\(kind.rawValue) says nothing about ticking it off in OmniFocus"))
        }
    }

    // The two kinds are cleared by DIFFERENT acts, so one sentence for both would be wrong for one.
    @Test func thetwoKindsNameDifferentActs() {
        let triage = OmniFocusSync.DesiredTask.Kind.replyTriage.whatClearsIt
        let prompt = OmniFocusSync.DesiredTask.Kind.postEventPrompt.whatClearsIt
        #expect(triage != prompt)
        #expect(triage.contains("answer them"))
        #expect(prompt.contains("how the show ended"))
    }

    // The sentence and the behaviour, checked against each other rather than both written by hand. A
    // completed reply-triage task IS read back and stamps the reply answered (#2899); a completed
    // post-event prompt writes nothing, because only Dan holds the ending. The note says so per kind, and
    // this is what stops it saying the opposite after somebody changes the carry-back.
    @Test func theNoteAgreesWithWhatACompletionActuallyWrites() throws {
        let now = Date()
        for kind in [OmniFocusSync.DesiredTask.Kind.replyTriage, .postEventPrompt] {
            let ctx = ModelContext(try container())
            let p = showWithReply(handled: nil, showDaysAgo: kind == .replyTriage ? -20 : 2,
                                  in: ctx, now: now)
            let r = try #require(p.recipients.first)
            let task = OmniFocusSync.DesiredTask(kind: kind, naturalKey: p.naturalKey, recipientId: r.id,
                                                 title: "t", note: "n", deferDate: now, dueDate: now)

            let stamped = OmniFocusSync.recordCompletions([task], in: [p], now: now)
            #expect((stamped > 0) == kind.completionIsCarriedBack,
                    Comment(rawValue: "\(kind.rawValue) says its completion is carried back "
                            + "\(kind.completionIsCarriedBack), and it wrote \(stamped)"))

            let saysItCounts = kind.whatClearsIt.contains("counts too")
            #expect(saysItCounts == kind.completionIsCarriedBack,
                    Comment(rawValue: "the note for \(kind.rawValue) disagrees with what a completion writes"))
        }
    }

    // A reply nobody has answered: a triage task, and no claim that a conversation happened.
    @Test func anUnansweredReplyGetsTheTriageSentenceAndNoConversationLine() throws {
        let now = Date()
        let ctx = ModelContext(try container())
        // A show still ahead, so the only task it can earn is the triage one.
        let p = showWithReply(handled: nil, showDaysAgo: -20, in: ctx, now: now)

        let tasks = OmniFocusSync.desired(from: [p], now: now, horizonDays: 30)
        let task = try #require(tasks.first)
        #expect(task.kind == .replyTriage)
        #expect(task.note.contains("Clears when: you answer them in Overture"))
        #expect(!task.note.contains("already been in touch"),
                "nobody has answered them, so the note must not say a conversation happened")
    }

    // #2952: once it is answered, the follow-up says so.
    @Test func anAnsweredReplySaysAConversationAlreadyHappened() throws {
        let now = Date()
        let ctx = ModelContext(try container())
        // The show has PASSED and the reply is answered, which is exactly the state #2952 is about: the
        // triage task has completed and what remains is the follow-up.
        let p = showWithReply(handled: now.addingTimeInterval(-4 * 86_400), showDaysAgo: 2,
                              in: ctx, now: now)
        let r = try #require(p.recipients.first)
        #expect(r.replyIsAnswered, "the fixture must be in the state this test is about")

        let task = try #require(OmniFocusSync.desired(from: [p], now: now, horizonDays: 30).first)
        #expect(task.kind == .postEventPrompt)
        #expect(task.note.contains("already been in touch with them about this and answered their reply"))
        #expect(task.note.contains("Clears when: you record how the show ended in Overture"))
    }

    // The three machine-read paragraphs stay first and stay adjacent: the client matches a task to its
    // contact by reading them back verbatim, so anything inserted above or between them breaks the sync.
    @Test func theMachineReadParagraphsStayAtTheTop() throws {
        let now = Date()
        let ctx = ModelContext(try container())
        let p = showWithReply(handled: nil, showDaysAgo: -20, in: ctx, now: now)

        let note = try #require(OmniFocusSync.desired(from: [p], now: now, horizonDays: 30).first?.note)
        let lines = note.components(separatedBy: "\n")
        #expect(lines.count > 3)
        #expect(lines[0].contains(p.naturalKey))
        #expect(lines[1].contains(try #require(p.recipients.first).id))
        #expect(lines[2].contains("Due"))
    }
}
