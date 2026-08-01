import Testing
import Foundation

// #1773: two properties of the row factory that nothing else can observe.
//
// The first is structural identity. Wrapping every card in AnyView hides its real type from SwiftUI,
// which is what SwiftUI uses to decide whether a subtree can be updated in place or has to be thrown
// away and rebuilt. Inside a lazy list of long rows that turns every pass into a teardown and rebuild
// of every visible card rather than a cheap diff. The card renders identically either way, so there is
// no output to assert on; what rots is the spelling.
//
// The second is that the factory no longer goes looking through the whole store for the one prospect
// matching the card it is building. QueueItemVoiceLearningTests pins the replacement behaviourally
// (the fact now rides on the snapshot); this pins that the scan itself is gone and cannot come back.
@Suite("The row factory builds one concrete card and scans nothing (#1773)")
struct RowFactoryBuildsOneConcreteCardGuardTests {
    private var factory: String { SourceGuardHelper.source("Overture/UI/ProspectRowFactory.swift") }

    @Test func theFactoryIsReadable() {
        #expect(!factory.isEmpty)
    }

    // Type erasure costs the diff. The conditional context menu it existed to express is expressible
    // with a @ViewBuilder without erasing anything.
    //
    // Matches the two CODE spellings (constructing one, or returning one) rather than the bare name,
    // because the factory's own comment has to name the thing it no longer does in order to explain
    // why. A bare-name check fails on its own explanation, which teaches the next person to delete the
    // explanation rather than keep the rule.
    @Test func aCardIsNotTypeErased() {
        #expect(!factory.contains("AnyView("))
        #expect(!factory.contains("-> AnyView"))
    }

    // The whole-store scan. `prospects` is the queue's @Query array, 724 rows on the live store, and
    // this ran once per card per render pass to answer one question about the card's own show.
    @Test func theFactoryDoesNotSearchTheStoreForTheCardItIsBuilding() {
        #expect(!factory.contains("prospects.first(where:"))
    }
}
