import Testing
import Foundation
import SwiftData

// #1800: what a stage strip may double count, and #1797: who speaks for a contact a review guard holds.
//
// Every pill was honest about its own predicate and silent about the set it shared with its neighbours,
// and no test forbade an overlap, so one show could be promised by two numbers at once and read as two
// pieces of work. The instance Dan saw is the pair below (untriaged AND reported as a send problem, on a
// show nothing was ever sent to); these are the property, which outlives it.
@MainActor
@Suite("A show belongs to one piece of work at a time (#1800, #1797)")
struct StageOverlapTests {
    private func makeContext() -> ModelContext {
        ModelContext(try! ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                         configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func show(_ ctx: ModelContext, key: String, status: ReviewStatus,
                      hasDraft: Bool = false, sentAt: Date? = nil) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: key, discipline: "theatre", venue: "Under St Marks",
                         performanceDate: "2099-08-14", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: status)
        if hasDraft { p.draftBody = "Hi" }
        p.sentAt = sentAt
        ctx.insert(p)
        return p
    }

    // A contact the duplicate guard is holding: pending, with a real address, flagged and undismissed.
    // This is the exact shape of the one recipient in the live store that satisfies isBlockedAwaitingReview.
    @discardableResult
    private func heldContact(_ p: Prospect, id: String = "office@frigid.nyc") -> Recipient {
        let r = Recipient(id: id, email: id, provenance: .presenter)
        r.sendState = .pending
        r.looksLikeDuplicateContact = true
        p.addRecipient(r)
        return r
    }

    private func sentContact(_ p: Prospect, id: String = "sent@example.com") {
        let r = Recipient(id: id, email: id, provenance: .act)
        r.sendState = .sent
        p.addRecipient(r)
    }

    private func focuses(_ p: Prospect) -> [StageFocus] {
        StageNavigation.countedFocuses.filter {
            StageNavigation.naturalKeys(for: $0, in: [p]).count == 1
        }
    }

    // MARK: - #1797, the instance

    // Dan, 2026-07-30: "why is this marked as send issues if I've never tried to email them". He had not.
    @Test func anUntriagedShowWithAHeldContactIsNotASendProblem() throws {
        let ctx = makeContext()
        let p = show(ctx, key: "untriaged", status: .new)
        heldContact(p)

        #expect(p.blockedContactCount == 1)          // the guard still holds it
        #expect(!focuses(p).contains(.sendBlocked))  // Send issues does not speak for it
    }

    // The complement, which is the half that must never be lost: it is still somewhere Dan will see it.
    @Test func thatShowIsStillInTriage() throws {
        let ctx = makeContext()
        let p = show(ctx, key: "untriaged", status: .new)
        heldContact(p)

        #expect(focuses(p) == [.scout])
    }

    // #792's own case, unchanged: a show already sent to somebody else, with one contact still held. This
    // is what the stage was built for, and gating it too tightly would make that person invisible again.
    @Test func aShowAlreadySentToKeepsItsHeldContactUnderSendIssues() throws {
        let ctx = makeContext()
        let p = show(ctx, key: "contacted", status: .contacted, hasDraft: true, sentAt: Date())
        heldContact(p)
        sentContact(p)

        #expect(focuses(p).contains(.sendBlocked))
    }

    // A draft exists, so the send is the next thing that happens here: #1797 names drafted, approved and
    // contacted as the send half. Without this the gate could be satisfied by refusing everything until a
    // send has actually gone out, which would hide a held contact for the whole of Review.
    @Test func aDraftedShowWithAHeldContactIsASendProblem() throws {
        let ctx = makeContext()
        let p = show(ctx, key: "drafted", status: .drafted, hasDraft: true)
        heldContact(p)

        #expect(focuses(p).contains(.sendBlocked))
    }

    // A kept show that was sent to before being re-prepped: status alone says no, the send says yes.
    @Test func aSentRecipientPutsAShowInTheSendHalfWhateverItsStatusSays() throws {
        let ctx = makeContext()
        let p = show(ctx, key: "kept-but-sent", status: .queued)
        heldContact(p)
        sentContact(p)

        #expect(p.hasEnteredSendHalf)
        #expect(focuses(p).contains(.sendBlocked))
    }

    // MARK: - #1800, the property

