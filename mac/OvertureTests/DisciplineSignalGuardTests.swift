import Testing
import Foundation

// #981: guard the classifier's discipline word lists against silently going stale.
//
// LIVE-STORE-CLAIM verified=2026-07-17 measure="live rows tagged music, and how many came from a real genre signal"
// Every discipline in EventClassifier.detectDiscipline is detected by a hand-written regex word
// list, and until #981 nothing measured those lists against real data. #970 Phase 0 found the
// music list had only ever known choir words while the function fell back to `.music`, so "no
// signal" and "music" were the same answer (119 of 128 live rows tagged music, only 4 from an
// actual signal) and the whole suite stayed green. Under #970, discipline now picks the geographic
// gate, so a stale list quietly files a show under the wrong rule.
//
// This guard measures the OUTCOME over a corpus of REAL live-store titles: the share that resolve
// to the `.other` fallback rather than to an actual discipline signal. It deliberately does NOT
// re-list the classifier's own words and assert they match (the "test compared against its own
// definition" trap): it asserts the aggregate signal instead. See
// fixtures/discipline-corpus/README.md for provenance and the threshold rationale.
@Suite("Discipline signal guard (#981)")
struct DisciplineSignalGuardTests {
    private struct CorpusEntry: Decodable {
        let title: String
        let presenter: String?
    }
    private struct Corpus: Decodable {
        let version: Int
        let titles: [CorpusEntry]
    }

    // Fail bar: the `.other` fallback share may not exceed this. The real corpus sits near 0.21;
    // the music list going dark (the #970 defect) sends it to roughly 0.84. See the fixture README.
    private static let maxFallbackShare = 0.35

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OvertureTests
            .deletingLastPathComponent()   // mac
            .deletingLastPathComponent()   // repo root
    }

    private func loadCorpus() throws -> [CorpusEntry] {
        let data = try Data(contentsOf: repoRoot().appendingPathComponent("fixtures/discipline-corpus/titles.json"))
        return try JSONDecoder().decode(Corpus.self, from: data).titles
    }

    // The measured outcome: share of rows that resolve to `.other` rather than to a real discipline
    // signal. This is the only thing the guard asserts on, and it never restates the word lists.
    private func fallbackShare(_ entries: [CorpusEntry]) -> Double {
        guard !entries.isEmpty else { return 0 }
        let fellBack = entries.filter {
            EventClassifier.classify(ExtractedEvent(
                title: $0.title,
                presenter: $0.presenter,
                venue: nil,
                performanceDate: nil,
                sourceUrl: nil,
                location: nil
            )).discipline == .other
        }.count
        return Double(fellBack) / Double(entries.count)
    }

    @Test func realCorpusResolvesMostlyByaRealSignal() throws {
        let entries = try loadCorpus()
        // A stripped corpus must not pass by being too small to say anything.
        #expect(entries.count >= 15)
        let share = fallbackShare(entries)
        #expect(
            share <= Self.maxFallbackShare,
            "\(Int((share * 100).rounded()))% of the corpus fell through to .other (bar \(Int(Self.maxFallbackShare * 100))%); a discipline word list may have gone stale"
        )
    }

    // The aggregate fallback share above is dominated by music, so it can stay green while a thin
    // non-music list (dance, opera, theater, band, comedy) rots: a handful of rows sliding to `.other`
    // barely moves the whole-corpus share. #1079 seeds each of those lists with real live-store rows and
    // asserts a per-discipline floor, so a single list going stale trips this even when the aggregate
    // does not. Under #970 that matters: discipline picks the geographic gate, so a stale non-music list
    // quietly files a show under the wrong rule.
    //
    // LIVE-STORE-CLAIM verified=2026-07-17 measure="prospects in the live store behind the corpus coverage floors"
    // The floors are the honest real coverage found in the live store (313 prospects) for #1079, not
    // aspirations. The store holds few real dance/opera/band/comedy rows, so those floors are low by
    // necessity: opera is the thinnest at 2 (all the real opera rows there are). See
    // fixtures/discipline-corpus/README.md for the per-discipline counts and provenance. This uses the
    // real classifier and never restates a word list, so it cannot become a test compared against its
    // own definition.
    private static let disciplineFloors: [Discipline: Int] = [
        .music: 14,
        .theater: 10,
        .dance: 4,
        .band: 4,
        .comedy: 4,
        .opera: 2
    ]

    @Test func eachDisciplineIsExercisedByRealTitles() throws {
        let entries = try loadCorpus()
        var counts: [Discipline: Int] = [:]
        for entry in entries {
            let discipline = EventClassifier.classify(ExtractedEvent(
                title: entry.title,
                presenter: entry.presenter,
                venue: nil,
                performanceDate: nil,
                sourceUrl: nil,
                location: nil
            )).discipline
            counts[discipline, default: 0] += 1
        }
        for (discipline, floor) in Self.disciplineFloors {
            let have = counts[discipline, default: 0]
            #expect(
                have >= floor,
                "only \(have) real \(discipline.rawValue) titles resolve in the corpus (floor \(floor)); a discipline word list may have gone stale or the corpus lost coverage"
            )
        }
    }

    // Proves the bar is not vacuous and would fire on the failure it exists to catch. A corpus the
    // classifier mostly cannot read (real live rows carrying no discipline signal) is the end-state
    // a stale word list produces: rows that should resolve fall to `.other` and the share climbs
    // past the bar. Uses only real titles and the real classifier; no word list is restated.
    @Test func guardFiresWhenTooManyRowsFallThrough() {
        let rotHeavy = [
            CorpusEntry(title: "A Man Called Paris", presenter: nil),
            CorpusEntry(title: "Gigi in Punk", presenter: nil),
            CorpusEntry(title: "Honey, Drop It", presenter: nil),
            CorpusEntry(title: "An Evening of Chopin", presenter: nil),
            CorpusEntry(title: "Berliner Philharmoniker", presenter: nil),
            CorpusEntry(title: "Joe Hisaishi in Concert", presenter: nil)
        ]
        #expect(fallbackShare(rotHeavy) > Self.maxFallbackShare)
    }
}
