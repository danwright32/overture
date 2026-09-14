import Testing
import Foundation
import SwiftData

// #3651 (milestone #80, Phase 1): finding the row behind a press on the Reached out list.
//
// WHAT THIS EXISTS TO STOP. `RenderData.reachedOut` holds live `Prospect` and `Recipient` references
// across a render snapshot, and `LaunchMigrations` runs deleting passes on the main context with a
// window open, as do `DuplicateContactMerge`, `SameNightTitleVariantMerge`, `DriftedRunMerge` and
// `ContactRefusal`. Reading a property off a deleted model is a crash, not a stale row.
//
// AND WHY A KEY ALONE IS WORSE THAN THE CRASH. `Prospect.naturalKey` is `@Attribute(.unique)` and it is
// MUTABLE, reassigned by five sites, one of which is a survivor adopting the key of the loser it just
// deleted (`SameNightTitleVariantMerge:187`). Because the column is unique, a key-only lookup finds
// EXACTLY ONE row and returns it with nothing to report, so a press meant for a merged-away show lands
// silently on the survivor. That is L145, L75 and L15 at once, and under this milestone's hard
// constraint 2 a wrong-row write is worse than a refusal.
//
// So the snapshot carries `persistentModelID` as its identity and the key as a WITNESS, and the resolver
// refuses whenever the two disagree.
//
// THREE REFUSALS, THREE MESSAGES (L11), because they have three different causes and only one of them is
// "the show is gone". Two outcomes given distinct wording but the same consequence are one outcome in
// practice, and two that share wording are worse (L260).
@MainActor
@Suite("Finding the row behind a Reached out press (#3651)")
struct ReachedOutSnapshotTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    @discardableResult
    private func makeShow(_ ctx: ModelContext, key: String, org: String = "Ensemble") -> Prospect {
        let p = Prospect(naturalKey: key, groupName: org, discipline: "music", venue: "Weill Recital Hall",
                         performanceDate: "2026-10-01", sourceListingURL: nil, priorRelationship: "none",
                         production: "presenter", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 5, tier: "mid", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .contacted)
        ctx.insert(p)
        return p
    }

    @discardableResult
    private func addContact(_ ctx: ModelContext, to p: Prospect, id: String) -> Recipient {
        let r = Recipient(id: id, email: "\(id)@example.com", name: "Contact",
                          role: "programming", provenance: .presenter)
        r.prospect = p
        ctx.insert(r)
        return r
    }

    // THE ORDINARY CASE, and it is here first because every refusal below is only meaningful if the
    // resolver can find a row that really is there (L171).
    @Test func aLiveRowResolvesToItself() throws {
        let ctx = ModelContext(try container())
        let show = makeShow(ctx, key: "show-1")
        let contact = addContact(ctx, to: show, id: "contact-1")
        try ctx.save()

        let snapshot = ReachedOutSnapshot(show: show, contact: contact, next: Date())
        let found = ReachedOutSnapshot.resolve(snapshot, in: [show])

        guard case .found(let p, let r) = found else {
            Issue.record("a live row did not resolve, so every refusal below proves nothing: \(found)")
            return
        }
        #expect(p.naturalKey == "show-1")
        #expect(r.id == "contact-1")
    }

    // 1. DELETED. The row is not there at all.
    @Test func aDeletedShowIsRefusedAsGone() throws {
        let ctx = ModelContext(try container())
        let show = makeShow(ctx, key: "show-1")
        let contact = addContact(ctx, to: show, id: "contact-1")
        try ctx.save()
        let snapshot = ReachedOutSnapshot(show: show, contact: contact, next: Date())

        // The press arrives against a live list that no longer holds it.
        let outcome = ReachedOutSnapshot.resolve(snapshot, in: [])

        #expect(outcome == .gone,
                Comment(rawValue: "a show missing from the live list resolved as \(outcome) rather than "
                        + "gone, so a press on a deleted row does something other than refuse."))
    }

    // 2. RE-KEYED, and this is the one a key-only lookup gets silently WRONG. The show Dan pressed was
    // merged away and a DIFFERENT show adopted its key, which is what SameNightTitleVariantMerge does.
    @Test func aShowWhoseKeyAnotherRowAdoptedIsRefusedRatherThanResolvedOntoIt() throws {
        let ctx = ModelContext(try container())
        let merged = makeShow(ctx, key: "show-1", org: "The one Dan pressed")
        let contact = addContact(ctx, to: merged, id: "contact-1")
        let survivor = makeShow(ctx, key: "show-2", org: "A different show entirely")
        addContact(ctx, to: survivor, id: "contact-2")
        try ctx.save()

        let snapshot = ReachedOutSnapshot(show: merged, contact: contact, next: Date())
        // The merge: the loser goes, and the survivor adopts its key.
        survivor.naturalKey = "show-1"
        try ctx.save()

        let outcome = ReachedOutSnapshot.resolve(snapshot, in: [survivor])

        #expect(outcome == .gone,
                Comment(rawValue: "resolved as \(outcome). A snapshot whose show was merged away must not "
                        + "find the survivor that adopted its key: `naturalKey` is unique, so a key-only "
                        + "lookup returns exactly one row with nothing to report and the press lands on a "
                        + "different show (L145, L75, L15)."))
    }

    // 2b. RE-KEYED IN PLACE, which is the OTHER half and the one `.reKeyed` exists for. The show Dan
    // pressed is still alive and still the same row, and its own key moved underneath it, which is what
    // `RunNightDrop` does when a run is re-keyed onto its next night. Resolving by identity finds it; the
    // key witness is what says the row is no longer the thing the list drew.
    @Test func aShowRekeyedInPlaceIsRefusedAsMovedRatherThanActedOn() throws {
        let ctx = ModelContext(try container())
        let show = makeShow(ctx, key: "show-1")
        let contact = addContact(ctx, to: show, id: "contact-1")
        try ctx.save()
        let snapshot = ReachedOutSnapshot(show: show, contact: contact, next: Date())

        // The night drop: same row, new key.
        show.naturalKey = "show-1-night-2"
        try ctx.save()

        let outcome = ReachedOutSnapshot.resolve(snapshot, in: [show])

        #expect(outcome == .reKeyed,
                Comment(rawValue: "resolved as \(outcome). The row is alive and its key has moved, so it "
                        + "is not the show the list drew and acting on it would write to a night Dan did "
                        + "not press. That is its own refusal, never \"could not find that show\"."))
    }

    // 3. THE CONTACT went, and the show did not. A merge or a refusal took the recipient.
    @Test func aShowWhoseContactWentIsRefusedForThatReasonAndNotAsMissing() throws {
        let ctx = ModelContext(try container())
        let show = makeShow(ctx, key: "show-1")
        let contact = addContact(ctx, to: show, id: "contact-1")
        try ctx.save()
        let snapshot = ReachedOutSnapshot(show: show, contact: contact, next: Date())

        ctx.delete(contact)
        try ctx.save()

        let outcome = ReachedOutSnapshot.resolve(snapshot, in: [show])

        #expect(outcome == .contactGone,
                Comment(rawValue: "resolved as \(outcome). The show is still there and its contact is "
                        + "not, which is a different thing from the show being gone and needs its own "
                        + "sentence, or the two causes share one message and neither can be acted on "
                        + "(L11, L260)."))
    }

    // The three refusals must not share a sentence, which is the whole reason they are three cases.
    @Test func eachRefusalSaysSomethingDifferent() {
        let said = [ReachedOutSnapshot.Outcome.gone,
                    .reKeyed,
                    .contactGone].map { $0.sentence(org: "Ensemble") }
        #expect(Set(said).count == said.count,
                Comment(rawValue: "two of the three refusals say the same thing: \(said). Two outcomes "
                        + "with distinct causes and one message are one outcome in practice (L11, L260)."))
        for sentence in said {
            #expect(!sentence.isEmpty, "a refusal with no wording cannot be acted on")
        }
    }

    // THE WIRING, because a resolver nothing calls is a field only ever written (L46). The close-out
    // control on the Reached out row is the site that used to capture a live model in a button closure
    // and read it at press time.
    @Test func theCloseOutPressGoesThroughTheResolver() throws {
        let view = SourceGuardHelper.source("Overture/UI/QueueView.swift")
        #expect(view.contains("private func closeOut(_ row: ReachedOutSnapshot, as outcome: ShowOutcome)"),
                Comment(rawValue: "closing a show out no longer takes a snapshot, so it is reading a "
                        + "model captured in a button closure at press time (#3651)."))
        let body = try #require(SourceGuardHelper.bodyOfFunction(named: "closeOut", in: view))
        #expect(body.contains("ReachedOutSnapshot.resolve(row, in: prospects)"),
                Comment(rawValue: "the press does not resolve, or resolves against something other than "
                        + "the view's own live query. Resolving against the pass's captured scope walks "
                        + "model references the pass took minutes ago and faults a property on each, "
                        + "which is the same crash moved one level out."))
        #expect(body.contains("resolved.sentence(org: row.org)"),
                "a refusal is not said, so a press that changed nothing looks exactly like one that worked")
    }

}
