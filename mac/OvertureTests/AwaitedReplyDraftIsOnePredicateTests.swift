import Testing
import Foundation
import SwiftData

// #2966: "is a reply draft still awaited" was asked in THREE bodies, and only one of them carried the
// guard that makes the answer true.
//
// `Recipient.recordAnswerSent` nils `replyDraftBody`, stamps `replyHandledAt`, and leaves
// `replyDraftRequestedAt` standing. That is deliberate: `Recipient.wasWrittenTo` reads the stamp as
// evidence a real exchange happened, and it guards a delete path. So every reader has to allow for a
// request that belongs to an exchange already answered (L68), and one of the three did:
//
//   * `ReplyPanel.isDrafting` guarded it, with a comment naming exactly this.
//   * `Recipient.isReplyDraftStalled` did not, so every conversation Dan answered through Overture after
//     asking for an AI draft read as permanently stalled. Harmless while nothing rendered it; #2878 wires
//     it into `DueWork`, which would have made it a gold pill, a toolbar badge, a Dock tile and a menu bar
//     count that no action could clear.
//   * `RecipientSnapshot.isDraftingReply` did not either, and it drives `ReplyConversationView`'s
//     "Drafting a reply..." live label and its Retry, so the same answered conversation showed a run that
//     had finished hours earlier with a button offering to restart it.
//
// One predicate now (`ReplyDraftRequest.awaited`), which is the part that stops this recurring: the
// missing guard is only where it surfaced (L16, L30).
@MainActor
@Suite("Whether a reply draft is still awaited is one predicate (#2966)")
struct AwaitedReplyDraftIsOnePredicateTests {
    // Both ends pinned, so real time cannot walk this fixture into a different case (L130, #2669).
    private let now = Date(timeIntervalSince1970: 1_780_000_000)
    private var today: String { EasternDate.today(now) }
    private var longEnoughAgo: Date { now.addingTimeInterval(-Recipient.replyDraftStallTimeout - 60) }

    private func makeContext() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private func show(_ context: ModelContext) -> Prospect {
        let p = Prospect(naturalKey: "aurora", groupName: "Aurora Strings", discipline: "music",
                         venue: "Weill Recital Hall",
                         performanceDate: EasternDate.today(now.addingTimeInterval(30 * 86_400)),
                         sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .contacted)
        p.sentAt = now.addingTimeInterval(-2 * 86_400)
        context.insert(p)
        return p
    }

    // Dan asked for an AI reply draft, then answered the conversation through Overture. That send is what
    // consumed the draft body and stamped the answer; the request stamp is left where it was.
    private func answeredAfterAskingForADraft(_ context: ModelContext) -> (Prospect, Recipient) {
        let p = show(context)
        let r = Recipient(id: "act@example.com", email: "act@example.com", name: "Emma", provenance: .act)
        r.sendState = .sent
        r.sentAt = now.addingTimeInterval(-2 * 86_400)
        r.replied = true
        r.repliedAt = longEnoughAgo.addingTimeInterval(-60)
        r.lastReplyText = "Thanks for getting in touch."
        r.replyDraftRequestedAt = longEnoughAgo
        r.replyDraftBody = "A draft the run produced."
        p.setRecipients([r])
        // The real writer, not a hand-set field: this is the send path that leaves the stamp behind.
        r.recordAnswerSent(now: longEnoughAgo.addingTimeInterval(30))
        return (p, r)
    }

    // Nothing has come back yet and nobody has answered, which is the state the section exists for.
    private func stillAwaitingADraft(_ context: ModelContext) -> (Prospect, Recipient) {
        let p = show(context)
        let r = Recipient(id: "act@example.com", email: "act@example.com", name: "Emma", provenance: .act)
        r.sendState = .sent
        r.sentAt = now.addingTimeInterval(-2 * 86_400)
        r.replied = true
        r.repliedAt = longEnoughAgo.addingTimeInterval(-60)
        r.lastReplyText = "Thanks for getting in touch."
        r.replyDraftRequestedAt = longEnoughAgo
        r.replyDraftBody = nil
        p.setRecipients([r])
        return (p, r)
    }

    // MARK: - The defect

