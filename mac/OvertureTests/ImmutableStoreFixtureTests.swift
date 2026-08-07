import Testing
import Foundation
import SwiftData

// #1608. Roughly one full local suite run in five failed with
// `SwiftData.DefaultStore save failed ... "you don't have permission"` naming a path under
// `/var/folders/.../immutable-store-<UUID>/default.store`, in a DIFFERENT suite each time, and passed on
// the identical retry.
//
// That path is `ImmutableStoreFixture`'s, and that permission error is what the fixture DELIBERATELY
// causes: it flags a real on-disk store immutable so a save against it genuinely throws. The leak was in
// the order it cleaned up. The tear-down sat in a `defer`, and a `defer` unwinds on the way OUT of its
// scope, which is after `release()` on the success path, so the immutable flags were still set, the temp
// directory was still there, and both containers were still alive holding SwiftData store coordinators at
// the moment the next suite was allowed to start.
//
// Since #1347 the local suite is the only thing verifying the Mac app before a merge, so a gate that
// fails at random trains the operator to re-run until green, which is exactly how a real regression gets
// waved through.
@MainActor
@Suite("The immutable-store fixture cleans up before it lets go (#1608)")
struct ImmutableStoreFixtureTests {
    private var schema: Schema { Schema([Prospect.self, Recipient.self]) }

    private func aShow(_ ctx: ModelContext) {
        ctx.insert(Prospect(naturalKey: "k", groupName: "G", discipline: "choral", venue: "V",
                            performanceDate: "2026-10-25", sourceListingURL: nil, websiteURL: nil,
                            priorRelationship: "none", production: "self", profile: "strong",
                            coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                            matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil))
    }

    // THE assertion. Both orders leave the caller seeing a torn-down fixture, so the difference is only
    // ever visible to whatever runs next, which is why it went unnoticed for months and why this has to
    // watch the order rather than the end state.
    @Test func itTearsDownBeforeItReleasesTheLock() async throws {
        ImmutableStoreFixture.stepsForTesting = []
        defer { ImmutableStoreFixture.stepsForTesting = nil }

        try await ImmutableStoreFixture.withFailingSave(schema: schema, seed: aShow) { ctx in
            self.aShow(ctx)
            #expect(throws: (any Error).self) { try ctx.save() }
        }

        #expect(ImmutableStoreFixture.stepsForTesting == [.toreDown, .releasedLock],
                "the immutable store must be gone before the next suite is allowed to start")
    }

    // The failure path, which is the one that matters most: a body that throws must not skip the
    // tear-down and leave an immutable store behind for the rest of the run.
    @Test func abodyThatThrewStillTearsDownFirst() async throws {
        struct Boom: Error {}
        ImmutableStoreFixture.stepsForTesting = []
        defer { ImmutableStoreFixture.stepsForTesting = nil }

        await #expect(throws: Boom.self) {
            try await ImmutableStoreFixture.withFailingSave(schema: self.schema, seed: self.aShow) { _ in
                throw Boom()
            }
        }

        #expect(ImmutableStoreFixture.stepsForTesting == [.toreDown, .releasedLock])
    }

    // And nothing of it survives at all: no immutable flags left set, no directory left behind. Read from
    // the real file system, since a leftover flagged file is exactly what poisoned the next suite.
    @Test func nothingOfTheFixtureSurvivesTheCall() async throws {
        var storePath = ""
        try await ImmutableStoreFixture.withFailingSave(schema: schema, seed: aShow) { ctx in
            storePath = (ctx.container.configurations.first?.url.path) ?? ""
            #expect(!storePath.isEmpty)
        }

        #expect(storePath.contains("immutable-store-"), "the premise: this really is the fixture's store")
        #expect(!FileManager.default.fileExists(atPath: storePath))
        #expect(!FileManager.default.fileExists(atPath: (storePath as NSString).deletingLastPathComponent))
    }

    // Ordinary runs record nothing, so the observation costs the suite it is watching nothing at all.
    @Test func itrecordsNothingWhenNobodyIsWatching() async throws {
        ImmutableStoreFixture.stepsForTesting = nil
        try await ImmutableStoreFixture.withFailingSave(schema: schema, seed: aShow) { _ in }
        #expect(ImmutableStoreFixture.stepsForTesting == nil)
    }
}
