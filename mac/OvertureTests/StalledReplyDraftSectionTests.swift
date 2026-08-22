import Testing
import Foundation
import SwiftData

// #2878/#2828: the Follow-ups pill counted a stalled reply draft that no screen listed.
//
// Dan, 2026-08-17, with two screenshots taken seconds apart: the pill read "1 reply draft stalled", and
// opening it showed "Due 0" over "Nothing to act on. Shows you've emailed appear here for a gentle
// follow-up...". A pill's number is a promise about rows (#863), and this one sent him to a screen that
// flatly contradicted it, under an empty state about a different subject entirely.
//
// The stalled draft was real (the store held a request stamped with no body), so the count was the
// honest half and the LIST was the half missing a row. These assert the two halves are one derivation:
// what the pill counts, what the sheet's header states, and what the sheet lists all come from
// `StalledReplyDraft.dueRecipients`, so they cannot come to different answers (L16).
//
// This is the Follow-ups half of the guard `StagePillCountMatchesNavigationTests` holds for every other
// pill. That suite excludes `.followUps` (and still does, correctly): the Follow-ups pill resolves no
// queue keys, so `StageNavigation` can say nothing about it. The exemption is about the GRAIN and was
// read as an exemption from the promise itself, which is how this went unnoticed.
@MainActor
@Suite("A stalled reply draft is counted and listed by one predicate (#2878, #2828)")
struct StalledReplyDraftSectionTests {
    // A fixed instant, with every date in the fixture derived from it, so real time cannot walk this
    // fixture into a different case than the one it was written for (L130, #2669).
    private let now = Date(timeIntervalSince1970: 1_780_000_000)
    private var today: String { EasternDate.today(now) }

