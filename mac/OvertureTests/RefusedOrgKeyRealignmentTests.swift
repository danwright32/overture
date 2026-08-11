import Testing
import Foundation
import SwiftData

// #2451: the protective half of the realignment, where a merge would be a data loss.
//
// The thing under test is not really "does it move a row", it is "can it ever remove one". A refusal
// ledger one row shorter is indistinguishable from no refusal at all (L42): nothing on any screen says
// the strike is gone, the address simply comes back, and the prep run pays to rediscover it. That is
// #2392 leading to #2421, which is the loss this whole milestone exists to prevent.
//
// So the collision case gets the most attention here, because it is the one case where the shipped
// answer-shaped pass would have deleted.
@MainActor
@Suite("A refusal is re-keyed and never deleted (#2451)")
struct RefusedOrgKeyRealignmentTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(
            for: Schema([Prospect.self, Recipient.self, RefusedContactAddress.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private let struckAt = Date(timeIntervalSince1970: 1_800_000_000)

    // Inserts a refusal holding a scope key SPELLED OUT rather than computed, which is the whole point:
    // it stands for a row a previous build wrote under the old fold.
    @discardableResult
    private func refusal(_ ctx: ModelContext, scopeRaw: String, scopeId: String,
                         handle: String, at: Date? = nil) -> RefusedContactAddress {
        let row = RefusedContactAddress(
            id: ContactRefusal.rowId(scopeRaw: scopeRaw, scopeId: scopeId, handleKey: handle),
            scopeRaw: scopeRaw, scopeId: scopeId, handleKey: handle, refusedAt: at ?? struckAt)
        ctx.insert(row)
        try? ctx.save()
        return row
    }

    private func rows(_ ctx: ModelContext) throws -> [RefusedContactAddress] {
        try ctx.fetch(FetchDescriptor<RefusedContactAddress>()).sorted { $0.id < $1.id }
    }

    // The plain case, and the one this ships for: a strike filed under "presenter:the green room 42"
    // before the fold learned that an article is not part of an organisation's name.
    @Test func aRefusalUnderTheOldSpellingIsMovedOntoTheNewKey() throws {
        let ctx = ModelContext(try container())
        refusal(ctx, scopeRaw: ContactRefusal.Scope.organisationRaw,
                scopeId: "presenter:the green room 42", handle: "info@example.test")

        let summary = RefusedOrgKeyRealignment.run(in: ctx)

        #expect(summary.rekeyed == 1)
        #expect(summary.collisionsKeptBoth == 0)
        #expect(try rows(ctx).map(\.scopeId) == [OrgKey.stored(for: "The Green Room 42")])
    }

    // And it still ANSWERS afterwards, which is the thing that matters. A row that moved but no longer
    // matched what the importer asks would be a refusal that reads as intact and refuses nothing.
    @Test func theMovedRefusalStillReadsAsRefused() throws {
        let ctx = ModelContext(try container())
        refusal(ctx, scopeRaw: ContactRefusal.Scope.organisationRaw,
                scopeId: "presenter:the green room 42", handle: "info@example.test")
        RefusedOrgKeyRealignment.run(in: ctx)

        let ledger = ContactRefusal.ledger(from: try rows(ctx))
        #expect(ledger.isRefused(email: "info@example.test", showKey: nil,
                                 orgKey: OrgKey.stored(for: "The Green Room 42")))
    }

    // THE CASE THE ANSWER-SHAPED PASS WOULD HAVE DELETED. Both spellings of one organisation carry the
    // same struck address, so the re-key would land on a row that already exists. Two refusals can only
    // ever mean refuse, so both are kept, each under its own key, and the collision is counted.
    @Test func aCollisionKeepsBothRefusalsRatherThanMergingThem() throws {
        let ctx = ModelContext(try container())
        let target = OrgKey.stored(for: "The Green Room 42")!
        refusal(ctx, scopeRaw: ContactRefusal.Scope.organisationRaw,
                scopeId: "presenter:the green room 42", handle: "info@example.test")
        refusal(ctx, scopeRaw: ContactRefusal.Scope.organisationRaw,
                scopeId: target, handle: "info@example.test")

        let summary = RefusedOrgKeyRealignment.run(in: ctx)

        #expect(summary.collisionsKeptBoth == 1)
        #expect(summary.rekeyed == 0)
        #expect(try rows(ctx).count == 2, "a refusal was lost to a collision")
        #expect(Set(try rows(ctx).map(\.scopeId)) == ["presenter:the green room 42", target])
    }

    // The stranded row goes on refusing under the spelling it was written with, which costs nothing,
    // because a refusal only ever ADDS a refusal. This is the sentence that makes "keep both" honest
    // rather than merely conservative.
    @Test func bothSidesOfACollisionStillRefuse() throws {
        let ctx = ModelContext(try container())
        let target = OrgKey.stored(for: "The Green Room 42")!
        refusal(ctx, scopeRaw: ContactRefusal.Scope.organisationRaw,
                scopeId: "presenter:the green room 42", handle: "info@example.test")
        refusal(ctx, scopeRaw: ContactRefusal.Scope.organisationRaw,
                scopeId: target, handle: "info@example.test")
        RefusedOrgKeyRealignment.run(in: ctx)

        let ledger = ContactRefusal.ledger(from: try rows(ctx))
        #expect(ledger.isRefused(email: "info@example.test", showKey: nil, orgKey: target))
        #expect(ledger.isRefused(email: "info@example.test", showKey: nil,
                                 orgKey: "presenter:the green room 42"))
    }

    // A SHOW-scoped refusal is not an organisation key at all: `scopeId` holds a prospect's natural key
    // there. Two independent conditions keep it out (the scope, and the key namespace), because a check
    // whose two sides come from one lookup can only prove that lookup is self-consistent (L70).
    @Test func aShowScopedRefusalIsNeverTouched() throws {
        let ctx = ModelContext(try container())
        let showKey = "the green room 42|2026-09-12|the green room 42"
        refusal(ctx, scopeRaw: ContactRefusal.Scope.showRaw, scopeId: showKey,
                handle: "info@example.test")

        #expect(RefusedOrgKeyRealignment.run(in: ctx) == RefusedOrgKeyRealignment.Summary())
        #expect(try rows(ctx).map(\.scopeId) == [showKey])
    }

    // An organisation-scoped row whose key is not in the namespace (a row a future writer files another
    // way) keeps the key it has and is COUNTED, rather than being silently skipped. A fold that failed
    // must not cost a refusal, and it must not be invisible either.
    @Test func aRowWhoseKeyNoLongerFoldsIsKeptAndCounted() throws {
        let ctx = ModelContext(try container())
        refusal(ctx, scopeRaw: ContactRefusal.Scope.organisationRaw, scopeId: "not-a-presenter-key",
                handle: "info@example.test")

        let summary = RefusedOrgKeyRealignment.run(in: ctx)

        #expect(summary.unkeyable == 1)
        #expect(summary.rekeyed == 0)
        #expect(try rows(ctx).map(\.scopeId) == ["not-a-presenter-key"])
    }

    // A row already on its computed key is untouched, which is also what makes a second pass a no-op.
    @Test func aSecondPassDoesNothing() throws {
        let ctx = ModelContext(try container())
        refusal(ctx, scopeRaw: ContactRefusal.Scope.organisationRaw,
                scopeId: "presenter:the green room 42", handle: "info@example.test")
        refusal(ctx, scopeRaw: ContactRefusal.Scope.organisationRaw,
                scopeId: "presenter:the players theatre", handle: "box@example.test")

        #expect(RefusedOrgKeyRealignment.run(in: ctx).rekeyed == 2)
        #expect(RefusedOrgKeyRealignment.run(in: ctx) == RefusedOrgKeyRealignment.Summary())
        #expect(try rows(ctx).count == 2)
    }

    // An empty ledger is an empty summary, not a crash and not a pass over rows that are not there.
    @Test func anEmptyLedgerIsANoOp() throws {
        let ctx = ModelContext(try container())
        #expect(RefusedOrgKeyRealignment.run(in: ctx) == RefusedOrgKeyRealignment.Summary())
    }

    // The row's `id` is UNIQUE and derived from the scope key, so a re-key rewrites it too. A pass that
    // moved `scopeId` and left `id` behind would leave a row whose identity no longer describes it, and
    // `ContactRefusal.refuse` would then write a SECOND row for the same strike.
    @Test func theRowIdIsRebuiltFromTheNewKey() throws {
        let ctx = ModelContext(try container())
        refusal(ctx, scopeRaw: ContactRefusal.Scope.organisationRaw,
                scopeId: "presenter:the green room 42", handle: "info@example.test")
        RefusedOrgKeyRealignment.run(in: ctx)

        let row = try #require(try rows(ctx).first)
        #expect(row.id == ContactRefusal.rowId(scopeRaw: row.scopeRaw, scopeId: row.scopeId,
                                               handleKey: row.handleKey))
        #expect(!row.id.contains("\u{1}"), "a row was left parked mid-pass")
    }

    // Two rows moving at once, where one wants the key the other is vacating. `id` is unique, so for as
    // long as both held it the store would refuse the write; the parking pass is what makes the order
    // the fetch happened to return them in irrelevant.
    @Test func twoRefusalsSwappingKeysBothLand() throws {
        let ctx = ModelContext(try container())
        // "presenter:the a" wants "presenter:a", which "presenter:the the a" would never want; the pair
        // below is the chained shape: the second row's target is the first row's current key.
        refusal(ctx, scopeRaw: ContactRefusal.Scope.organisationRaw,
                scopeId: "presenter:the a", handle: "one@example.test")
        refusal(ctx, scopeRaw: ContactRefusal.Scope.organisationRaw,
                scopeId: "presenter:the the a", handle: "one@example.test")

        let summary = RefusedOrgKeyRealignment.run(in: ctx)

        #expect(try rows(ctx).count == 2, "a refusal was lost to a chained re-key")
        #expect(summary.rekeyed + summary.collisionsKeptBoth == 2)
        #expect(Set(try rows(ctx).map(\.id)).count == 2)
    }
}

