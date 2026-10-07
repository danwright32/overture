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

// #4531: the Follow-ups sheet's five lists in ONE order, whatever order the store hands rows over in.
//
// Every list here runs over an unsorted whole-store read and over each show's contacts, a relationship
// SwiftData hands back in whatever order it likes (L343). Each sorted by one field (a send instant, a
// request instant, a reply's arrival, a performance date) or by nothing at all, and where two rows tied
// they kept the order they arrived in, so the sheet could reorder between launches on unchanged data
// (L419). #4357 slice I3 made the queue's render pass total and left these, because the pass reads only
// their counts.
//
// WHAT THIS RUNS. One corpus, planted so every list holds a tie on what it sorts by, run through
// `DueWork.rows` over 20 seeded permutations of the shows, of each show's contacts and of the inquiries,
// and every list compared by identity (`TermsOverFacts.dueLines`) with the first permutation's. The seed
// is fixed, so a red run reproduces exactly (L339). One address sits on several shows, because a contact's
// `id` is its email and is shared across shows, so a tie broken by it alone is not broken at all; and one
// show holds two contacts on one address, which only the store's identifier tells apart.
//
// Every name and address is invented, on example.org or act.example (L155, L222). The clock is pinned
// (L130).
@MainActor
@Suite("The Follow-ups sheet's lists hold one order whatever order the store returns (#4531)")
struct DueWorkTotalOrderTests {
    private let container: ModelContainer
    private let context: ModelContext
    private let sent = Date(timeIntervalSince1970: 1_780_000_000)   // 2026-05-28
    private let day: TimeInterval = 86_400
    private var now: Date { sent.addingTimeInterval(10 * day) }
    private let seed: UInt64 = 4531
    private let permutationCount = 20

    init() throws {
        container = try TestModelContainer.inMemory([Prospect.self, Recipient.self, Inquiry.self])
        context = container.mainContext
    }