    private func makeContext() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    // The exact state behind the screenshots: a pitch that went out two days ago (so no nudge is due
    // yet), on a show still a month ahead (so nothing is owed after it), which somebody answered, and
    // whose reply draft Dan asked for and never received.
    @discardableResult
    private func showWithAStalledReplyDraft(_ context: ModelContext) -> Prospect {
        let p = Prospect(naturalKey: "aurora", groupName: "Aurora Strings", discipline: "music",
                         venue: "Weill Recital Hall",
                         performanceDate: EasternDate.today(now.addingTimeInterval(30 * 86_400)),
                         sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .contacted)
        p.sentAt = now.addingTimeInterval(-2 * 86_400)
        context.insert(p)
        let r = Recipient(id: "act@example.com", email: "act@example.com", name: "Emma", provenance: .act)
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

    // #2718: a form pitch with a conversation Overture thinks might be its reply, waiting on Dan to say
    // whether it is theirs. It is counted in the sheet's header and rendered on the Reached out row, not
    // here, which is #2967. Built so the class guard below is asserting about a real number.
    @discardableResult
    private func showWithAConversationToConfirm(_ context: ModelContext) -> Prospect {
        let p = Prospect(naturalKey: "shuffle", groupName: "54 Sings Shuffle Along", discipline: "music",
                         venue: "54 Below",
                         performanceDate: EasternDate.today(now.addingTimeInterval(45 * 86_400)),
                         sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        context.insert(p)
        let r = Recipient(id: "form:https://54below.example/contact", email: nil, name: "Corin",
                          provenance: .act)
        r.contactFormURL = "https://54below.example/contact"
        r.formOutreachURL = "https://54below.example/contact"
        r.outreachChannel = .contactForm
        r.formOutreachRecordedAt = now.addingTimeInterval(-3 * 86_400)
        r.sentAt = now.addingTimeInterval(-3 * 86_400)
        r.sendState = .sent
        p.setRecipients([r])
        ProposedConversation.propose(
            ProposedConversation.Candidate(messageId: "m1", threadId: "t-m1",
                                           fromAddress: "corin@example.com", fromName: "Corin",
                                           subject: "Re: the anniversary show",
                                           sentAt: now.addingTimeInterval(-3_600), score: 9),
            on: r, now: now)
        return p
    }

    private func prospects(_ context: ModelContext) throws -> [Prospect] {
        try context.fetch(FetchDescriptor<Prospect>())
    }

    private func followUpsPill(_ all: [Prospect], replyRunAlive: Bool = false) -> AgentStatus {
        let inputs = AgentInputs.from(prospects: all, context: .at(today, now: now),
                                      gmailConnected: true, runInFlight: nil, replyRunAlive: replyRunAlive)
        return AgentRoster.statuses(inputs).first { $0.name == "Follow-ups" }!
    }

    // MARK: - The two halves Dan photographed

    // The pill half, unchanged and still honest: one stalled draft, said in Dan's words.
    @Test func thePillCountsTheStalledDraft() throws {
        let context = try makeContext()
        showWithAStalledReplyDraft(context)
        let pill = followUpsPill(try prospects(context))

        #expect(pill.detail == "1 reply draft stalled")
        #expect(pill.count == 1)
    }

    // THE defect. The sheet's own header renders `DueWork.counts(...).total`, and the toolbar badge that
    // opens the same sheet renders it too, so a stalled draft absent from it is the "Due 0" Dan read
    // over a pill that had just told him there was one.
    @Test func theSheetsHeaderCountsTheStalledDraftThePillSentHimFor() throws {
        let context = try makeContext()
        showWithAStalledReplyDraft(context)
        let counts = DueWork.counts(prospects: try prospects(context), now: now, replyRunAlive: false)

        #expect(counts.stalledReplyDrafts == 1)
        #expect(counts.total == 1, "the sheet reads \"Due \(counts.total)\" under a pill that says 1 stalled")
    }

    // The list half: the row the pill promised exists, and it names the show and the contact it is about,
    // so Dan can tell WHICH conversation stalled rather than only that one did.
    @Test func theSheetListsARowForTheStalledDraft() throws {
        let context = try makeContext()
        showWithAStalledReplyDraft(context)
        let listed = DueWork.rows(prospects: try prospects(context), now: now, replyRunAlive: false)

        #expect(listed.stalledReplyDrafts.count == 1)
        #expect(listed.stalledReplyDrafts.first?.prospect.groupName == "Aurora Strings")
        #expect(listed.stalledReplyDrafts.first?.recipient.email == "act@example.com")
    }

    // The other two sections stay empty in this state, which is what made the sheet read as having
    // nothing at all. Stated rather than assumed: if a stalled draft ever also became a silent follow-up
    // or a post-event prompt, the count above would be right for the wrong reason.
    @Test func aStalledDraftIsInNoOtherSectionSoNothingElseCoveredForIt() throws {
        let context = try makeContext()
        showWithAStalledReplyDraft(context)
        let listed = DueWork.rows(prospects: try prospects(context), now: now, replyRunAlive: false)

        #expect(listed.silent.isEmpty)
        #expect(listed.afterTheShow.isEmpty)
    }

    // MARK: - The invariant

    // The one #2878 asked for: the number the pill states equals the number of rows the sheet renders
    // for it. One predicate, asked twice, never two that happen to agree today.
    @Test func thePillsNumberEqualsTheRowsTheSheetRenders() throws {
        let context = try makeContext()
        showWithAStalledReplyDraft(context)
        let all = try prospects(context)
        let pill = followUpsPill(all)
        let listed = DueWork.rows(prospects: all, now: now, replyRunAlive: false)

        #expect(pill.count == listed.stalledReplyDrafts.count,
                "the pill says \"\(pill.detail)\" (\(pill.count)) over \(listed.stalledReplyDrafts.count) rows")
    }

    // The same promise with more than one stalled draft, so the guard cannot be satisfied by a fixture
    // where every count in sight happens to be 1 (L147).
    @Test func thePromiseHoldsForMoreThanOneStalledDraft() throws {
        let context = try makeContext()
        let p = showWithAStalledReplyDraft(context)
        let second = Recipient(id: "manager@example.com", email: "manager@example.com", name: "Ravi",
                               provenance: .act)
        second.sendState = .sent
        second.sentAt = now.addingTimeInterval(-2 * 86_400)
        second.replied = true
        second.repliedAt = now.addingTimeInterval(-7_200)
        second.replyDraftRequestedAt = now.addingTimeInterval(-Recipient.replyDraftStallTimeout - 600)
        p.setRecipients(p.recipients + [second])
        try context.save()

        let all = try prospects(context)
        let pill = followUpsPill(all)
        let listed = DueWork.rows(prospects: all, now: now, replyRunAlive: false)

        #expect(pill.detail == "2 reply drafts stalled")
        #expect(pill.count == 2)
        #expect(pill.count == listed.stalledReplyDrafts.count)
        // Oldest request first, so the one stranded longest is the one he meets at the top.
        #expect(listed.stalledReplyDrafts.map(\.recipient.id) == ["manager@example.com", "act@example.com"])
    }

    // #471: a classify run that is still beating is not a dead one, so nothing is stalled and nothing is
    // listed. Asserted on BOTH halves together, because a count and a list that disagree about when the
    // run is alive is the same defect in the other direction.
    @Test func aLiveClassifyRunLeavesNothingStalledAndNothingListed() throws {
        let context = try makeContext()
        showWithAStalledReplyDraft(context)
        let all = try prospects(context)
        let pill = followUpsPill(all, replyRunAlive: true)
        let listed = DueWork.rows(prospects: all, now: now, replyRunAlive: true)

        #expect(pill.count == 0)
        #expect(listed.stalledReplyDrafts.isEmpty)
        #expect(pill.count == listed.stalledReplyDrafts.count)
    }

    // MARK: - The class, not the instance

    // Every member of the number the sheet's header states must have a section in that sheet, or be a
    // named, filed exception. `conversationsToConfirm` (#2718) is the one exception: those rows are
    // answered on the Reached out row instead, which is #2967, so the header can still exceed the rows
    // behind it by exactly that and by nothing else.
    //
    // This is the guard that makes the fix a rule rather than one repaired instance: a FIFTH member
    // added to `Counts` with no section in the sheet fails here, which is precisely how
    // `stalledReplyDrafts` got in unnoticed.
    //
    // The fixture PUTS a proposed conversation in the store, so the exception is a real number rather
    // than a zero the assertion would be satisfied by whatever the code did (L159). With no proposal
    // both sides read 0 and the test would pass in a fixture where the case cannot arise.
    @Test func everyMemberOfTheHeaderCountHasASectionExceptTheOneFiledElsewhere() throws {
        let context = try makeContext()
        showWithAStalledReplyDraft(context)
        showWithAConversationToConfirm(context)
        let all = try prospects(context)
        let counts = DueWork.counts(prospects: all, now: now, replyRunAlive: false)
        let listed = DueWork.rows(prospects: all, now: now, replyRunAlive: false)

        // The exception exists in this store, so the difference below is asserting about something.
        #expect(counts.conversationsToConfirm == 1)
        #expect(listed.stalledReplyDrafts.count == 1)

        #expect(counts.total - listed.rendered == counts.conversationsToConfirm,
                "the header states \(counts.total) over \(listed.rendered) rendered rows, and only \(counts.conversationsToConfirm) of that difference is the conversations answered on the Reached out row (#2967): something else is counted with no section to land on")
    }

