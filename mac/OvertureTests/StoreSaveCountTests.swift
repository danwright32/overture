import Testing
import Foundation
import SwiftData

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

    // #4358: the foreign count moves on every save through another context, and never on the main context's
    // own, which is the positive control that makes "it moved" mean something (L159).
    @Test func onlyASaveThroughAnotherContextMovesTheForeignCount() throws {
        let counter = StoreSaveCount()
        let c = try TestModelContainer.inMemory(AppSchema.models)
        c.mainContext.insert(WatchedSource(sourceId: "m", orgName: "Main", listingsURL: "https://m.example/e", kind: .html))
        try c.mainContext.save()
        #expect(counter.value(for: c) == 1 && counter.foreignSaveCount(for: c) == 0,
                "the main context's own save counted as foreign")
        for n in 1...2 {
            let other = ModelContext(c)
            other.insert(WatchedSource(sourceId: "f\(n)", orgName: "Other", listingsURL: "https://f.example/e", kind: .html))
            try other.save()
            #expect(counter.foreignSaveCount(for: c) == n,
                    "save \(n) through another context left the count at \(counter.foreignSaveCount(for: c))")
        }
        #expect(counter.hasForeignSaves(in: c))
    }

    // #4609: a store's record belongs to THAT store, never to the next container made at its address. Keyed by
    // `ObjectIdentifier` alone, a fresh store built where a foreign-saved one had been released read as
    // foreign-saved itself, so the queue's memo refused to serve SwiftData's refetch on it and derived the
    // whole store a second time, `nothing this view reads`, in whichever hosted test drew that address.
    @Test func aStoreMadeWhereAForeignSavedOneDiedStartsWithNoRecord() throws {
        let counter = StoreSaveCount()
        // THE POSITIVE CONTROL is the helper returning at all: nil means no container was ever made at a
        // released one's address, so nothing below could have been inherited and the test measured nothing.
        let fresh = try #require(try RecycledStore.whereAForeignSavedOneDied(AppSchema.models) { other in
            other.insert(ExcludedTown(town: "Poughkeepsie"))
        }, "no container was made at the address of a released foreign-saved one, so nothing was measured")
        #expect(!counter.hasForeignSaves(in: fresh) && counter.foreignSaveCount(for: fresh) == 0, Comment(rawValue:
            "a store nothing has saved into reads as foreign-saved (\(counter.foreignSaveCount(for: fresh)) foreign "
            + "saves), inherited from the released store that had its address, so its memos stop serving the refetch"))
        #expect(counter.value(for: fresh) == 0, Comment(rawValue:
            "a store nothing has saved into reads \(counter.value(for: fresh)) saves, inherited from a released one"))
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
