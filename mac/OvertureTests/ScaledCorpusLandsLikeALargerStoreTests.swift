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

    private static let glues = [Phase0.glue(forCopy: 1), Phase0.glue(forCopy: 2)]

    private func unglued(_ s: String?) -> String {
        guard let s else { return "nil" }
        // A name carries its copy's glue, doubled, in front of every word; an address or id carries it on the end
        // (`ScaledCorpus.gluedName`). No name in the invented corpus holds either glue of its own.
        for g in Self.glues where s.contains(g + g) { return s.replacingOccurrences(of: g + g, with: "") }
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

    /// What a second, unchanged landing of the same results wrote: every show whose stored values (its
    /// `ingestedAt` included) moved, and how many of those are explained: the #4331 rule restamps a show
    /// `MergeCandidateIndex` gives a twin on purpose, and the reconcile counts another miss for a show its
    /// source still does not list (Old Harbor Revue), which is a real change rather than a needless write.
    private struct ReLanded {
        let written: Int
        let explained: Int
    }

    private func reLand(_ results: ScoutExtractResults, on url: URL) async throws -> ReLanded {
        let container = try Phase0.openContainer(at: url)
        let context = container.mainContext
        context.autosaveEnabled = false
        func values(_ p: Prospect) -> String {
            "\(p.groupName)|\(p.presenter ?? "")|\(p.venue ?? "")|\(p.performanceDate ?? "")|\(p.ingestedAt)|"
                + "\(p.missedScoutCount)|\(p.statusRaw)|\(p.sourceIds)|\(p.runSourceURLs)|\(p.sourceListingURL ?? "")"
        }
        for landing in 1...2 {
            let stored = try context.fetch(FetchDescriptor<Prospect>())
            let before = Dictionary(uniqueKeysWithValues: stored.map { ($0.naturalKey, values($0)) })
            let missedBefore = Dictionary(uniqueKeysWithValues: stored.map { ($0.naturalKey, $0.missedScoutCount) })
            await ScoutExtractIngest.ingest(results, clients: [], history: [], blocked: .empty,
                                            today: LandingOracleCorpus.today,
                                            now: LandingOracleCorpus.now.addingTimeInterval(Double(landing) * 3600),
                                            into: context)
            try context.save()
            guard landing == 2 else { continue }
            let rows = try ModelContext(container).fetch(FetchDescriptor<Prospect>())
            let written = rows.filter { before[$0.naturalKey] != values($0) }
            let index = MergeCandidateIndex(rows: rows, tokens: { p in
                ([p.sourceListingURL].compactMap { $0 } + p.runSourceURLs).compactMap(ProductionToken.inURL)
            })
            let explained = written.filter { p in
                index.isContested(p) || missedBefore[p.naturalKey].map { $0 != p.missedScoutCount } == true
            }
            return ReLanded(written: written.count, explained: explained.count)
        }
        return ReLanded(written: -1, explained: -1)
    }

    /// #4481: an unchanged re-land writes, at three times the size, exactly three times the shows it writes on
    /// the clone, and at either size only the shows the #4331 rule restamps on purpose (a show with a twin a merge
    /// reader may compare it against) or whose miss the reconcile counts. THREE times, because the defect lived
    /// between two COPIES: glued once on the first word, copy one's "qaHamlet" and copy two's "qbHamlet" were
    /// one typo apart on the same night, so `isSameNightVariant` made them twins (measured on a clone of the live
    /// store, 1,290 of its 1,372 titles), and a corpus with a single copy has no second copy to twin with.
    @Test func anUnchangedReLandWritesOnlyTheTwinRuleSRowsAtEverySize() async throws {
        let seed = try seededStore()
        let results = LandingOracleCorpus.results()
        let oneDir = try sandboxes.make(named: "scaled-corpus-4481-x1")
        let one = oneDir.appendingPathComponent("Overture.store")
        for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: seed.path + suffix) {
            try FileManager.default.copyItem(atPath: seed.path + suffix, toPath: one.path + suffix)
        }
        let x1 = try await reLand(results, on: one)
        let three = try Phase0.scaledCopy(of: seed, factor: 3, in: try sandboxes.make(named: "scaled-corpus-4481-x3"))
        let x3 = try await reLand(Phase0.scaledResults(results, factor: 3), on: three)

        #expect(x1.written > 0 && x1.written == x1.explained,
                "the clone's re-land wrote \(x1.written) shows, and only \(x1.explained) are a twin or a counted miss")
        #expect(x3.written == x3.explained,
                "the 3x re-land wrote \(x3.written) shows, and only \(x3.explained) are a twin or a counted miss")
        #expect(x3.written == 3 * x1.written, "an unchanged re-land wrote \(x1.written) shows at 1x and \(x3.written) at 3x")
    }

    /// #4481: a copy's names are no same-night variant of another copy's or the original's, and relate to each
    /// other inside the copy exactly as the original's do.
    @Test func aGluedNameIsNoVariantOfAnotherCopysAndKeepsItsOwnCopysRelations() {
        let qa = Phase0.glue(forCopy: 1), qb = Phase0.glue(forCopy: 2)
        for title in ["Hamlet", "Winter Light", "The Tin Orchard", "Copper Tide: A Sea Cycle"] {
            for (a, b) in [(title, ScaledCorpus.gluedName(title, glue: qa)),
                           (ScaledCorpus.gluedName(title, glue: qa), ScaledCorpus.gluedName(title, glue: qb))] {
                #expect(!GroupNameMatch.isSameNightVariant(a, b), "\(a) reads as a same-night variant of \(b)")
            }
        }
        let pairs = [("Winter Light", "Winter Light Vespers"), ("Tin Orchard", "The Tin Orchard"),
                     ("Copper Tide", "Copper Tide: A Sea Cycle")]
        for (a, b) in pairs {
            #expect(GroupNameMatch.isSameShowTitle(ScaledCorpus.gluedName(a, glue: qa), ScaledCorpus.gluedName(b, glue: qa))
                    == GroupNameMatch.isSameShowTitle(a, b), "\(a) against \(b) answers differently inside a copy")
        }
        #expect(ScaledCorpus.gluedName("Rock &amp; Roll", glue: qa) == "\(qa)\(qa)Rock &amp; \(qa)\(qa)Roll")
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
        let computed = Prospect.makeNaturalKey(groupName: ScaledCorpus.gluedName("Paper Lanterns", glue: glue), performanceDate: "2026-10-31",
                                               venue: ScaledCorpus.gluedName("Harbor Stage", glue: glue))
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

    /// #4427 review: every copy sits in the table under its appended key before any key is recomputed, so a
    /// recomputed key equal to a LATER copy's appended key must stay appended, or that copy's update collides.
    @Test func aRecomputedKeyNeverLandsOnAnotherCopysAppendedKey() {
        let glue = Phase0.glue(forCopy: 1)
        // A's copy computes a key ending in the glue (its room ends in "Aqa"); B's key is that key without its
        // glue, so B's copy already sits under exactly the key A's copy would compute.
        let a = ScaledCorpus.KeySource(key: Prospect.makeNaturalKey(groupName: "Encore", performanceDate: "2026-11-01",
                                                                    venue: "Studio Aqa"),
                                       anchoredTitle: "Encore", date: "2026-11-01", anchoredVenue: "Studio Aqa")
        let computed = Prospect.makeNaturalKey(groupName: ScaledCorpus.gluedName("Encore", glue: glue), performanceDate: "2026-11-01",
                                               venue: ScaledCorpus.gluedName("Studio Aqa", glue: glue))
        #expect(computed.hasSuffix(glue), "the fixture needs a computed key ending in the glue: \(computed)")
        let b = ScaledCorpus.KeySource(key: String(computed.dropLast(glue.count)), anchoredTitle: "Unrelated",
                                       date: "2026-11-02", anchoredVenue: nil)
        let decisions = ScaledCorpus.keyDecisions([a, b], factor: 2)
        let keys = decisions.map { $0.2.key }
        #expect(decisions.first?.2.kind == .taken, "A's copy was decided \(decisions.first.map { "\($0.2)" } ?? "nothing")")
        #expect(Set(keys).count == keys.count, "two copies were given one key: \(keys)")
    }

    @Test func factorOneLeavesTheResultsAsTheyWere() {
        let results = LandingOracleCorpus.results()
        #expect(Phase0.scaledResults(results, factor: 1) == results)
        let doubled = Phase0.scaledResults(results, factor: 2)
        #expect(doubled.results.map(\.sourceId)
                == results.results.map(\.sourceId) + results.results.map { $0.sourceId + Phase0.glue(forCopy: 1) })
    }
}
