import Testing
import Foundation
import SwiftData

// #359 one-time backfill. WatchlistSeed reads the vetted list of presenters/venues discovered from Dan's
// Google Calendar history and adds each through the app's own WatchlistEditing.add, so the seed obeys every
// rule the hand-add path already enforces (host de-dup, refusal, URL/name validation). It lives in the test
// target on purpose: nothing about this one-shot ships in the app.
@MainActor
@Suite("Seeding the watchlist from calendar history (#359)")
struct WatchlistSeedTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([WatchedSource.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private func sources(_ ctx: ModelContext) throws -> [WatchedSource] {
        try ctx.fetch(FetchDescriptor<WatchedSource>())
    }

    @Test func decodesTheVettedSeedShape() throws {
        let json = Data("""
        [
          { "orgName": "The Sebastians", "listingsURL": "https://www.sebastians.org/nyc-series/" },
          { "orgName": "TENET", "listingsURL": "https://tenet.nyc/concerts" }
        ]
        """.utf8)

        let entries = try WatchlistSeed.decode(json)

        #expect(entries == [
            WatchlistSeed.Entry(orgName: "The Sebastians", listingsURL: "https://www.sebastians.org/nyc-series/"),
            WatchlistSeed.Entry(orgName: "TENET", listingsURL: "https://tenet.nyc/concerts"),
        ])
    }

    @Test func addsEachDistinctEntryAsAWatchedSource() throws {
        let ctx = try context()
        let entries = [
            WatchlistSeed.Entry(orgName: "The Sebastians", listingsURL: "https://www.sebastians.org/nyc-series/"),
            WatchlistSeed.Entry(orgName: "TENET", listingsURL: "https://tenet.nyc/concerts"),
            WatchlistSeed.Entry(orgName: "Cerddorion", listingsURL: "https://cerddorion.org/home/tickets/"),
        ]

        let summary = WatchlistSeed.importEntries(entries, into: ctx)

        #expect(summary.added == ["The Sebastians", "TENET", "Cerddorion"])
        #expect(try sources(ctx).count == 3)
    }

    // Two entries that resolve to the same host must not both land: WatchlistEditing.add matches on host, so
    // the second is reported as a duplicate rather than fetched and read twice every run.
    @Test func aSecondEntryOnTheSameHostIsReportedNotAddedTwice() throws {
        let ctx = try context()
        let entries = [
            WatchlistSeed.Entry(orgName: "TENET", listingsURL: "https://tenet.nyc/concerts"),
            WatchlistSeed.Entry(orgName: "TENET Vocal Artists", listingsURL: "https://tenet.nyc/about"),
        ]

        let summary = WatchlistSeed.importEntries(entries, into: ctx)

        #expect(summary.added == ["TENET"])
        #expect(summary.duplicates == ["TENET Vocal Artists"])
        #expect(try sources(ctx).count == 1)
    }

    // The line that must not be crossed: an org that asked Dan to stop can never be seeded back on, even by
    // this bulk import. The rule lives in WatchlistEditing; the seed must not route around it.
    @Test func anOrgThatRefusedIsReportedAndNeverReAdded() throws {
        let ctx = try context()
        let refused = WatchedSource(sourceId: "tenet.nyc", orgName: "TENET",
                                    listingsURL: "https://tenet.nyc/concerts", kind: .html)
        refused.isActive = false
        refused.inactiveReason = .orgRefusal
        ctx.insert(refused)

        let summary = WatchlistSeed.importEntries(
            [WatchlistSeed.Entry(orgName: "TENET", listingsURL: "https://tenet.nyc/concerts")], into: ctx)

        #expect(summary.refused == ["TENET"])
        #expect(summary.added.isEmpty)
        #expect(try sources(ctx).count == 1)
        #expect(try sources(ctx).first?.isActive == false)
    }

    @Test func anEntryWithAnUnusableURLIsReportedNotSilentlyDropped() throws {
        let ctx = try context()

        let summary = WatchlistSeed.importEntries(
            [WatchlistSeed.Entry(orgName: "Broken", listingsURL: "not a url")], into: ctx)

        #expect(summary.invalid == ["Broken"])
        #expect(summary.added.isEmpty)
        #expect(try sources(ctx).isEmpty)
    }

    // MARK: - Running against a real store file on disk (the shape the one-shot uses)

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // The one-shot opens the app's real store (all four @Model types) at a URL and persists the rows.
    // Proven here against a throwaway on-disk store, not the live one: write, then reopen a fresh
    // container at the same path and confirm the rows survived the save.
    // #1006: real, disk-backed ModelContainer work funnels through RealStoreTestLock so it never
    // overlaps another suite's, in the whole process.
    @Test func runImportPersistsRowsToAStoreOnDisk() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let dir = try tempDir()
            let storeURL = dir.appendingPathComponent("default.store")
            let jsonURL = dir.appendingPathComponent("seed.json")
            try Data("""
            [
              { "orgName": "The Sebastians", "listingsURL": "https://www.sebastians.org/nyc-series/" },
              { "orgName": "TENET", "listingsURL": "https://tenet.nyc/concerts" }
            ]
            """.utf8).write(to: jsonURL)

            let summary = try WatchlistSeed.runImport(storeURL: storeURL, jsonURL: jsonURL)

            #expect(summary.added == ["The Sebastians", "TENET"])

            let reopened = ModelContext(try ModelContainer(
                for: Schema([Prospect.self, Recipient.self, WatchedSource.self, DayOff.self]),
                configurations: [ModelConfiguration(url: storeURL)]))
            #expect(try reopened.fetch(FetchDescriptor<WatchedSource>()).count == 2)
            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }

    // Assume it runs twice: a second run of the same seed adds nothing new (every entry is a host it
    // already watches) and never doubles the rows.
    @Test func runImportIsIdempotentAcrossTwoRuns() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let dir = try tempDir()
            let storeURL = dir.appendingPathComponent("default.store")
            let jsonURL = dir.appendingPathComponent("seed.json")
            try Data("""
            [ { "orgName": "TENET", "listingsURL": "https://tenet.nyc/concerts" } ]
            """.utf8).write(to: jsonURL)

            _ = try WatchlistSeed.runImport(storeURL: storeURL, jsonURL: jsonURL)
            let second = try WatchlistSeed.runImport(storeURL: storeURL, jsonURL: jsonURL)

            #expect(second.added.isEmpty)
            #expect(second.duplicates == ["TENET"])

            let reopened = ModelContext(try ModelContainer(
                for: Schema([Prospect.self, Recipient.self, WatchedSource.self, DayOff.self]),
                configurations: [ModelConfiguration(url: storeURL)]))
            #expect(try reopened.fetch(FetchDescriptor<WatchedSource>()).count == 1)
            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }
}
