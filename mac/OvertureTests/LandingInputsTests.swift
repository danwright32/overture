import Testing
import Foundation
import SwiftData

// #4339 (A11): the show table reads in the first hold of the calendar ingest and of `runScout` leave the main
// thread, behind the entry flush, and a table that cannot be read is recorded rather than read as empty.
private struct Unreadable: Error {}

private struct NoFeed: SourceExtractor {
    func extract() async throws -> ExtractedListing { ExtractedListing(events: [], verdict: .noDatedContent) }
}

// Which thread each table read ran on, from whatever thread it ran.
private final class Threads: @unchecked Sendable {
    private let lock = NSLock()
    private var onMain: [Bool] = []
    func note() { lock.withLock { onMain.append(Thread.isMainThread) } }
    var all: [Bool] { lock.withLock { onMain } }
}

@MainActor
@Suite("#4339 the landing inputs are read off the main thread, behind the entry flush")
final class LandingInputsTests {
    private func seeded() throws -> (ModelContainer, ModelContext) {
        let c = try TestModelContainer.inMemory(AppSchema.models)
        let ctx = c.mainContext
        ctx.insert(Prospect(naturalKey: "stored-0", groupName: "Stored Show", discipline: "music",
                            venue: "Venue Hall", performanceDate: "2026-11-21",
                            sourceListingURL: "https://stored.example/0", priorRelationship: "none",
                            production: "self", profile: "strong", coverage: "likely_uncovered",
                            fitScore: 5, tier: "mid", fitReason: "r", matchedClientName: nil,
                            possibleMatchSource: nil, possibleMatchName: nil))
        try ctx.save()
        return (c, ctx)
    }

    private let absentHistory = URL(fileURLWithPath: "/dev/null/no-imported-history.json")
    private let absentExport = URL(fileURLWithPath: "/dev/null/no-downbeat-export.json")

    @Test func theIngestsHistoryIsReadOffTheMainThread() async throws {
        let (container, ctx) = try seeded()
        defer { withExtendedLifetime(container) {} }
        let threads = Threads()
        let inputs = await LandingInputs.read(exportURL: absentExport, historyURL: absentHistory,
                                              readProspectTable: { threads.note(); return try ScoutService.readProspectTable($0) },
                                              into: ctx)
        #expect(threads.all == [false], "the show table was read on threads \(threads.all) (true is main)")
        #expect(inputs.degradedReads.isEmpty)
    }

    @Test func anUnreadableTableIsRecordedAndTheHistoryIsTheImportedRecordAlone() async throws {
        let (container, ctx) = try seeded()
        defer { withExtendedLifetime(container) {} }
        let inputs = await LandingInputs.read(exportURL: absentExport, historyURL: absentHistory,
                                              readProspectTable: { _ in throw Unreadable() }, into: ctx)
        #expect(inputs.degradedReads == [.repeatClientHistory])
        #expect(inputs.history == LocalHistory.forMatching(existing: [], importedFrom: absentHistory))
    }

    @Test func aPendingEditIsSavedBeforeTheBackgroundReadAndAFlushThatFailsReadsOnTheMainThread() async throws {
        let (container, ctx) = try seeded()
        defer { withExtendedLifetime(container) {} }
        let stored = try #require(try ctx.fetch(FetchDescriptor<Prospect>()).first)
        stored.groupName = "Renamed By Dan"
        let threads = Threads()
        // A flush that cannot save: the edit stays pending, and the read happens where it can see it.
        _ = await LandingInputs.history(importedFrom: absentHistory,
                                        readProspectTable: { threads.note(); return try ScoutService.readProspectTable($0) },
                                        saveEntry: { _ in throw Unreadable() }, into: ctx)
        #expect(threads.all == [true], "a read behind a failed flush ran on \(threads.all), where the edit is unseen")
        #expect(ctx.hasChanges, "the failed flush touched Dan's pending edit")
        // A flush that saves: the background read sees the edit, because it is in the store.
        _ = await LandingInputs.history(importedFrom: absentHistory, into: ctx)
        let fresh = try ModelContext(container).fetch(FetchDescriptor<Prospect>()).map(\.groupName)
        #expect(fresh == ["Renamed By Dan"], "the edit was not saved before the background read: \(fresh)")
    }

    @Test func runScoutReadsItsHistoryOffTheMainThread() async throws {
        let (container, ctx) = try seeded()
        defer { withExtendedLifetime(container) {} }
        let threads = Threads()
        _ = try await ScoutService.runScout(
            into: ctx, depth: .watchOnly, extractor: NoFeed(), extractorRegistry: { _ in nil },
            fetch: { url, _, _ in FetchedPage(normalizedHTML: "<p/>", finalURL: url.absoluteString, contentHash: "x") },
            pin: { _, id in URL(fileURLWithPath: "/dev/null/\(id).html") }, launch: { _ in },
            defaults: ScratchDefaults.make("LandingInputsTests"),
            readProspectTable: { threads.note(); return try ScoutService.readProspectTable($0) },
            landings: LandingSingleFlight())
        #expect(threads.all.first == false, "runScout's first table read, its history, ran on the main thread: \(threads.all)")
    }
}
