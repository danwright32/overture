import Testing
import Foundation
import SwiftData

// #2967, #2968, #3076: one number, stated by five surfaces, which had drifted apart from each other.
//
// Measured 2026-08-21, the five were:
//   the Follow-ups pill        `AgentInputs.followUpsDue`, silent nudges ONLY
//   the sheet's header         `DueWork.Counts.total`, silent plus after the show plus conversations
//   the toolbar Due badge      `RootView.followUpsDue`, the same total, over a different prospect set
//   the Dock tile and menu bar `ReconcileScheduler` to `DueBadge` to `MenuBarLabel`
//   the rows the sheet DRAWS   silent plus after the show plus stalled reply drafts
//
// So the pill could read "None due" over a sheet with rows in it (#2968), and the badge could read
// "Due 2" over one row (#2967), and both were found in the same sweep by two different routes: one
// number included something the sheet had no section for, the other excluded something it did render.
// A third route was likely rather than hypothetical, which is why this suite asserts the RULE and not
// the two repaired instances (#3076, L30).
//
// Dan's call, 2026-08-22: one number, and the sheet grows a section, so the number is always a promise
// about rows he can act on where he lands (#863).
//
// The fixture holds one of every kind of due work AT ONCE, which is the whole point: each kind on its
// own leaves the others at zero, and an assertion that two zeroes agree is satisfied by a fixture in
// which they could not disagree (L159).
@MainActor
@Suite("Every surface stating the Due count agrees with the rows behind it (#3076)")
struct OneDueNumberTests {
    // A fixed instant, with every date derived from it, so real time cannot walk this fixture into a
    // different case than the one it was written for (L130, #2669).
    private let now = Date(timeIntervalSince1970: 1_780_000_000)
    private var today: String { EasternDate.today(now) }
    private func day(_ offset: TimeInterval) -> String { EasternDate.today(now.addingTimeInterval(offset)) }

    private func makeContext() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private func show(_ key: String, _ name: String, on date: String,
                      status: ReviewStatus = .contacted) -> Prospect {
        Prospect(naturalKey: key, groupName: name, discipline: "music", venue: "The Example Room",
                 performanceDate: date, sourceListingURL: nil,
                 priorRelationship: "none", production: "self", profile: "strong",
                 coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                 matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                 status: status)
    }

    // An emailed pitch nobody answered, old enough that a nudge is owed, on a show still ahead.
    @discardableResult
    private func silentFollowUp(_ context: ModelContext, key: String = "silent") -> Prospect {
        let p = show(key, "Boreal Quartet", on: day(30 * 86_400))
        p.sentAt = now.addingTimeInterval(-30 * 86_400)
        context.insert(p)
        let r = Recipient(id: "\(key)@example.com", email: "\(key)@example.com", name: "Nessa",
                          provenance: .act)
        r.sendState = .sent
        r.sentAt = now.addingTimeInterval(-30 * 86_400)
        p.setRecipients([r])
        return p
    }

    // A pitch on a show that has been and gone, waiting on Dan to say how it ended.
    @discardableResult
    private func afterTheShow(_ context: ModelContext, key: String = "passed") -> Prospect {
        let p = show(key, "Lumen Dance", on: day(-5 * 86_400))
        p.sentAt = now.addingTimeInterval(-20 * 86_400)
        context.insert(p)
        let r = Recipient(id: "\(key)@example.com", email: "\(key)@example.com", name: "Rowan",
                          provenance: .act)
        r.sendState = .sent
        r.sentAt = now.addingTimeInterval(-20 * 86_400)
        // `hasProvenOutreach`: a post-event prompt is owed only on outreach that provably left, which is
        // a real message id and not merely a send state.
        r.gmailMessageId = "m-\(key)"
        p.setRecipients([r])
        return p
    }

