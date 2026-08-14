import Testing
import Foundation
import SwiftData

// #2662: Dan, 2026-08-13, striking a run of contacts off the send list. "It's working, but each one
// takes a while. It should be a lot quicker and basically instant." And: "if I go too quickly I get the
// spinning wheel."
//
// Two costs live in the strike path alone, and this suite is about those two. The third, the queue
// rebuilding every card on the main thread on each save, is #2417's and #2598's and is not touched here.
//
//   1. TWO SAVES PER STRIKE. `ContactRefusal.refuse` ended in its own `try? context.save()`, and the
//      caller then saved again for the removal. Every SwiftData save invalidates the queue's @Query, so
//      one click paid the whole rebuild twice. Nothing between the two needs the first to be durable.
//   2. THE WHOLE TABLE, PER STRIKE. `refuse` fetched every `RefusedContactAddress` and linear scanned it
//      in memory to test for a row whose id it had already computed. That table only grows, and it grows
//      fastest exactly while Dan is doing what he was doing: striking many contacts in a row. The file
//      already knew this was wrong: its own comment thirty lines below says the ledger is read once per
//      pass and handed to the readers because "a per-row version would re-fetch the whole table for every
//      card drawn", and the writer then did the per-row version.
//
// WHAT IS NOT CLAIMED HERE. No before-and-after timing was taken on the live store, so this suite asserts
// the two defects are gone and does not assert how much faster a strike feels (L102, L107). Whether
// halving the rebuilds is what Dan notices is a question only #2417 and #2598 can answer, since the
// rebuild itself is theirs.
@MainActor
@Suite("What one strike costs (#2662)")
struct StrikeCostTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, RefusedContactAddress.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func show(_ ctx: ModelContext, key: String = "k") -> Prospect {
        let p = Prospect(naturalKey: key, groupName: "54 Sings Shuffle Along", discipline: "theater",
                         venue: "54 Below", performanceDate: "2026-08-17", sourceListingURL: nil,
                         websiteURL: nil, priorRelationship: "none", production: "unknown",
                         profile: "neutral", coverage: "unknown", fitScore: 5, tier: "mid",
                         fitReason: "", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil, status: .new)
        ctx.insert(p)
        return p
    }

    private func rows(_ ctx: ModelContext) throws -> [RefusedContactAddress] {
        try ctx.fetch(FetchDescriptor<RefusedContactAddress>())
    }

    // MARK: - One commit per strike

    // The defect stated as behaviour rather than as a line of code: after recording a refusal, the work
    // is still UNCOMMITTED, so the caller's own save is the only one and the queue rebuilds once. If
    // `refuse` commits for itself there is nothing left pending and this reads false.
    @Test func recordingARefusalDoesNotCommitByItself() throws {
        let ctx = ModelContext(try container())
        _ = show(ctx)
        try ctx.save()

        ContactRefusal.refuse(email: "cast@example.com", scope: .show("k"), in: ctx)
        #expect(ctx.hasChanges, "the refusal committed for itself, so the caller's save is a second one")
    }

    // The same for the reversal, which had the identical shape.
    @Test func allowingAnAddressBackDoesNotCommitByItself() throws {
        let ctx = ModelContext(try container())
        ContactRefusal.refuse(email: "cast@example.com", scope: .show("k"), in: ctx)
        try ctx.save()

        ContactRefusal.allow(email: "cast@example.com", showKey: "k", orgKey: nil, in: ctx)
        #expect(ctx.hasChanges, "the reversal committed for itself")
    }

    // And a strike still LANDS, which is the risk the change carries: a refusal that no longer saves
    // itself is lost entirely if its caller does not commit. Measured against the store rather than the
    // context, by reading it back through a context that never saw the insert.
    @Test func aStrikeStillReachesTheStore() throws {
        let box = try container()
        let ctx = ModelContext(box)
        ContactRefusal.refuse(email: "cast@example.com", scope: .show("k"), in: ctx)
        try ctx.save()

        let reader = ModelContext(box)
        #expect(try rows(reader).map(\.handleKey) == ["cast@example.com"])
    }

    // MARK: - Every caller commits

    // The entry point that had NO save of its own and relied entirely on `refuse` committing for it. It is
    // the one that would silently stop working, and unlike the others it has no visible second write to
    // notice the loss by: Dan strikes an inherited address, is told it was removed, and the strike is gone
    // at the next launch.
    @Test func strikingAnInheritedAddressStillPersists() throws {
        let box = try container()
        let ctx = ModelContext(box)
        let p = show(ctx)
        p.presenter = "Feinstein's/54 Below"
        try ctx.save()

        let item = QueueItem(p)
        ProspectMutations.removeInheritedAddress(item, email: "boxoffice@54below.example",
                                                 prospects: [p], context: ctx,
                                                 feedback: ActionFeedback())

        let reader = ModelContext(box)
        #expect(try rows(reader).map(\.handleKey) == ["boxoffice@54below.example"])
    }

    // The strike Dan actually made tonight, end to end through the draft-review panel's own entry point:
    // the refusal is recorded AND the contact is gone, both durable, on the caller's single save.
    @Test func strikingAContactRecordsAndRemovesItInOneCommit() throws {
        let box = try container()
        let ctx = ModelContext(box)
        let p = show(ctx)
        let r = Recipient(id: "cast@example.com", email: "cast@example.com", name: "A Performer",
                          provenance: .performer)
        p.setRecipients([r])
        try ctx.save()

        ProspectMutations.removeRecipientManually(QueueItem(p), "cast@example.com", "A Performer",
                                                  prospects: [p], context: ctx,
                                                  feedback: ActionFeedback())
        #expect(!ctx.hasChanges, "the caller's save did not commit everything the strike wrote")

        let reader = ModelContext(box)
        #expect(try rows(reader).map(\.handleKey) == ["cast@example.com"])
        #expect(try reader.fetch(FetchDescriptor<Prospect>()).first?.recipients.isEmpty == true)
    }

    // MARK: - Looking a refusal up by the id it already has

    // Idempotence is the behaviour the lookup exists for, and it has to hold with a table big enough that
    // reading all of it is the cost this issue is about. A hundred unrelated rows is far past the size
    // where a linear scan per strike is defensible, and the answer must be identical either way.
    @Test func aRepeatedStrikeIsStillOneRefusalWithACrowdedTable() throws {
        let ctx = ModelContext(try container())
        for i in 0..<100 {
            ContactRefusal.refuse(email: "other\(i)@example.com", scope: .show("other"), in: ctx)
        }
        try ctx.save()

        ContactRefusal.refuse(email: "cast@example.com", scope: .show("k"), in: ctx)
        ContactRefusal.refuse(email: "CAST@Example.com ", scope: .show("k"), in: ctx)
        try ctx.save()

        let struck = try rows(ctx).filter { $0.scopeId == "k" }
        #expect(struck.count == 1)
        #expect(struck.first?.handleKey == "cast@example.com")
    }

    // And the lookup must not confuse neighbours: the same address struck for a different show, and a
    // different address struck for this one, are different refusals and neither answers for the other.
    @Test func theLookupTellsNeighbouringRefusalsApart() throws {
        let ctx = ModelContext(try container())
        ContactRefusal.refuse(email: "cast@example.com", scope: .show("other-show"), in: ctx)
        ContactRefusal.refuse(email: "someone@example.com", scope: .show("k"), in: ctx)
        try ctx.save()

        ContactRefusal.refuse(email: "cast@example.com", scope: .show("k"), in: ctx)
        try ctx.save()

        #expect(try rows(ctx).count == 3)
        let ledger = ContactRefusal.ledger(in: ctx)
        #expect(ledger.isRefused(email: "cast@example.com", showKey: "k", orgKey: nil))
        #expect(ledger.isRefused(email: "cast@example.com", showKey: "other-show", orgKey: nil))
        #expect(!ledger.isRefused(email: "nobody@example.com", showKey: "k", orgKey: nil))
    }

    // The reversal reads by id too, and it clears BOTH levels, which is the contract #2392 gave it: adding
    // an address back is an explicit statement that it is fine, so an organisation-level strike must not be
    // left standing behind a contact now sitting on the card.
    @Test func theReversalStillClearsBothLevelsWithACrowdedTable() throws {
        let ctx = ModelContext(try container())
        for i in 0..<100 {
            ContactRefusal.refuse(email: "other\(i)@example.com", scope: .show("other"), in: ctx)
        }
        ContactRefusal.refuse(email: "cast@example.com", scope: .show("k"), in: ctx)
        ContactRefusal.refuse(email: "cast@example.com", scope: .organisation("org"), in: ctx)
        try ctx.save()

        ContactRefusal.allow(email: "cast@example.com", showKey: "k", orgKey: "org", in: ctx)
        try ctx.save()

        let ledger = ContactRefusal.ledger(in: ctx)
        #expect(!ledger.isRefused(email: "cast@example.com", showKey: "k", orgKey: "org"))
        #expect(try rows(ctx).count == 100)
    }
}
