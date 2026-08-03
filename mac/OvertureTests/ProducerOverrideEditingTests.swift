import Testing
import Foundation
import SwiftData

// #1719 (milestone 34 Phase 2): the human half of #1593's decision, which until now had no store and no
// way in. ProducerGate has taken a `promoted` set since #1593 and every one of its six call sites passed
// the default empty one, so Dan's judgment looked shipped while doing nothing at all (#1679).
//
// Two directions, because the automatic arms miss in both: an organisation that IS a producer despite
// carrying a room's name (the Metropolitan Opera at the Metropolitan Opera House), and an organisation
// that IS a house despite naming no room at all (FRIGID New York, measured on the live store 2026-07-29).
//
// The shape is ExcludedTown's (#991/#1221), deliberately: a SwiftData-only model that grows by an in-app
// action, with the add/remove kept OUT of the view, because a rule stated in a SwiftUI body is a rule no
// test can reach.
@MainActor
@Suite("Correcting a producer/house verdict by hand (#1719)")
struct ProducerOverrideEditingTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(
            for: Schema([PromotedProducer.self, DemotedHouse.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    // The whole point of the layer: what is stored is what the GATE will look up. Storing a plain
    // lowercased string instead would silently never match, because the gate folds a parenthetical and a
    // leading "the" away before comparing, and a set whose keys never match reads exactly like an empty
    // one. That is the #1679 failure a second time, so it is pinned first.
    @Test func promotionStoresTheGatesOwnFoldedKey() throws {
        let ctx = try context()
        #expect(ProducerOverrideEditing.promote("The Metropolitan Opera (Lincoln Center)", into: ctx) == .promoted)
        #expect(ProducerOverrideEditing.promoted(in: ctx) == ["metropolitan opera"])
    }

    @Test func demotionStoresTheGatesOwnFoldedKey() throws {
        let ctx = try context()
        #expect(ProducerOverrideEditing.demote("FRIGID New York", into: ctx) == .demoted)
        #expect(ProducerOverrideEditing.demoted(in: ctx) == ["frigid new york"])
    }

    // Idempotent by construction, like ExcludedTownEditing.exclude: the same organisation, any casing or
    // padding, is a no-op rather than a second row. The unique constraint would throw otherwise.
    @Test func promotingTheSameOrganisationTwiceIsANoOp() throws {
        let ctx = try context()
        #expect(ProducerOverrideEditing.promote("Metropolitan Opera", into: ctx) == .promoted)
        #expect(ProducerOverrideEditing.promote("  metropolitan opera ", into: ctx) == .alreadyPromoted)
        #expect(ProducerOverrideEditing.promoted(in: ctx).count == 1)
    }

    // Mutual exclusion, and the reason it lives HERE rather than being left to the gate: an organisation
    // that is on both lists means nothing, and a correction that silently left the opposite one standing
    // would leave the store holding a contradiction Dan cannot see. Correcting in one direction clears
    // the other, so the last thing he said is the thing in force.
    @Test func demotingAPromotedOrganisationMovesItRatherThanLeavingBoth() throws {
        let ctx = try context()
        #expect(ProducerOverrideEditing.promote("FRIGID New York", into: ctx) == .promoted)
        #expect(ProducerOverrideEditing.demote("FRIGID New York", into: ctx) == .demoted)
        #expect(ProducerOverrideEditing.promoted(in: ctx).isEmpty)
        #expect(ProducerOverrideEditing.demoted(in: ctx) == ["frigid new york"])
    }

    @Test func promotingADemotedOrganisationMovesItBack() throws {
        let ctx = try context()
        #expect(ProducerOverrideEditing.demote("Metropolitan Opera", into: ctx) == .demoted)
        #expect(ProducerOverrideEditing.promote("Metropolitan Opera", into: ctx) == .promoted)
        #expect(ProducerOverrideEditing.demoted(in: ctx).isEmpty)
        #expect(ProducerOverrideEditing.promoted(in: ctx) == ["metropolitan opera"])
    }

    // The way back (#845), and the reason the inline control can be the ONLY way in: the same control
    // that applied a correction takes it back, so a mis-click never costs Dan a verdict he wanted and
    // there is no separate sheet he has to go and find.
    @Test func aCorrectionCanBeTakenBackInEitherDirection() throws {
        let ctx = try context()
        ProducerOverrideEditing.promote("Metropolitan Opera", into: ctx)
        ProducerOverrideEditing.demote("FRIGID New York", into: ctx)

        ProducerOverrideEditing.clear("Metropolitan Opera", in: ctx)
        ProducerOverrideEditing.clear("FRIGID New York", in: ctx)

        #expect(ProducerOverrideEditing.promoted(in: ctx).isEmpty)
        #expect(ProducerOverrideEditing.demoted(in: ctx).isEmpty)
    }

    // What the inline control reads to decide which correction to offer and which to show in force.
    // Derived from the store rather than held in the view, for the same reason the editing is.
    @Test func theStandingCorrectionIsReadableForOneOrganisation() throws {
        let ctx = try context()
        #expect(ProducerOverrideEditing.standing(for: "Metropolitan Opera", in: ctx) == .none)
        ProducerOverrideEditing.promote("Metropolitan Opera", into: ctx)
        #expect(ProducerOverrideEditing.standing(for: "The Metropolitan Opera", in: ctx) == .promoted)
        ProducerOverrideEditing.demote("Metropolitan Opera", into: ctx)
        #expect(ProducerOverrideEditing.standing(for: "Metropolitan Opera", in: ctx) == .demoted)
    }

    // A name the gate cannot key (blank, or punctuation that folds away to nothing) is not an error and
    // not a row: it is simply nothing to correct. Storing it would put a key in the set that no presenter
    // can ever match, which is the quiet kind of wrong this whole issue exists to end.
    @Test(arguments: ["", "   ", "()"])
    func anUnkeyableNameStoresNothing(_ raw: String) throws {
        let ctx = try context()
        #expect(ProducerOverrideEditing.promote(raw, into: ctx) == .noOrganisation)
        #expect(ProducerOverrideEditing.demote(raw, into: ctx) == .noOrganisation)
        #expect(ProducerOverrideEditing.promoted(in: ctx).isEmpty)
        #expect(ProducerOverrideEditing.demoted(in: ctx).isEmpty)
    }

    // End to end, on the real miss: the correction Dan makes in the app is the correction the gate
    // applies. The two halves are only actually connected if a key stored here changes a verdict there,
    // and nothing above proves that on its own.
    @Test func aStoredDemotionChangesTheGatesVerdict() throws {
        let ctx = try context()
        let shows = [
            ProducerGate.Show(presenter: "FRIGID New York", venue: "Under St Marks"),
            ProducerGate.Show(presenter: "FRIGID New York", venue: "The Kraine Theater"),
        ]
        #expect(ProducerGate.qualifies("FRIGID New York", among: shows,
                                       overrides: ProducerOverrideEditing.overrides(in: ctx)))

        ProducerOverrideEditing.demote("FRIGID New York", into: ctx)

        #expect(ProducerGate.qualifies("FRIGID New York", among: shows,
                                       overrides: ProducerOverrideEditing.overrides(in: ctx)) == false)
    }
}