    // A reply draft Dan asked for that died before arriving.
    @discardableResult
    private func stalledReplyDraft(_ context: ModelContext, key: String = "stalled") -> Prospect {
        let p = show(key, "Aurora Strings", on: day(30 * 86_400))
        p.sentAt = now.addingTimeInterval(-2 * 86_400)
        context.insert(p)
        let r = Recipient(id: "\(key)@example.com", email: "\(key)@example.com", name: "Emma",
                          provenance: .act)
        r.sendState = .sent
        r.sentAt = now.addingTimeInterval(-2 * 86_400)
        r.replied = true
        r.repliedAt = now.addingTimeInterval(-3_600)
        r.lastReplyText = "Thanks for getting in touch."
        r.replyDraftRequestedAt = now.addingTimeInterval(-Recipient.replyDraftStallTimeout - 60)
        r.replyDraftBody = nil
        p.setRecipients([r])
        return p
    }

    // A form pitch with a conversation Overture thinks might be its reply, waiting on Dan to say whether
    // it is theirs. `daysAhead` is a parameter because the DOUBLE COUNT below needs this same show with
    // its date behind it rather than ahead.
    @discardableResult
    private func conversationToConfirm(_ context: ModelContext, key: String = "confirm",
                                       daysAhead: TimeInterval = 45) -> Prospect {
        let p = show(key, "54 Sings Shuffle Along", on: day(daysAhead * 86_400))
        context.insert(p)
        let r = Recipient(id: "form:https://\(key).example/contact", email: nil, name: "Corin",
                          provenance: .act)
        r.contactFormURL = "https://\(key).example/contact"
        r.formOutreachURL = "https://\(key).example/contact"
        r.outreachChannel = .contactForm
        r.formOutreachRecordedAt = now.addingTimeInterval(-3 * 86_400)
        r.sentAt = now.addingTimeInterval(-3 * 86_400)
        r.sendState = .sent
        p.setRecipients([r])
        ProposedConversation.propose(
            ProposedConversation.Candidate(messageId: "m-\(key)", threadId: "t-\(key)",
                                           fromAddress: "corin@example.com", fromName: "Corin",
                                           subject: "Re: the anniversary show",
                                           sentAt: now.addingTimeInterval(-3_600), score: 9),
            on: r, now: now)
        return p
    }

    private func allProspects(_ context: ModelContext) throws -> [Prospect] {
        try context.fetch(FetchDescriptor<Prospect>())
    }

    private func rows(_ all: [Prospect]) -> DueWork.Rows {
        DueWork.rows(prospects: all, now: now, replyRunAlive: false)
    }

    private func followUpsPill(_ queue: [Prospect], all: [Prospect]) -> AgentStatus {
        let inputs = AgentInputs.from(prospects: queue, allProspects: all,
                                      context: .at(today, now: now),
                                      gmailConnected: true, runInFlight: nil, replyRunAlive: false)
        return AgentRoster.statuses(inputs).first { $0.name == "Follow-ups" }!
    }

    // MARK: - The rule

