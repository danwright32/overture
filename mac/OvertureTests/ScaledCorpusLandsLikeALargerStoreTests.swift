import Testing
import Foundation
import SwiftData

// #4427: a landing on the scaled corpus must do, per copy, exactly what the same landing does on the clone.
//
// #4372's attribution probe found the 4x corpus giving every copy its original's `sourceIds` while the results
// landed on it were the clone's, so the reconcile took every copy for a show its sources had dropped: 382 shows
// written by the reconcile at 4x against 7 on the clone. A real store four times the size has four times the
// sources and four times the results, and none of its live shows look cancelled (L48, L391).
//
// Measured here on the landing oracle's INVENTED corpus (`LandingOracleCorpus`), which already holds the cases a
// landing's answer depends on beyond the row in front of it: a stored show the run no longer lists (the
// reconcile's miss), a poisoned production token, an ambiguous season page, a source's own spelling of its
// room, and rows no source owns. It is seeded into a file store, landed once at 1x, and landed once at 2x on
// `Phase0.scaledCopy` of the same seed with `Phase0.scaledResults`. With the copy's glue taken off, every row the
// 2x landing leaves must be a row the 1x landing left, exactly twice over.
@MainActor
@Suite("#4427 the scaled corpus lands like a store that many times the size", .serialized)
final class ScaledCorpusLandsLikeALargerStoreTests {
    private let sandboxes = TemporarySandboxes()

    /// One row as the landing left it, with the copy's glue taken off every field the corpus glues, so a copy and its
    /// original read the same. Everything a landing or a reconcile writes is in it.
    private struct Row: Hashable, CustomStringConvertible {
        let title: String
        let presenter: String
        let venue: String
        let date: String
        let listing: String
        let runListings: [String]
        let sources: [String]
        let missed: Int
        let status: String
        var description: String {
            "\(title) | \(presenter) | \(venue) | \(date) | missed \(missed) | sources \(sources) | \(status) | \(listing) \(runListings)"
        }
    }

    private static let glues = [Phase0.glue(forCopy: 1)]

    private func unglued(_ s: String?) -> String {
        guard let s else { return "nil" }
        // A name carries its copy's glue in front, an address or id on the end (`ScaledCorpus.gluedName`).
        for g in Self.glues where s.hasPrefix(g) { return String(s.dropFirst(g.count)) }
        for g in Self.glues where s.hasSuffix(g) { return String(s.dropLast(g.count)) }
        return s
    }

    private func rows(_ shows: [Prospect]) -> [Row: Int] {
        var out: [Row: Int] = [:]
        for p in shows {
            let row = Row(title: unglued(p.groupName), presenter: unglued(p.presenter), venue: unglued(p.venue),
                          date: p.performanceDate ?? "nil", listing: unglued(p.sourceListingURL),
                          runListings: p.runSourceURLs.map { unglued($0) },
                          sources: p.sourceIds.map { unglued($0) }.sorted(),
                          missed: p.missedScoutCount, status: p.statusRaw)
            out[row, default: 0] += 1
        }
        return out
    }

    private struct Landed {
        let outcome: ScoutService.Outcome
        let rows: [Row: Int]
        let showCount: Int
        let unownedSourceIds: [String]
    }

    /// The landing oracle's corpus, seeded into a file store and closed, so it can be scaled.
    private func seededStore() throws -> URL {
        let dir = try sandboxes.make(named: "scaled-corpus-4427-seed")
        let url = dir.appendingPathComponent("Overture.store")
        let container = try Phase0.openContainer(at: url)
        let context = container.mainContext
        context.autosaveEnabled = false
        try LandingOracleCorpus.seed(into: context)
        try context.save()
        return url
    }

    private func land(_ results: ScoutExtractResults, on url: URL) async throws -> Landed {
        let container = try Phase0.openContainer(at: url)
        let context = container.mainContext
        context.autosaveEnabled = false
        let outcome = await ScoutExtractIngest.ingest(results, clients: [], history: [], blocked: .empty,
                                                      today: LandingOracleCorpus.today,
                                                      now: LandingOracleCorpus.now, into: context)
        try context.save()
        let read = ModelContext(container)
        let shows = try read.fetch(FetchDescriptor<Prospect>())
        let sources = Set(try read.fetch(FetchDescriptor<WatchedSource>()).map(\.sourceId))
        let unowned = Set(shows.flatMap(\.sourceIds)).subtracting(sources).sorted()
        return Landed(outcome: outcome, rows: rows(shows), showCount: shows.count, unownedSourceIds: unowned)
    }