    // The rule the strip must obey, over every state a show can be in at once. Written against the real
    // predicates rather than a copy of them, so it fails if a predicate changes underneath it.
    @Test func noShowInAnyStateBreaksTheOverlapRules() throws {
        let ctx = makeContext()
        // Untriaged, with the flag that used to put it in two pills at once.
        heldContact(show(ctx, key: "untriaged-held", status: .new))
        // Kept and waiting on a Prep run.
        show(ctx, key: "kept", status: .queued)
        // Drafted, awaiting review, with an earlier send that failed: two genuine pieces of work.
        let drafted = show(ctx, key: "drafted-with-error", status: .drafted, hasDraft: true)
        drafted.sendError = "550 mailbox unavailable"
        sentContact(drafted)
        // Approved, waiting on a click.
        show(ctx, key: "approved", status: .approved, hasDraft: true)
        // Re-prep queued on a drafted show: Prep and Review at once, deliberately.
        let reprep = show(ctx, key: "reprep", status: .drafted, hasDraft: true)
        reprep.reprepContactsRequested = true
        // Sent, with a contact still held.
        let contacted = show(ctx, key: "contacted-held", status: .contacted, hasDraft: true, sentAt: Date())
        heldContact(contacted)
        sentContact(contacted, id: "other@example.com")

        let all = try ctx.fetch(FetchDescriptor<Prospect>())
        let violations = StageOverlap.violations(in: all)

        #expect(violations.isEmpty, "\(violations.map { "\($0.key): \($0.rule.rawValue) \($0.focuses)" })")
    }

    // The re-prep overlap is not merely tolerated by the rules, it is real, and the suite has to hold it:
    // a rule that forbade it would be satisfied by silently dropping a re-prepped show out of Prep.
    @Test func aReprepOnADraftedShowIsInPrepAndReviewAtOnce() throws {
        let ctx = makeContext()
        let p = show(ctx, key: "reprep", status: .drafted, hasDraft: true)
        p.reprepContactsRequested = true

        #expect(Set(focuses(p)) == Set([.prep, .review]))
        #expect(StageOverlap.violations(in: [p]).isEmpty)
    }

    // The rules have teeth: a show that genuinely breaks one is reported, naming the rule. Without this
    // the property test above could pass because `violations` never returns anything.
    @Test func aSendProblemOnAShowThatWasNeverSentToIsReported() throws {
        let ctx = makeContext()
        let p = show(ctx, key: "never-sent", status: .new)
        p.sendError = "550 mailbox unavailable"   // a failure on a show nothing was sent from

        let violations = StageOverlap.violations(in: [p])

        #expect(violations.map(\.rule) == [.sendProblemNeedsSendHalf])
        #expect(violations.first?.focuses == [.sendErrors])
    }

    // MARK: - the card, the other half of the complement

    // Dan's call, 2026-08-01: he wants to see it while deciding keep or dismiss.
    @Test func theTriageCardSpeaksForAHeldContactOnAnUntriagedShow() throws {
        let ctx = makeContext()
        let p = show(ctx, key: "untriaged-held", status: .new)
        heldContact(p)
        try ctx.save()

        let item = try #require(QueueModel.items(from: [p]).first)

        #expect(item.heldContactAtTriage == .duplicate)
    }

    // ...and stops the moment Send issues starts, so the same hold is never stated twice. The draft
    // review already says "1 contact held for a check" on a drafted show.
    @Test func theTriageCardGoesQuietOnceTheShowIsInTheSendHalf() throws {
        let ctx = makeContext()
        let p = show(ctx, key: "drafted-held", status: .drafted, hasDraft: true)
        heldContact(p)
        try ctx.save()

        let item = try #require(QueueModel.items(from: [p]).first)

        #expect(item.heldContactAtTriage == nil)
        #expect(StageNavigation.naturalKeys(for: .sendBlocked, in: [p]) == ["drafted-held"])
    }

    // The property that matters more than either half: every held contact is spoken for by exactly one
    // surface. Neither is the #792 defect (a real person waiting, with nothing anywhere saying so); both
    // is the #843 one (the same sentence twice).
    @Test func everyHeldContactIsSpokenForExactlyOnce() throws {
        let ctx = makeContext()
        for (key, status) in [("new", ReviewStatus.new), ("queued", .queued), ("drafted", .drafted),
                              ("approved", .approved), ("contacted", .contacted)] {
            let p = show(ctx, key: key, status: status, hasDraft: status != .new && status != .queued)
            heldContact(p, id: "held-\(key)@example.com")
        }
        try ctx.save()
        let all = try ctx.fetch(FetchDescriptor<Prospect>())

        for p in all {
            let item = try #require(QueueModel.items(from: [p]).first)
            let card = item.heldContactAtTriage != nil
            let stage = StageNavigation.naturalKeys(for: .sendBlocked, in: [p]).count == 1
            #expect(card != stage, "\(p.naturalKey): card=\(card) stage=\(stage)")
        }
    }

    // Every focus says which half of the funnel it is about. This is what carries the rule forward: a
    // focus added later cannot compile without joining a family, so it cannot quietly escape the checks.
    @Test func everyFocusDeclaresItsFamilyAndTheCountedOnesResolveKeys() {
        for focus in StageNavigation.countedFocuses {
            #expect(StageOverlap.family(of: focus) != .resolvesNoKeys,
                    "\(focus) resolves queue keys, so it cannot be in the family for focuses that do not")
        }
        #expect(StageOverlap.family(of: .followUps) == .resolvesNoKeys)
        #expect(StageOverlap.family(of: .reachedOut) == .resolvesNoKeys)
    }
}