    // The header's number and the rows the sheet draws are the same number. This is what #2967 broke:
    // `conversationsToConfirm` joined the total while the sheet had no section for it, so the header
    // could stand over fewer rows than it promised.
    @Test func theHeaderStatesExactlyWhatTheSheetDraws() throws {
        let context = try makeContext()
        silentFollowUp(context); afterTheShow(context)
        stalledReplyDraft(context); conversationToConfirm(context)
        let all = try allProspects(context)
        let listed = rows(all)

        // Each kind is really present, so the equality below is asserting about four numbers rather than
        // about four zeroes.
        #expect(listed.silent.count == 1)
        #expect(listed.afterTheShow.count == 1)
        #expect(listed.stalledReplyDrafts.count == 1)
        #expect(listed.conversationsToConfirm.count == 1)

        #expect(listed.counts.total == listed.rendered,
                "the header states \(listed.counts.total) over \(listed.rendered) rendered rows")
        #expect(listed.rendered == 4)
    }

    // The pill Dan clicks states the number of the sheet he lands on. This is what #2968 broke: the pill
    // counted silent nudges alone, so it read "None due" over a sheet holding after the show rows.
    @Test func thePillStatesTheNumberOfTheSheetItOpens() throws {
        let context = try makeContext()
        afterTheShow(context); conversationToConfirm(context)
        let all = try allProspects(context)
        let listed = rows(all)

        // Deliberately NO silent follow-up in this store: that is the exact state in #2968, where the
        // only number the pill knew how to state was zero.
        #expect(listed.silent.isEmpty)
        #expect(listed.rendered == 2)

        let pill = followUpsPill(all, all: all)
        #expect(pill.count == listed.rendered,
                "the pill says \(pill.count) over a sheet drawing \(listed.rendered) rows")
        #expect(pill.detail != "None due", "the pill says nothing is due over a sheet with rows in it")
    }

    // A show Dan dismissed AFTER emailing it owes NOTHING.
    //
    // Dan's call, 2026-08-23: "if I dismiss it after emailing, no nudges". His reasoning, recorded on
    // #2968 on 2026-08-21: the dismissal was a decision against the show, so it stops asking for work.
    // That does not silence the person, because a reply from them still arrives on its own path and
    // still reaches him (#2910), which is what makes the exclusion safe rather than a way of losing
    // them.
    //
    // This REPLACES `aDismissedShowThatWasEmailedIsCountedByThePillAsWellAsTheSheet`, which asserted
    // the opposite. That test was not adjusted, because its whole content was the behaviour this
    // decision removes, and a guard kept over a reversed decision defends the defect (the same reason
    // #2967 deleted `everyMemberOfTheHeaderCountHasASectionExceptTheOneFiledElsewhere` rather than
    // editing it).
    //
    // A SILENT follow-up rather than a post-event prompt, because `PostEventPrompt.nextPromptDate`
    // refuses a dismissed show outright (#238) already. The silent nudge was the one half with no such
    // guard, which is why it is the half this fixture builds.
    @Test func aDismissedShowThatWasEmailedOwesNothingOnAnySurface() throws {
        let context = try makeContext()
        let p = silentFollowUp(context, key: "dismissed")
        p.markDismissed(reason: .notAFit, at: now)
        let all = try allProspects(context)
        let queue = all.filter { $0.status != .dismissed }

        #expect(queue.isEmpty, "the queue's own list drops this show, which is the premise of #2968")
        #expect(FollowUp.dueRecipients(from: all, now: now).isEmpty,
                "a show Dan cut is still asking to be nudged")
        #expect(rows(all).rendered == 0,
                "the Follow-ups sheet draws \(rows(all).rendered) row(s) for a show Dan already cut")

        let pill = followUpsPill(queue, all: all)
        #expect(pill.count == 0, "the pill counts \(pill.count) on a show Dan already cut")
        #expect(pill.detail == "None due")
    }

    // The POSITIVE control, in the same fixture and on the same row: undismissed, it really is due. A
    // test that asserts nothing is owed is satisfied by a fixture in which nothing could ever be owed
    // (L159), and that would pass just as well if `dueRecipients` had simply stopped working.
    @Test func theSameShowUndismissedIsStillDue() throws {
        let context = try makeContext()
        _ = silentFollowUp(context, key: "dismissed")
        let all = try allProspects(context)

        #expect(FollowUp.dueRecipients(from: all, now: now).count == 1,
                "the fixture owes no nudge even undismissed, so the test above asserts nothing")
        #expect(rows(all).rendered == 1)
        #expect(followUpsPill(all, all: all).count == 1)
    }

    // The OTHER half of the same decision, and the reason the guard is not simply applied everywhere.
    //
    // Dan's words on #2968: a dismissal "does not silence the person. A reply from them still arrives on
    // its own path and still reaches him (#2910)". So the rule is about DIRECTION, not about the show:
    // a dismissal stops OVERTURE reaching out (a nudge, and a post-event prompt, which #238 already
    // refuses), and leaves untouched anything that exists because SOMEBODY REACHED IN.
    //
    // Both remaining members of the Due count are on the reaching-in side: a conversation to confirm is
    // a candidate reply awaiting his yes or no, and a stalled reply draft only exists because a reply
    // arrived and he asked for help answering it. Neither takes the dismissed guard, and that is a
    // decision with a reason rather than an omission (L129). Asserted here so the next person to notice
    // the asymmetry finds the rule instead of "fixing" it.
    @Test func aDismissalSilencesTheNudgeAndNotTheReply() throws {
        let context = try makeContext()
        let confirm = conversationToConfirm(context, key: "confirmdismissed")
        confirm.markDismissed(reason: .notAFit, at: now)
        let stalled = stalledReplyDraft(context, key: "stalleddismissed")
        stalled.markDismissed(reason: .notAFit, at: now)
        // A dismissed SILENT lead in the same store, so the nudge assertion below discriminates. Without
        // it that line is vacuous: a form pitch is not on the email channel and a replied contact is not
        // silent, so neither of the two rows above could owe a nudge whether the guard exists or not,
        // and the test would pass just as well with the guard deleted (L159). Measured: it did.
        let silent = silentFollowUp(context, key: "silentdismissed")
        silent.markDismissed(reason: .notAFit, at: now)
        let all = try allProspects(context)
        let listed = rows(all)

        #expect(listed.conversationsToConfirm.count == 1,
                "a possible reply stopped being asked about because the show was cut, which loses the person")
        #expect(listed.stalledReplyDrafts.count == 1,
                "a reply Dan asked for help answering vanished because the show was cut")
        // The nudge half really is silenced IN THE SAME STORE, so this asserts a difference rather than
        // passing because the guard does nothing at all.
        #expect(FollowUp.dueRecipients(from: all, now: now).isEmpty,
                "the dismissed silent lead is still asking to be nudged")
    }

    // #2967 state 2: one form pitch on a show that has been and gone is in `afterTheShow` and in
    // `conversationsToConfirm` at once. Counted twice it reads "Due 2" over one contact. The confirm
    // question wins, because how a show ended cannot be answered honestly while it is still unsettled
    // whether the act ever replied.
    @Test func oneContactOwingTwoQuestionsIsCountedOnce() throws {
        let context = try makeContext()
        conversationToConfirm(context, key: "both", daysAhead: -5)
        let all = try allProspects(context)
        let listed = rows(all)

        #expect(listed.conversationsToConfirm.count == 1,
                "the fixture no longer produces a conversation to confirm, so this asserts nothing")
        #expect(listed.rendered == 1,
                "one contact is drawn \(listed.rendered) times over")
        #expect(listed.counts.total == 1, "the header double counts one contact as \(listed.counts.total)")
        #expect(listed.afterTheShow.isEmpty,
                "the same contact is asked how the show ended while it is still unsettled whether they replied")
    }

    // MARK: - Built is not wired (L3)

    // The section exists in the sheet, iterating the shared rows, so the number above is a promise about
    // rows the app really draws rather than a list only this test has asked for.
    @Test func theSheetDrawsTheConversationsToConfirmSection() throws {
        let source = SourceGuardHelper.source("Overture/UI/FollowUpsView.swift")
        #expect(!source.isEmpty)

        #expect(SourceGuardHelper.containsCode(
            "ForEach(listed.conversationsToConfirm, id: \\.recipient.id)", in: source),
                "FollowUpsView counts conversations to confirm and draws no section iterating them (#2967)")
        // The row is somewhere to ACT, not only somewhere to read that something is waiting (#80, #126).
        #expect(source.contains("ProposedConversationCopy.confirm"),
                "the conversations section offers no way to confirm, which is the whole question it asks")
        #expect(source.contains("ProposedConversationCopy.decline"),
                "the conversations section offers no way to decline")
    }

    // The pill takes its number from DueWork, not from a predicate of its own. Two definitions of "what
    // is due" is the shape that let these drift in the first place, and the fix is worth nothing if the
    // roster keeps one (L16).
    @Test func theRosterAsksDueWorkRatherThanCountingForItself() throws {
        let source = SourceGuardHelper.source("Overture/Domain/AgentRoster.swift")
        #expect(!source.isEmpty)

        #expect(source.contains("DueWork.counts("),
                "AgentRoster no longer takes the Follow-ups number from DueWork (#2968, L16)")
        #expect(!SourceGuardHelper.containsCode("followUpsDue: FollowUp.dueRecipients(", in: source),
                "AgentRoster counts silent nudges alone again, which is exactly #2968")
    }
}