    // MARK: - Built is not wired (L3)

    // The section exists in the sheet and is built from the shared function, so the rows above are rows
    // the app actually draws rather than a list only a test has ever asked for.
    @Test func theSheetRendersTheStalledSectionFromTheSharedRows() throws {
        let source = SourceGuardHelper.source("Overture/UI/FollowUpsView.swift")
        #expect(!source.isEmpty)

        #expect(source.contains("StalledReplyDraftCopy.section"),
                "FollowUpsView no longer draws a section for the stalled reply drafts it counts (#2878)")
        // #2726: the ForEach, since ITERATING is what this asserts. The bare name is satisfied by the
        // `isEmpty` test above it, which is not the same claim (L135).
        #expect(SourceGuardHelper.containsCode(
            "ForEach(listed.stalledReplyDrafts, id: \\.recipient.id)", in: source),
                "the stalled section no longer iterates the shared rows (#2878)")
        #expect(source.contains("DueWork.rows("),
                "FollowUpsView no longer takes its rows from DueWork, so it can derive them a second way")
        // The view holds no predicate of its own. Two definitions of "is this stalled" is the shape that
        // let the count and the list disagree, and the fix is worth nothing if the view reintroduces one.
        #expect(!source.contains("isReplyDraftStalled"),
                "FollowUpsView asks the stalled question for itself again, beside the count that already answers it (#2878, L16)")
    }

    // The row is somewhere to ACT, not only somewhere to read that something is wrong (#80, #126).
    @Test func theStalledRowCarriesAnAction() throws {
        let source = SourceGuardHelper.source("Overture/UI/FollowUpsView.swift")
        let body = try #require(SourceGuardHelper.bodyOfFunction(named: "stalledReplyDraftRow", in: source),
                                "the stalled reply draft row was not found in FollowUpsView")

        #expect(body.contains("StalledReplyDraftCopy.tryAgain"),
                "the stalled row names a problem with nothing to press (#80, #126)")
        #expect(body.contains("View in Archive"),
                "the stalled row has no way through to the conversation it is about")
    }

    // The header states the count of the SAME derivation the rows come from, rather than sweeping the
    // store a second time for a number. Two sweeps is how a header can say 0 over a populated list.
    @Test func theHeaderCountsTheDerivationTheRowsCameFrom() throws {
        let source = SourceGuardHelper.source("Overture/UI/FollowUpsView.swift")

        #expect(source.contains("Text(\"\\(listed.counts.total)\")"),
                "the sheet's header no longer states the count of the rows it renders (#885, #2878)")
    }

    // The row's own sentence, read the way Dan meets it: it has to say WHEN, because "stalled" alone
    // does not tell him whether to wait or to press again.
    @Test func theRowSaysHowLongTheDraftHasBeenStranded() {
        let line = StalledReplyDraftCopy.line(requestedAt: now.addingTimeInterval(-3 * 3_600), now: now)

        // The interval, not its exact rendering: the formatter's wording is the platform's to choose,
        // and pinning it would make this go red for a reason unrelated to the rule (L103).
        #expect(line.contains("3 hours"))
        #expect(line.hasPrefix("You asked for this reply draft "))
        #expect(line.hasSuffix(" and it never arrived."))
    }

    // The empty state names every subject the sheet holds. It named two of the three, so the one state
    // that sent Dan here with nothing to see was answered by a sentence about something else (L11).
    // Asserted on the sentence itself AND on the view rendering that sentence, because either half alone
    // can go quietly wrong: a correct sentence the view stopped drawing, or a view drawing a sentence the
    // stalled clause was edited out of.
    @Test func theEmptyStateNamesTheStalledDraftsToo() throws {
        #expect(EmptyState.followUpsSheet.contains(StalledReplyDraftCopy.nothingStalled),
                "the empty state still speaks only about shows Dan emailed, on a sheet that also holds stalled reply drafts (#2878, L11)")

        let source = SourceGuardHelper.source("Overture/UI/FollowUpsView.swift")
        let empty = try #require(SourceGuardHelper.between("if listed.isEmpty {", and: "} else {", in: source),
                                 "the sheet's empty state was not found where the guard expects it")
        #expect(empty.contains("EmptyState.followUpsSheet"),
                "the sheet's empty branch no longer renders the shared empty sentence (#2878, #885)")
    }
}