    private func prospect(_ key: String, on date: String) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: "Ensemble \(key)", discipline: "choral",
                         venue: "Quarry Hall", performanceDate: date, sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .contacted)
        context.insert(p)
        return p
    }

    // A show pitched at `sent`, each address on its own email.
    @discardableResult
    private func emailed(_ key: String, on date: String = "2027-07-01", _ emails: [String]) -> Prospect {
        let p = prospect(key, on: date)
        p.sentAt = sent
        p.setRecipients(emails.enumerated().map { index, email in
            let r = Recipient(id: email, email: email, provenance: .act)
            r.sendState = .sent
            r.sentAt = sent
            r.gmailThreadId = "t-\(key)-\(email)-\(index)"
            r.gmailMessageId = "<\(key)-\(email)-\(index)>"
            return r
        })
        return p
    }

    // A form pitch with a conversation Overture proposes as its reply, waiting on Dan to confirm it.
    @discardableResult
    private func proposed(_ key: String, form: String) -> Prospect {
        let p = prospect(key, on: "2027-07-01")
        let r = Recipient(id: "form:\(form)", email: nil, name: "Corin", provenance: .act)
        r.contactFormURL = form
        r.formOutreachURL = form
        r.outreachChannel = .contactForm
        r.formOutreachRecordedAt = now.addingTimeInterval(-3 * day)
        r.sentAt = now.addingTimeInterval(-3 * day)
        r.sendState = .sent
        p.setRecipients([r])
        ProposedConversation.propose(
            ProposedConversation.Candidate(messageId: "m-\(key)", threadId: "t-m-\(key)",
                                           fromAddress: "corin@example.org", fromName: "Corin",
                                           subject: "Re: the spring concert",
                                           sentAt: now.addingTimeInterval(-3_600), score: 9),
            on: r, now: now)
        return p
    }

    private func inquiry(_ name: String, event: String, repliedAt: Date) -> Inquiry {
        let i = Inquiry(source: .contactForm, inquirerName: name, inquirerEmail: "\(name)@example.org",
                        eventName: event)
        context.insert(i)
        i.replied = true
        i.repliedAt = repliedAt
        return i
    }

    // Every list's tie, planted. Keys are inserted out of natural key order so the planted order is not
    // already the sorted one.
    private func plantedCorpus() throws -> (shows: [Prospect], inquiries: [Inquiry]) {
        // Silent nudges: all sent at `sent`. One show with two separate emails ties within itself, and
        // the shared address sits on two shows.
        emailed("silent b", ["shared@act.example", "second@act.example"])
        emailed("silent a", ["shared@act.example"])
        // And one show holding TWO contacts on one address, which `SendGroup.oneRowPerGroup` collapses to
        // one row: which of the two it kept followed the order the relationship handed them over in.
        emailed("silent c", ["twice@act.example", "twice@act.example"])
        // After the show: two shows on one passed night, one prompt kind.
        emailed("after b", on: "2026-06-01", ["shared@act.example"])
        emailed("after a", on: "2026-06-01", ["other@act.example"])
        // Stalled reply drafts: asked for at one instant, never arrived.
        for key in ["stall b", "stall a"] {
            let r = emailed(key, ["stalled@act.example"]).recipients[0]
            r.replied = true
            r.repliedAt = now.addingTimeInterval(-2 * 3_600)
            r.lastReplyText = "Thanks for getting in touch."
            r.replyDraftRequestedAt = now.addingTimeInterval(-Recipient.replyDraftStallTimeout - 60)
            r.replyDraftBody = nil
        }
        // Replies to answer: two shows written back at one instant, and two inquiries about one event
        // written back at that same instant, so they share a natural key as well.
        for key in ["reply b", "reply a"] {
            emailed(key, ["replied@act.example"]).recipients[0].reopenOnReply(at: sent.addingTimeInterval(day))
        }
        let inquiries = [inquiry("marta", event: "Winter recital", repliedAt: sent.addingTimeInterval(day)),
                         inquiry("lena", event: "Winter recital", repliedAt: sent.addingTimeInterval(day))]
        // Conversations to confirm: a list that had no order at all.
        proposed("confirm b", form: "https://quarry.example/contact")
        proposed("confirm a", form: "https://quarry.example/contact")
        // Saved, so every identifier the order falls back to is a permanent one.
        try context.save()
        return (try context.fetch(FetchDescriptor<Prospect>()), inquiries)
    }

    private func lines(_ shows: [Prospect], contacts: [PersistentIdentifier: [Recipient]],
                       inquiries: [Inquiry]) -> [String: [String]] {
        TermsOverFacts.dueLines(DueWork.rows(from: shows, contacts: { contacts[$0.persistentModelID] ?? [] },
                                             inquiries: inquiries, now: now, replyRunAlive: false))
    }

    // The positive control: every list holds the tie this exists to break, so a green below is about
    // ties rather than about lists too short to have any (L159).
    @Test func everyListHoldsATieOnWhatItSortsBy() throws {
        let corpus = try plantedCorpus()
        let rows = DueWork.rows(from: corpus.shows, contacts: { $0.recipients }, inquiries: corpus.inquiries,
                                now: now, replyRunAlive: false)

        #expect(rows.silent.filter { $0.recipient.sentAt == sent }.count >= 3)
        #expect(rows.silent.filter { $0.prospect.naturalKey == "silent c" }.count == 1,
                "the show with two contacts on one address no longer collapses them to one row")
        #expect(Set(rows.afterTheShow.map { "\($0.prompt.kind) \($0.prospect.performanceDate ?? "")" }).count
                < rows.afterTheShow.count, "no two after the show rows tie")
        #expect(rows.stalledReplyDrafts.count >= 2)
        #expect(Set(rows.stalledReplyDrafts.map(\.requestedAt)).count == 1)
        #expect(rows.repliesToAnswer.count >= 4)
        #expect(Set(rows.repliesToAnswer.compactMap(\.arrivedAt)).count == 1)
        #expect(rows.conversationsToConfirm.count >= 2)
    }

    @Test func everyListIsInOneOrderWhateverOrderTheShowsAndTheirContactsArriveIn() throws {
        let corpus = try plantedCorpus()
        var generator = SeededGenerator(seed: seed)
        var answers: [[String: [String]]] = []
        var showOrders = Set<[String]>()
        for _ in 0..<permutationCount {
            let shows = corpus.shows.shuffled(using: &generator)
            var contacts: [PersistentIdentifier: [Recipient]] = [:]
            for show in shows {
                contacts[show.persistentModelID] = show.recipients.shuffled(using: &generator)
            }
            showOrders.insert(shows.map(\.naturalKey))
            answers.append(lines(shows, contacts: contacts, inquiries: corpus.inquiries.shuffled(using: &generator)))
        }

        try #require(showOrders.count > 1, "the shuffle never changed the order the shows arrive in")
        let first = try #require(answers.first)
        for list in first.keys.sorted() {
            let orders = Set(answers.map { $0[list] ?? [] })
            #expect(orders.count == 1,
                    "\(list) came back in \(orders.count) orders over \(permutationCount) permutations of seed \(seed)")
        }
    }
}
