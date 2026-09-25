import Testing
import Foundation
import SwiftData
@testable import Overture

// #4106: the count the queue's render memo keys on so that a save through ANY context is a change to it.
// Driven through a real save rather than a hand-posted notification, because the whole claim is that
// SwiftData posts `ModelContext.didSave` when a context saves, and a hand-posted one would prove only
// that this class counts what it is handed (L52).

@MainActor
@Suite("A save through any context moves the store save count (#4106)")
struct StoreSaveCountTests {

    @Test func aSaveThroughAContextMovesTheCount() throws {
        let counter = StoreSaveCount()
        let c = try TestModelContainer.inMemory(AppSchema.models)
        let ctx = ModelContext(c)
        let before = counter.value(for: c)
        ctx.insert(WatchedSource(sourceId: "s", orgName: "Org", listingsURL: "https://org.example/e", kind: .html))
        try ctx.save()
        #expect(counter.value(for: c) > before, Comment(rawValue:
            "a real save left the count at \(counter.value(for: c)), so a memo keyed on it would serve an answer "
            + "from before a write saved through another context"))
    }

    // PER STORE: a save into a different container is not a change to this one. Without this, every
    // concurrently running suite's saves would move every memo in the process.
    @Test func aSaveIntoAnotherStoreLeavesThisOnesCountAlone() throws {
        let counter = StoreSaveCount()
        let mine = try TestModelContainer.inMemory(AppSchema.models)
        let theirs = try TestModelContainer.inMemory(AppSchema.models)
        let before = counter.value(for: mine)
        let ctx = ModelContext(theirs)
        ctx.insert(WatchedSource(sourceId: "t", orgName: "Theirs", listingsURL: "https://t.example/e", kind: .html))
        try ctx.save()
        #expect(counter.value(for: theirs) > 0, "the other store's save was never counted, so the check below proves nothing")
        #expect(counter.value(for: mine) == before, "a save into another store moved this store's count")
    }
}
