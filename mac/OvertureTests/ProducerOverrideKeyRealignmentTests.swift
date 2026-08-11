import Testing
import Foundation
import SwiftData

// #2451: the answer-shaped half of the realignment, over Dan's own producer/house corrections.
//
// These two tables keep no raw name, so the pass re-folds the key itself. Every row below is spelled
// out rather than computed, which is the point: it stands for a row an earlier build wrote before the
// gate's fold learned something. The bracketed one is the real shape, from #1764: the gate learned to
// drop a bracket whose contents hold a comma, and every correction written before that day carries the
// bracket in its key.
@MainActor
@Suite("Realigning Dan's producer corrections onto today's gate fold (#2451)")
struct ProducerOverrideKeyRealignmentTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(
            for: Schema([Prospect.self, Recipient.self, PromotedProducer.self, DemotedHouse.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private let older = Date(timeIntervalSince1970: 1_800_000_000)
    private let newer = Date(timeIntervalSince1970: 1_800_090_000)

    // The live string from #1764, whose key carried a bracket until the gate learned to drop one.
    private let bracketed = "the golden hour series (curated with jalopy theatre and others)"

    private func promoted(_ ctx: ModelContext) throws -> [String] {
        try ctx.fetch(FetchDescriptor<PromotedProducer>()).map(\.orgKey).sorted()
    }

    private func demoted(_ ctx: ModelContext) throws -> [String] {
        try ctx.fetch(FetchDescriptor<DemotedHouse>()).map(\.orgKey).sorted()
    }

    @Test func aPromotionUnderTheOldFoldIsMovedOntoTheNewKey() throws {
        let ctx = ModelContext(try container())
        ctx.insert(PromotedProducer(orgKey: bracketed, addedAt: older))
        try ctx.save()

        let summary = ProducerOverrideKeyRealignment.run(in: ctx)

        #expect(summary.rekeyed == 1)
        #expect(summary.duplicatesDeleted == 0)
        #expect(try promoted(ctx) == [ProducerGate.key(bracketed)!])
    }

    @Test func aDemotionUnderTheOldFoldIsMovedToo() throws {
        let ctx = ModelContext(try container())
        ctx.insert(DemotedHouse(orgKey: bracketed, addedAt: older))
        try ctx.save()

        #expect(ProducerOverrideKeyRealignment.run(in: ctx).rekeyed == 1)
        #expect(try demoted(ctx) == [ProducerGate.key(bracketed)!])
    }

    // One correction written twice is one correction. The newest keeps the key, and the redundant row
    // goes, which is the semantics a REFUSAL may not have and a verdict may.
    @Test func oneCorrectionWrittenTwiceCollapses() throws {
        let ctx = ModelContext(try container())
        ctx.insert(PromotedProducer(orgKey: bracketed, addedAt: older))
        ctx.insert(PromotedProducer(orgKey: ProducerGate.key(bracketed)!, addedAt: newer))
        try ctx.save()

        let summary = ProducerOverrideKeyRealignment.run(in: ctx)

        #expect(summary.duplicatesDeleted == 1)
        #expect(try promoted(ctx) == [ProducerGate.key(bracketed)!])
    }

    // THE FAILURE PATH. A promotion and a demotion landing on ONE key is not a duplicate, it is Dan
    // having said two opposite things about one organisation, and mutual exclusion at write time cannot
    // see it coming because the collision is created by the re-key. A launch pass may not pick a side,
    // so neither row moves and the gate reads exactly what it read before.
    @Test func aPromotionAndADemotionOnOneKeyAreBothLeftAlone() throws {
        let ctx = ModelContext(try container())
        ctx.insert(PromotedProducer(orgKey: bracketed, addedAt: older))
        ctx.insert(DemotedHouse(orgKey: ProducerGate.key(bracketed)!, addedAt: newer))
        try ctx.save()

        let summary = ProducerOverrideKeyRealignment.run(in: ctx)

        #expect(summary.conflictsDeferred == 1)
        #expect(summary.rekeyed == 0)
        #expect(summary.duplicatesDeleted == 0)
        #expect(try promoted(ctx) == [bracketed])
        #expect(try demoted(ctx) == [ProducerGate.key(bracketed)!])
    }

    // A correction on a key the gate's fold no longer computes keeps the key it has, rather than being
    // moved somewhere or removed. His judgment must survive a fold that failed.
    @Test func aCorrectionWhoseKeyNoLongerFoldsIsKept() throws {
        let ctx = ModelContext(try container())
        // A key the gate's fold reduces to NOTHING, which is the only way it answers nil.
        ctx.insert(PromotedProducer(orgKey: "()", addedAt: older))
        try ctx.save()

        #expect(ProducerGate.key("()") == nil, "the case this test exists for stopped existing")
        ProducerOverrideKeyRealignment.run(in: ctx)

        #expect(try promoted(ctx) == ["()"], "a correction was lost because its key would not fold")
    }

    @Test func aSecondPassDoesNothing() throws {
        let ctx = ModelContext(try container())
        ctx.insert(PromotedProducer(orgKey: bracketed, addedAt: older))
        ctx.insert(DemotedHouse(orgKey: "The Frigid New York", addedAt: older))
        try ctx.save()

        #expect(ProducerOverrideKeyRealignment.run(in: ctx).rekeyed == 2)
        #expect(ProducerOverrideKeyRealignment.run(in: ctx)
                == ProducerOverrideKeyRealignment.Summary())
    }

    @Test func twoEmptyTablesAreANoOp() throws {
        let ctx = ModelContext(try container())
        #expect(ProducerOverrideKeyRealignment.run(in: ctx)
                == ProducerOverrideKeyRealignment.Summary())
    }

    // The corrections still REACH the gate afterwards, which is the thing that matters: a set whose
    // keys never match is indistinguishable from the empty set #1679 was about.
    @Test func aRealignedPromotionStillReachesTheGate() throws {
        let ctx = ModelContext(try container())
        ctx.insert(PromotedProducer(orgKey: "The Frigid New York", addedAt: older))
        try ctx.save()
        ProducerOverrideKeyRealignment.run(in: ctx)

        let overrides = ProducerOverrideEditing.overrides(in: ctx)
        #expect(overrides.promoted.contains(ProducerGate.key("FRIGID New York")!))
    }

    // Two rows moving at once where one wants the key the other is vacating. `orgKey` is UNIQUE, so for
    // as long as both held it the store would refuse the write.
    @Test func chainedReKeysBothLand() throws {
        let ctx = ModelContext(try container())
        // The second row's target IS the first row's current key, which is the shape that needs parking.
        ctx.insert(PromotedProducer(orgKey: "the a", addedAt: older))
        ctx.insert(PromotedProducer(orgKey: "the the a", addedAt: older))
        try ctx.save()

        ProducerOverrideKeyRealignment.run(in: ctx)

        let keys = try promoted(ctx)
        #expect(keys.count == 2, "a correction was lost to a chained re-key")
        #expect(Set(keys).count == 2)
        #expect(!keys.contains { $0.contains("\u{1}") }, "a row was left parked mid-pass")
    }
}
