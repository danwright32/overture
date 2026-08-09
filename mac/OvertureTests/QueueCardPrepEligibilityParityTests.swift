import Testing
import Foundation
import SwiftData

// #1666: the queue card states what happens to a show next, and it used to do so without consulting the
// rule that decides it. "Contact: pending Prep run" (#1534) rendered off `isKept`, while
// `PrepQueueBuilder.needsPrep` refuses any show with an open date conflict and `prepMode` downgrades a
// probed show to writing the draft alone. Deleting that one line removed the instance, not the gap: the
// next status line added to the card would derive the answer by hand and be wrong the same way, and
// nothing compared the card's claim to the Prep queue's own predicate.
//
// So the card has ONE accessor (`QueueItem.nextPrepRun`, and `isAwaitingPrepRun` over it), routed through
// `PrepQueueBuilder.needsPrepEligible` and `PrepQueueBuilder.prepMode`, and this is the guard on it. It is
// in the shape of PrepQueueEligibilityParityTests, which does the same job for RootView's #Predicate.
//
// Two independent routes meet here, deliberately (L70). The card's side is a real `QueueItem` built from
// a stored `Prospect` by the app's own mapping, which is the only way a card is ever made. The rule's
// side is the queue `PrepQueueService.buildQueue` actually hands the Prep run: the file the run reads,
// built by the code that writes it, not by this test restating what it ought to contain. Nothing here
// re-states the eligibility rule itself; the only thing read by hand is `reprepMode`, which is the
// handoff file's published wire vocabulary (docs/contracts.md), read exactly as the run reads it.
@MainActor
@Suite("The queue card's Prep claim comes from the Prep queue's own rule (#1666)")
struct QueueCardPrepEligibilityParityTests {