    @Test func eachCopyLandsExactlyAsItsOriginalDoes() async throws {
        let seed = try seededStore()
        let results = LandingOracleCorpus.results()

        let oneDir = try sandboxes.make(named: "scaled-corpus-4427-x1")
        let one = oneDir.appendingPathComponent("Overture.store")
        for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: seed.path + suffix) {
            try FileManager.default.copyItem(atPath: seed.path + suffix, toPath: one.path + suffix)
        }
        let x1 = try await land(results, on: one)

        let twoDir = try sandboxes.make(named: "scaled-corpus-4427-x2")
        let two = try Phase0.scaledCopy(of: seed, factor: 2, in: twoDir)
        // Before anything lands: a copy carries the key its own glued values compute wherever its original does.
        // Left appended, the landing re-keys every copy through a URL arm and still ends equal below, so the
        // rows alone cannot see it; the re-key is a write per copy a real store never makes.
        do {
            func anchored(_ url: URL) throws -> Int {
                try ModelContext(Phase0.openContainer(at: url)).fetch(FetchDescriptor<Prospect>())
                    .filter { $0.naturalKey == $0.scoutAnchoredNaturalKey }.count
            }
            let seedAnchored = try anchored(seed)
            let twoAnchored = try anchored(two)
            #expect(seedAnchored > 0 && twoAnchored == 2 * seedAnchored,
                    "shows keyed as the app computes them: seed \(seedAnchored), 2x \(twoAnchored)")
        }
        let x2 = try await land(Phase0.scaledResults(results, factor: 2), on: two)

        // The 1x landing has to have done each thing the comparison is about, or equality proves nothing.
        #expect(x1.outcome.inserted > 0 && x1.outcome.updated > 0,
                "the 1x landing inserted \(x1.outcome.inserted) and updated \(x1.outcome.updated)")
        #expect(x1.rows.keys.contains { $0.missed > 0 },
                "no show read a miss at 1x, so the reconcile this exists for was not exercised")
        #expect(x1.outcome.unqueuedResultIds.isEmpty && x2.outcome.unqueuedResultIds.isEmpty,
                "results landed under an id no source holds: 1x \(x1.outcome.unqueuedResultIds), 2x \(x2.outcome.unqueuedResultIds)")

        #expect(x2.outcome.inserted == 2 * x1.outcome.inserted,
                "inserted: 1x \(x1.outcome.inserted), 2x \(x2.outcome.inserted)")
        #expect(x2.outcome.updated == 2 * x1.outcome.updated,
                "updated: 1x \(x1.outcome.updated), 2x \(x2.outcome.updated)")
        #expect(x2.outcome.skipped == 2 * x1.outcome.skipped,
                "skipped: 1x \(x1.outcome.skipped), 2x \(x2.outcome.skipped)")
        #expect(x2.showCount == 2 * x1.showCount, "shows after: 1x \(x1.showCount), 2x \(x2.showCount)")
        // The corpus names one source it holds no row for on purpose (a show owned by a source not in the run), so
        // the 2x store must hold a row for every source the 1x store does, and lack exactly the copies of the rest.
        let unownedCopies = (x1.unownedSourceIds + x1.unownedSourceIds.map { $0 + Phase0.glue(forCopy: 1) }).sorted()
        #expect(x2.unownedSourceIds == unownedCopies,
                "sources shows name and no row holds: 1x \(x1.unownedSourceIds), 2x \(x2.unownedSourceIds)")

        let doubled = x1.rows.mapValues { $0 * 2 }
        let differing = Set(doubled.keys).union(x2.rows.keys).filter { doubled[$0] != x2.rows[$0] }
            .map { "\($0): 1x twice \(doubled[$0] ?? 0), 2x \(x2.rows[$0] ?? 0)" }.sorted()
        #expect(differing.isEmpty, Comment(rawValue:
            "rows a copy left differently from its original:\n" + differing.joined(separator: "\n")))
    }

    @Test func aCopyKeyIsTheOneItsGluedEventArrivesWith() {
        let glue = Phase0.glue(forCopy: 1)
        let key = Prospect.makeNaturalKey(groupName: "Tidewater Suite", performanceDate: "2026-10-24",
                                          venue: "Harbor Stage, Pier 4")
        let decision = ScaledCorpus.copyKey(key: key, anchoredTitle: "Tidewater Suite", date: "2026-10-24",
                                            anchoredVenue: "Harbor Stage, Pier 4", glue: glue, taken: [key])
        let event = ScaledCorpus.glued(LandingOracleCorpus.event("Tidewater Suite", "Harbor Stage Collective",
                                                                 "Harbor Stage, Pier 4", "2026-10-24",
                                                                 "https://harborstage.example/tidewater"),
                                       glue: glue)
        #expect(decision == .init(key: Prospect.makeNaturalKey(groupName: event.title,
                                                              performanceDate: event.performanceDate,
                                                              venue: event.venue), kind: .recomputed))
        // Appending to the key would have been a key that event cannot compute (the venue's comma clause is
        // dropped from the key, so the glue never reaches it).
        #expect(decision.key != key + glue)
    }

    @Test func aDriftedKeyStaysAppendedAndATakenKeyIsNeverWrittenTwice() {
        let glue = Phase0.glue(forCopy: 1)
        // A renamed card: its key is not the one its title computes, so its copy drifts the same way.
        let drifted = ScaledCorpus.copyKey(key: "old title|2026-10-24|harbor stage", anchoredTitle: "New Title",
                                           date: "2026-10-24", anchoredVenue: "Harbor Stage", glue: glue, taken: [])
        #expect(drifted == .init(key: "old title|2026-10-24|harbor stage" + glue, kind: .drifted))
        let key = Prospect.makeNaturalKey(groupName: "Paper Lanterns", performanceDate: "2026-10-31", venue: "Harbor Stage")
        let computed = Prospect.makeNaturalKey(groupName: glue + "Paper Lanterns", performanceDate: "2026-10-31",
                                               venue: glue + "Harbor Stage")
        let taken = ScaledCorpus.copyKey(key: key, anchoredTitle: "Paper Lanterns", date: "2026-10-31",
                                         anchoredVenue: "Harbor Stage", glue: glue, taken: [computed])
        #expect(taken == .init(key: key + glue, kind: .taken))
    }

    /// Every probe that lands results on the scaled corpus lands the scaled results, or says in a marker why it
    /// lands the clone's. Landing the clone's results on a corpus whose copies own their own sources is option 2
    /// of #4427, the reading the decision rejected for understating the reconcile's walk, and it would look like
    /// a working probe. A whole-file scan, so a second probe in one file is answered by the first (L135); it
    /// catches the next probe FILE, which is how every one of them has arrived.
    @Test func everyProbeLandingOnTheScaledCorpusLandsTheScaledResults() throws {
        let marker = "// scaled-corpus-lands-unscaled: "
        var offenders: [String] = []
        var landers = 0
        for folder in ["mac/OvertureTests", "mac/OvertureHostedTests"] {
            let dir = RepoRoot.url.appendingPathComponent(folder)
            for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) where name.hasSuffix(".swift") {
                let text = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
                guard text.contains("Phase0.scaledCopy(") || text.contains("ScaledCorpus.build("),
                      text.contains("ScoutExtractIngest.ingest(") else { continue }
                landers += 1
                let scales = text.contains("Phase0.scaledResults(") || text.contains("ScaledCorpus.results(")
                // The reason must begin with a word, so the marker alone cannot read as one (L675).
                let reasoned = text.components(separatedBy: "\n").contains { line in
                    guard let range = line.range(of: marker) else { return false }
                    return line[range.upperBound...].first?.isLetter == true
                }
                if !scales && !reasoned { offenders.append(name) }
            }
        }
        #expect(landers >= 4, "found \(landers) probe files landing on the scaled corpus; the scan reads nothing")
        #expect(offenders.isEmpty, Comment(rawValue: "these land results on the scaled corpus without "
            + "Phase0.scaledResults and without a '\(marker)<reason>' line: \(offenders.sorted())"))
    }

    @Test func factorOneLeavesTheResultsAsTheyWere() {
        let results = LandingOracleCorpus.results()
        #expect(Phase0.scaledResults(results, factor: 1) == results)
        let doubled = Phase0.scaledResults(results, factor: 2)
        #expect(doubled.results.map(\.sourceId)
                == results.results.map(\.sourceId) + results.results.map { $0.sourceId + Phase0.glue(forCopy: 1) })
    }
}
