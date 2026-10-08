import Foundation
import SwiftData

// #4609: an in-memory container made at the ADDRESS of one that took a save through a second context and was
// then released.
//
// For a test of anything that remembers a store by `ObjectIdentifier`, which names an address rather than a
// store: once a container is released its address is free, and the next one is routinely made there.
// `StoreSaveCount` kept "this store has taken a foreign save" that way, so a fresh store built where a
// foreign-saved one had died inherited it, and the queue's memo stopped serving SwiftData's refetch on a store
// nothing had ever written to from outside. Order dependent, so it reached a test only in a run where some
// earlier test had saved through a second context, and never in the test run alone.
enum RecycledStore {
    /// The container, or nil when none landed on a released foreign-saved one's address within `attempts`.
    ///
    /// `insert` puts one valid row into the second context, so this never has to know what a schema holds.
    /// Each attempt runs in its own autorelease pool, because a context left in the current pool keeps its
    /// container alive and its address taken.
    @MainActor
    static func whereAForeignSavedOneDied(_ types: [any PersistentModel.Type], attempts: Int = 200,
                                          insert: (ModelContext) -> Void) throws -> ModelContainer? {
        var foreignSaved: Set<ObjectIdentifier> = []
        for _ in 0..<attempts {
            let reused: ModelContainer? = try autoreleasepool {
                let made = try TestModelContainer.inMemory(types)
                if foreignSaved.contains(ObjectIdentifier(made)) { return made }
                let other = ModelContext(made)
                insert(other)
                try other.save()
                foreignSaved.insert(ObjectIdentifier(made))
                return nil
            }
            if let reused { return reused }
        }
        return nil
    }
}