    private let today = "2026-07-01"
    private let probedAt = Date(timeIntervalSince1970: 1_780_000_000)

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(
            for: Schema([Prospect.self, Recipient.self, PromotedProducer.self, DemotedHouse.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    // No history read from disk: the band a draft may cite is irrelevant here and reading it would make
    // this test depend on whatever is in the handoff directory on the machine running it.
    private var emptyHistory: VenueShootHistory {
        VenueShootHistory(shoots: [], bookings: [], today: today)
    }

    @discardableResult
    private func show(_ ctx: ModelContext, _ key: String, status: ReviewStatus,
                      hasDraft: Bool = false,
                      draftRequested: Bool = false, contactsRequested: Bool = false,
                      conflicted: Bool = false, clearedAfterConflict: Bool = false,
                      probedEmail: String? = nil) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: key, discipline: "music", venue: "Merkin Hall",
                         performanceDate: "2026-09-12", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: status)
        if hasDraft { p.draftBody = "Hi" }
        p.reprepDraftRequested = draftRequested
        p.reprepContactsRequested = contactsRequested
        if conflicted || clearedAfterConflict {
            p.setScoutConflict(BlockedCalendar.Day(date: "2026-09-12", kind: .dayOff,
                                                   name: "Vacation").key)
            // Dan overruled it, so the night is his again and the show is ordinary work.
            if clearedAfterConflict { p.clearConflict() }
        }
        if let probedEmail {
            p.reachabilityProbedAt = probedAt
            p.recipients = [Recipient(id: probedEmail, email: probedEmail, provenance: .act)]
        }
        ctx.insert(p)
        return p
    }

    // The handoff file's own vocabulary for which half of the work an item asks for, read back as the
    // run reads it. Absent means do both, which is what the wire has always meant.
    private func intent(ofQueued reprepMode: String?) -> PrepRunIntent {
        switch reprepMode {
        case PrepQueueBuilder.draftOnlyMode: return .draftOnly
        case PrepQueueBuilder.contactsOnlyMode: return .contactsOnly
        default: return .contactsAndDraft
        }
    }

    private func populated(_ ctx: ModelContext) throws {
        show(ctx, "kept-undrafted", status: .queued)
        show(ctx, "kept-undrafted-on-a-blocked-night", status: .queued, conflicted: true)
        show(ctx, "kept-undrafted-clash-overruled", status: .queued, clearedAfterConflict: true)
        show(ctx, "kept-undrafted-already-probed", status: .queued, probedEmail: "jane@aurora.org")
        show(ctx, "kept-undrafted-probe-found-nobody", status: .queued, probedEmail: "")
        show(ctx, "kept-with-a-draft", status: .queued, hasDraft: true)
        show(ctx, "drafted-redraft-asked-for", status: .drafted, hasDraft: true, draftRequested: true)
        show(ctx, "drafted-contacts-asked-for", status: .drafted, hasDraft: true, contactsRequested: true)
        show(ctx, "approved-both-asked-for", status: .approved, hasDraft: true,
             draftRequested: true, contactsRequested: true)
        show(ctx, "approved-nothing-asked-for", status: .approved, hasDraft: true)
        show(ctx, "drafted-redraft-asked-for-on-a-blocked-night", status: .drafted, hasDraft: true,
             draftRequested: true, conflicted: true)
        show(ctx, "untriaged", status: .new)
        show(ctx, "dismissed-with-flags-set", status: .dismissed, hasDraft: true,
             draftRequested: true, contactsRequested: true)
        show(ctx, "already-emailed-with-flags-set", status: .contacted, hasDraft: true,
             draftRequested: true, contactsRequested: true)
        try ctx.save()
    }

    // MARK: - The parity itself

    @Test func theCardAndTheQueueTheRunReceivesAgreeOnEveryShow() throws {
        let ctx = try context()
        try populated(ctx)

        let prospects = try ctx.fetch(FetchDescriptor<Prospect>())
        let queue = PrepQueueService.buildQueue(from: ctx, generatedAt: "2026-07-01T00:00:00.000Z",
                                                today: today, venueHistory: emptyHistory)
        let handedOver = Dictionary(uniqueKeysWithValues: queue.items.map { ($0.naturalKey, $0) })

        // Non-vacuous on both sides: a run that took nothing up, or a store the mapping produced no cards
        // from, would agree perfectly while proving nothing (L1, L63).
        #expect(prospects.count == 14, "the fixture did not land, so nothing was compared")
        #expect(!handedOver.isEmpty, "the Prep run was handed no shows at all, so nothing was compared")
        #expect(handedOver.count < prospects.count, "every show was queued, so no refusal was exercised")

        for p in prospects {
            let card = QueueItem(p)
            let queued = handedOver[p.naturalKey]

            let handed = queued == nil ? "was not handed it" : "was handed it"
            #expect(card.isAwaitingPrepRun == (queued != nil),
                    "\(p.naturalKey): the card says awaiting=\(card.isAwaitingPrepRun) but the Prep run \(handed)")

            let expected = queued.map { intent(ofQueued: $0.reprepMode) } ?? .notQueued
            #expect(card.nextPrepRun == expected,
                    "\(p.naturalKey): the card says \(card.nextPrepRun), the queue says \(expected)")
        }
    }

    // The four answers all occur in the fixture above. Without this the parity loop could stay green
    // over a set that only ever exercises one of them.
    @Test func theFixtureExercisesEveryIntent() throws {
        let ctx = try context()
        try populated(ctx)

        let intents = Set(try ctx.fetch(FetchDescriptor<Prospect>()).map { QueueItem($0).nextPrepRun })
        #expect(intents == [.notQueued, .contactsAndDraft, .draftOnly, .contactsOnly])
    }

    // MARK: - The two cases the card used to get wrong

    // #1534's defect exactly: kept is not queued. The card still calls this show kept, and must not
    // claim a Prep run for a night Dan is already committed to.
    @Test func aKeptShowOnABlockedNightIsKeptAndIsNotAwaitingAPrepRun() throws {
        let ctx = try context()
        let p = show(ctx, "kept-undrafted-on-a-blocked-night", status: .queued, conflicted: true)
        try ctx.save()

        let card = QueueItem(p)
        #expect(card.isKept, "the fixture must be a kept show, or this proves nothing about isKept")
        #expect(!card.isAwaitingPrepRun)
        #expect(card.nextPrepRun == .notQueued)

        let queue = PrepQueueService.buildQueue(from: ctx, generatedAt: "now", today: today,
                                                venueHistory: emptyHistory)
        #expect(queue.items.isEmpty, "the Prep run refuses it too, which is the point of the parity")
    }

    // Overruling the clash hands the show back: the same fixture, one decision later, is ordinary work
    // again on both sides. The refusal above is a real gate rather than a fixture that can never pass.
    @Test func overrulingTheClashPutsTheShowBackInFrontOfTheNextRun() throws {
        let ctx = try context()
        let p = show(ctx, "kept-undrafted-clash-overruled", status: .queued, clearedAfterConflict: true)
        try ctx.save()

        #expect(QueueItem(p).nextPrepRun == .contactsAndDraft)
        let queue = PrepQueueService.buildQueue(from: ctx, generatedAt: "now", today: today,
                                                venueHistory: emptyHistory)
        #expect(queue.items.map(\.naturalKey) == ["kept-undrafted-clash-overruled"])
        #expect(queue.items.first?.reprepMode == nil)
    }

    // The other half of what the deleted line got wrong: it promised a contact hunt on a show whose
    // contact a probe had already found. The card now says the run will only write the draft, and the
    // queue the run receives says the same.
    @Test func aProbedShowsCardSaysTheRunOnlyWritesTheDraft() throws {
        let ctx = try context()
        let p = show(ctx, "kept-undrafted-already-probed", status: .queued, probedEmail: "jane@aurora.org")
        try ctx.save()

        let card = QueueItem(p)
        #expect(card.isAwaitingPrepRun)
        #expect(card.nextPrepRun == .draftOnly)

        let queue = PrepQueueService.buildQueue(from: ctx, generatedAt: "now", today: today,
                                                venueHistory: emptyHistory)
        #expect(queue.items.first?.reprepMode == PrepQueueBuilder.draftOnlyMode)
    }

    // A probe that stored no address found nothing, so the hunt is still to do. Without this the
    // draft-only case above would pass for any probed show at all.
    @Test func aProbeThatFoundNobodyStillLeavesTheHuntToDo() throws {
        let ctx = try context()
        let p = show(ctx, "kept-undrafted-probe-found-nobody", status: .queued, probedEmail: "")
        try ctx.save()

        #expect(QueueItem(p).nextPrepRun == .contactsAndDraft)
        let queue = PrepQueueService.buildQueue(from: ctx, generatedAt: "now", today: today,
                                                venueHistory: emptyHistory)
        #expect(queue.items.first?.reprepMode == nil)
    }

    // #1940 landed the same week and moved a show with a queued re-prep out of Review and under Prep
    // alone. The card's accessor has to agree with that rather than an older rule: a drafted show with a
    // re-prep asked for IS awaiting a run, and a drafted show with nothing asked for is not.
    @Test func aQueuedReprepIsAwaitingARunAndAPlainDraftedShowIsNot() throws {
        let ctx = try context()
        let asked = show(ctx, "drafted-redraft-asked-for", status: .drafted, hasDraft: true,
                         draftRequested: true)
        let settled = show(ctx, "approved-nothing-asked-for", status: .approved, hasDraft: true)
        try ctx.save()

        #expect(QueueItem(asked).isAwaitingPrepRun)
        #expect(QueueItem(asked).nextPrepRun == .draftOnly)
        #expect(!QueueItem(settled).isAwaitingPrepRun)
        // The same flag decides both surfaces, so the badge and the accessor cannot disagree.
        #expect(QueueItem(asked).isReprepQueued)
        #expect(!QueueItem(settled).isReprepQueued)
    }

    // A clash outranks a re-prep request on the card exactly as it does in the run, which is the state
    // QueueModel.reprepOffer already says out loud rather than confirming work that cannot happen.
    @Test func aClashOutranksAReprepRequest() throws {
        let ctx = try context()
        let p = show(ctx, "drafted-redraft-asked-for-on-a-blocked-night", status: .drafted, hasDraft: true,
                     draftRequested: true, conflicted: true)
        try ctx.save()

        #expect(QueueItem(p).nextPrepRun == .notQueued)
        let queue = PrepQueueService.buildQueue(from: ctx, generatedAt: "now", today: today,
                                                venueHistory: emptyHistory)
        #expect(queue.items.isEmpty)
    }

    // MARK: - And the card asks it rather than the raw field

    // #2007's "Prep manually" control is the one surface on the card that already answered part of this
    // question for itself. It now asks the accessor for the clash half, so the three states it draws and
    // the run's own refusal can never drift apart.
    @Test func theManualPrepControlBlocksExactlyWhenTheRunWouldRefuse() throws {
        let ctx = try context()
        let free = show(ctx, "kept-undrafted", status: .queued)
        let blocked = show(ctx, "kept-undrafted-on-a-blocked-night", status: .queued, conflicted: true)
        let drafted = show(ctx, "kept-with-a-draft", status: .queued, hasDraft: true)
        try ctx.save()

        #expect(QueueModel.manualPrepOffer(for: QueueItem(free)) == .shown)
        #expect(QueueModel.manualPrepOffer(for: QueueItem(drafted)) == .hidden)
        guard case .blocked = QueueModel.manualPrepOffer(for: QueueItem(blocked)) else {
            Issue.record("a clashed show must offer manual prep in the blocked state, with its reason")
            return
        }
    }
}