// The structural half of the claim, which no behavioural test can make: this path cannot delete,
// because there is nothing in it that deletes.
//
// Behaviour tests prove what the pass does on the cases somebody thought of. A refusal lost on the case
// nobody thought of is exactly the failure L42 describes, and the only guard against it is that the
// file holds no delete at all. Seen red first by adding a `context.delete(row)` line to the pass.
@Suite("The protective path is structurally unable to delete (#2451)")
struct RefusalRealignmentNeverDeletesTests {

    // Read as CODE rather than as raw text: the comments in these files necessarily discuss deleting
    // and the counter this path must not have, and a guard that could not tell the paragraph explaining
    // the rule from the line breaking it would have to be written around its own explanation.
    static func code(of pass: String) -> String {
        let text = SourceGuardHelper.source("Overture/Domain/\(pass).swift")
        return SwiftSource.scannableLines(in: text, skipping: .scaffolding)
            .map(\.code).joined(separator: "\n")
    }

    @Test func theFileHoldsNoDelete() {
        let code = Self.code(of: "RefusedOrgKeyRealignment")
        #expect(!code.isEmpty, "the guard read no source, so it checked nothing")
        #expect(!code.contains("context.delete"),
                "the protective realignment can delete a refusal, which is the one thing it exists not to do")
        #expect(!code.contains(".delete("),
                "the protective realignment can delete a refusal, which is the one thing it exists not to do")
    }

    // And no counter that could hold a number for it. A `duplicatesDeleted` reading zero is a claim that
    // deleting is a thing this path does, which is how the next author decides it may.
    @Test func theSummaryHasNoDeletionCounter() {
        #expect(!Self.code(of: "RefusedOrgKeyRealignment").contains("duplicatesDeleted"),
                "the protective summary declares a deletion counter")
    }

    // The classification itself, so a pass cannot be declared protective in one place and behave like an
    // answer pass in another.
    @Test func theRefusalTableIsDeclaredProtective() {
        let refusal = KeyRealignment.coverage.first {
            $0.model == "RefusedContactAddress" && $0.property == "scopeId"
        }
        #expect(refusal?.tableClass == .protective)
    }

    // The OTHER case, read positively rather than by exclusion. A classification only one side of the
    // guard ever consults is decoration: `.answer` would sit there being true of three passes while
    // nothing checked that any of them still MERGES, so a pass that quietly lost its merge, or a
    // protective one mislabelled as an answer, would read exactly the same (L90).
    @Test func everyAnswerPassActuallyMerges() {
        let answers = Set(KeyRealignment.coverage.filter { $0.tableClass == .answer }.map(\.pass))
        #expect(!answers.isEmpty, "no pass is declared answer-shaped, so this guard checks nothing")
        for pass in answers.sorted() {
            let code = Self.code(of: pass)
            #expect(!code.isEmpty, "no source found for the answer-shaped pass \(pass)")
            #expect(code.contains("duplicatesDeleted"), Comment(rawValue:
                    "\(pass) is declared answer-shaped but counts no merge, so the classification says "
                    + "nothing about how it behaves"))
            #expect(code.contains(".delete("), Comment(rawValue:
                    "\(pass) is declared answer-shaped but never merges, which is the protective "
                    + "behaviour wearing the wrong label"))
        }
    }

    // Every OTHER pass declared protective gets the same two structural checks, so a second protective
    // table added later cannot quietly inherit the answer-shaped semantics.
    @Test func everyProtectivePassHoldsNoDelete() {
        let protective = Set(KeyRealignment.coverage.filter { $0.tableClass == .protective }
            .map(\.pass))
        #expect(!protective.isEmpty, "no pass is declared protective, so this guard checks nothing")
        for pass in protective.sorted() {
            let code = Self.code(of: pass)
            #expect(!code.isEmpty, "no source found for the protective pass \(pass)")
            #expect(!code.contains(".delete("), "\(pass) is declared protective and can delete a row")
            #expect(!code.contains("duplicatesDeleted"),
                    "\(pass) is declared protective and declares a deletion counter")
        }
    }
}