    // The reading #2878 wires into every count Dan can see. An answered conversation is not a stalled one.
    @Test func anAnsweredConversationIsNotStalledHoweverLongAgoTheDraftWasAskedFor() throws {
        let context = try makeContext()
        let (_, r) = answeredAfterAskingForADraft(context)

        #expect(r.replyDraftRequestedAt != nil, "the stamp is deliberately left standing, so this fixture is the real state")
        #expect(r.replyHandledAt != nil)
        #expect(r.isReplyDraftStalled(now: now) == false,
                "a conversation answered hours ago reads as a reply draft that stalled, which no action can clear")
    }

    // All three readings, on one recipient, in one assertion each, so a guard added to one of them again
    // cannot leave the others behind.
    @Test func theThreeReadingsAgreeThatNothingIsAwaited() throws {
        let context = try makeContext()
        let (_, r) = answeredAfterAskingForADraft(context)

        #expect(r.awaitedReplyDraftRequestedAt == nil)
        #expect(r.isReplyDraftStalled(now: now) == false)
        #expect(ReplyPanel.isDrafting(r) == false)
        #expect(RecipientSnapshot(r).isDraftingReply == false,
                "the reply panel shows a finished run as still drafting, with a Retry beside it")
    }

    // The positive case in the SAME fixture shape, so the negative above is not passing because the state
    // could not arise at all (L159).
    @Test func theThreeReadingsAgreeThatADraftIsStillAwaited() throws {
        let context = try makeContext()
        let (_, r) = stillAwaitingADraft(context)

        #expect(r.awaitedReplyDraftRequestedAt == longEnoughAgo)
        #expect(r.isReplyDraftStalled(now: now) == true)
        #expect(ReplyPanel.isDrafting(r) == true)
        #expect(RecipientSnapshot(r).isDraftingReply == true)
    }

    // MARK: - What #2878 wired it into

    // The exposure that made this a blocker: with the phantom in place, every one of these reads 1 and
    // nothing Dan can press changes any of them.
    @Test func anAnsweredConversationCountsTowardNothingDanCanSee() throws {
        let context = try makeContext()
        answeredAfterAskingForADraft(context)
        let all = try context.fetch(FetchDescriptor<Prospect>())
        let inputs = AgentInputs.from(prospects: all, allProspects: all, context: .at(today, now: now),
                                     gmailConnected: true, runInFlight: nil, replyRunAlive: false)
        let counts = DueWork.counts(prospects: all, now: now, replyRunAlive: false)
        let listed = DueWork.rows(prospects: all, now: now, replyRunAlive: false)

        #expect(inputs.stalledReplyDrafts == 0)          // the Follow-ups pill
        #expect(counts.stalledReplyDrafts == 0)          // the sheet's header, the toolbar badge
        #expect(counts.total == 0)                       // the Dock tile and the menu bar
        #expect(listed.stalledReplyDrafts.isEmpty)       // the section
    }

    // And the genuine stall still reaches all four, so the fix did not buy its quiet by silencing the
    // thing the section exists for.
    @Test func aGenuinelyAwaitedDraftStillReachesEveryCount() throws {
        let context = try makeContext()
        stillAwaitingADraft(context)
        let all = try context.fetch(FetchDescriptor<Prospect>())
        let inputs = AgentInputs.from(prospects: all, allProspects: all, context: .at(today, now: now),
                                     gmailConnected: true, runInFlight: nil, replyRunAlive: false)
        let counts = DueWork.counts(prospects: all, now: now, replyRunAlive: false)
        let listed = DueWork.rows(prospects: all, now: now, replyRunAlive: false)

        #expect(inputs.stalledReplyDrafts == 1)
        #expect(counts.stalledReplyDrafts == 1)
        #expect(counts.total == 1)
        #expect(listed.stalledReplyDrafts.count == 1)
    }

    // MARK: - The stamp itself stays

    // Why this is fixed in the READERS and not by clearing the stamp in `recordAnswerSent`:
    // `wasWrittenTo` reads it as evidence a real exchange happened, and it guards a delete path, so
    // clearing it could turn a real outreach record into one that reads as never having gone out (L5).
    @Test func theRequestStampIsStillEvidenceThatAnExchangeHappened() throws {
        let context = try makeContext()
        let (_, r) = answeredAfterAskingForADraft(context)

        #expect(r.replyDraftRequestedAt != nil)
        #expect(r.wasWrittenTo)

        // And the stamp is genuinely load-bearing there rather than incidentally true beside other marks.
        // Asserted as the DIFFERENCE the stamp makes, not by enumerating what `wasWrittenTo` reads, which
        // would be a second copy of that predicate sitting here going stale (L41).
        let bare = Recipient(id: "bare@example.com", email: "bare@example.com", provenance: .act)
        bare.replyDraftRequestedAt = longEnoughAgo
        #expect(bare.wasWrittenTo,
                "the request stamp alone marks this contact as written to, which is why clearing it is a change to a delete guard")
        bare.replyDraftRequestedAt = nil
        #expect(bare.wasWrittenTo == false)
    }

    // MARK: - One definition, not three

    // Built is not wired (L3): the three readings must be spelled through the shared rule rather than each
    // repeating its conditions, or the next guard added to one of them leaves the other two behind again.
    @Test func noReaderSpellsTheConditionsForItself() throws {
        for path in ["Overture/Domain/Recipient.swift",
                     "Overture/Domain/ReplyPanel.swift",
                     "Overture/UI/QueueView+Model.swift"] {
            let source = SourceGuardHelper.source(path)
            #expect(!source.isEmpty, "\(path) was not found")
            #expect(source.contains("ReplyDraftRequest.awaited") || source.contains("awaitedReplyDraftRequestedAt"),
                    "\(path) no longer reads the shared awaited-draft rule (#2966)")
        }
    }

    // The rule's own body carries the answered guard. Asserted at the rule rather than at each reader,
    // which is the whole point of there being one.
    @Test func theSharedRuleRefusesARequestBelongingToAnAnsweredExchange() throws {
        let source = SourceGuardHelper.source("Overture/Domain/ReplyDraftRequest.swift")
        let body = try #require(SourceGuardHelper.bodyOfFunction(named: "awaited", in: source),
                                "the shared awaited-draft rule was not found")

        #expect(body.contains("answeredAt"),
                "the shared rule stopped allowing for a request that belongs to an answered exchange (#2966)")
    }
}
