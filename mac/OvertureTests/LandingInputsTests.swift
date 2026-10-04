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

    // The read phase saves nothing: with an edit of Dan's pending, the history is read on the main thread, where
    // the context sees the edit, and the edit is left pending for the landing's own flush to save.
    @Test func aPendingEditKeepsTheReadOnTheMainThreadAndIsNotSaved() async throws {
        let (container, ctx) = try seeded()
        defer { withExtendedLifetime(container) {} }
        let stored = try #require(try ctx.fetch(FetchDescriptor<Prospect>()).first)
        stored.groupName = "Renamed By Dan"
        let threads = Threads()
        _ = await LandingInputs.history(importedFrom: absentHistory,
                                        readProspectTable: { threads.note(); return try ScoutService.readProspectTable($0) },
                                        into: ctx)
        #expect(threads.all == [true], "a read with an edit pending ran on \(threads.all), where the edit is unseen")
        #expect(ctx.hasChanges, "the read phase saved Dan's pending edit")
        let fresh = try ModelContext(container).fetch(FetchDescriptor<Prospect>()).map(\.groupName)
        #expect(fresh == ["Stored Show"], "the read phase wrote the store: \(fresh)")
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
