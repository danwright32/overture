import Testing
import Foundation
import SwiftData

// #2417: what one queue rebuild actually costs, and which part of it dominates.
//
// Dan, 2026-08-10: closing a show out takes "a full second or two" before the row leaves the screen,
// and striking an email address off a card does the same. Every queue mutation writes the model, saves,
// and then SwiftData invalidates the view's @Query and QueueModel.items(from:) rebuilds EVERY card on
// the main thread. That cost is proportional to the store, not to what changed.
//
// The issue asks for a measurement BEFORE a fix, so the fix follows the numbers rather than the guess.
// This is that measurement.
//
// Why it is opt-in rather than an ordinary test: it builds a corpus the size of the live store and times
// it, which is seconds of work and a stopwatch, neither of which belongs in a suite that runs before
// every push. It is a measuring instrument, not a guard, and it says so rather than sitting silently
// skipped. Run it with:
//
//   TEST_RUNNER_MEASURE_QUEUE_REBUILD=1 mac/scripts/run-tests-locked.sh \
//     -only-testing:OvertureTests/QueueRebuildCostTests
//
// The corpus is MEASURED from Dan's live store on 2026-08-14, never invented, because a rebuild's cost
// is a function of the corpus's shape and an invented one measures a store that does not exist (L48).
// Read with sqlite3 against a COPY of the store, so nothing here or in the reading touched the live one:
//
//   1,139 prospects, 399 distinct presenters, 169 distinct venues, 1,049 distinct group names
//   305 recipients in total, spread over 198 prospects (152 have 1, 26 have 2, 7 have 3, 4 have 4,
//     3 have 5, one has 6, 2 have 7, 2 have 9, one has 11)
//   39 prospects carry a draft body
//   73 watched sources, 60 stored organisation answers
//   233 distinct performance dates, largest single-date cluster 19
//
// The recipient distribution is the part most easily got wrong, and the part that matters most: 941 of
// the 1,139 rows have NO contacts at all, so the per-card contact work (the send grouping, the sendable
// predicate, and with it the draft lint) short circuits on the overwhelming majority. A fixture that
// gave every row a contact would measure a path the live store does not take, and would argue for a fix
// aimed at the wrong half (L102).
@MainActor
@Suite("Queue rebuild cost")
struct QueueRebuildCostTests {

    // LIVE-STORE-CLAIM verified=2026-09-02 measure="prospects, distinct presenters, distinct venues, distinct group names, watched sources, stored organisation answers, and recipients per prospect, all read with sqlite3 from a WAL-inclusive copy of the live store"
    //
    // Each figure carries a LIVE-SHAPE tag, so scripts/check-fixture-corpus-drift.sh compares it against
    // the real store on every push and names the one that has fallen behind. Before #3426 this block read
    // 893 prospects measured 2026-08-14 and had been describing a store a fifth smaller than the one that
    // ships, with nothing reporting it: a cost guard sized below the live store stays GREEN the whole
    // time, because it is exercising a smaller world rather than failing (L354).
    private enum LiveShape {
        // LIVE-SHAPE: prospects
        static let prospects = 1139
        // LIVE-SHAPE: presenters
        static let presenters = 399
        // LIVE-SHAPE: venues
        static let venues = 169
        // LIVE-SHAPE: groupNames
        static let groupNames = 1049
        // LIVE-SHAPE: sources
        static let sources = 73
        // The store's 60 organisation answers are deliberately NOT built here, and this is the one place
        // the fixture departs from the live shape. `inheritedAnswers` returns immediately on an empty
        // list, so with 60 answers its cost is a rounding error either way, and leaving them out keeps
        // the remainder below attributable to the per-card construction alone rather than to a mixture.
        // Named here rather than left silent, so the departure is visible instead of looking like an
        // oversight.
        // Prospect index to number of recipients, matching the measured distribution exactly.
        // Re-measured 2026-09-02: 305 recipients over 198 prospects, so 941 of the 1,139 rows have NO
        // contacts at all. That share, 83%, is the number the paragraph at the top of this file is about
        // and it is why the per-card contact work short-circuits on the overwhelming majority.
        static let recipientCounts: [Int] = {
            var counts = Array(repeating: 0, count: prospects)
            var i = 0
            for _ in 0..<152 { counts[i] = 1; i += 1 }
            for _ in 0..<26 { counts[i] = 2; i += 1 }
            for _ in 0..<7 { counts[i] = 3; i += 1 }
            for _ in 0..<4 { counts[i] = 4; i += 1 }
            for _ in 0..<3 { counts[i] = 5; i += 1 }
            counts[i] = 6; i += 1
            for _ in 0..<2 { counts[i] = 7; i += 1 }
            for _ in 0..<2 { counts[i] = 9; i += 1 }
            counts[i] = 11
            return counts
        }()
        static let prospectsWithADraft = 39
    }

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, WatchedSource.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    // A corpus with the live store's SHAPE. The strings are synthetic, the distribution is not.
    private func buildCorpus(_ ctx: ModelContext) -> [Prospect] {
        var prospects: [Prospect] = []
        prospects.reserveCapacity(LiveShape.prospects)

        for i in 0..<LiveShape.prospects {
            let presenter = "Presenter \(i % LiveShape.presenters) Ensemble"
            let venue = "Venue \(i % LiveShape.venues) Hall"
            let group = "Group \(i % LiveShape.groupNames)"
            let day = (i % 28) + 1
            let month = (i % 12) + 1
            let p = Prospect(naturalKey: "key-\(i)", groupName: group, discipline: "music",
                             venue: venue,
                             performanceDate: String(format: "2026-%02d-%02d", month, day),
                             sourceListingURL: nil,
                             priorRelationship: "none", production: "self", profile: "strong",
                             coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                             matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                             status: .new)
            p.presenter = presenter
            p.sourceIds = ["source-\(i % LiveShape.sources)"]
            if i < LiveShape.prospectsWithADraft {
                p.draftSubject = "Photographs of your concert"
                p.draftBody = "Hello, I photograph concerts in New York and would like to photograph yours."
            }
            for r in 0..<LiveShape.recipientCounts[i] {
                let recipient = Recipient(id: "r-\(i)-\(r)", email: "person\(r)@example.org",
                                          name: "Person \(r)", role: "Director",
                                          provenance: .presenter)
                ctx.insert(recipient)
                p.recipients.append(recipient)
            }
            ctx.insert(p)
            prospects.append(p)
        }
        try? ctx.save()
        return prospects
    }

    private func buildSources(_ ctx: ModelContext) -> [WatchedSource] {
        (0..<LiveShape.sources).map { i in
            let s = WatchedSource(sourceId: "source-\(i)", orgName: "Source \(i)",
                                  listingsURL: "https://example.org/source-\(i)/calendar",
                                  kind: .html)
            ctx.insert(s)
            return s
        }
    }

    private func seconds(_ work: () -> Void) -> Double {
        let start = Date()
        work()
        return Date().timeIntervalSince(start)
    }

    @Test func measureOneQueueRebuild() throws {
        guard ProcessInfo.processInfo.environment["MEASURE_QUEUE_REBUILD"] != nil else {
            // Not silently skipped: a measuring instrument that says nothing is indistinguishable from
            // one that ran and found nothing (L98).
            print("queue-rebuild-cost: not measured. Set TEST_RUNNER_MEASURE_QUEUE_REBUILD=1 to run it.")
            return
        }

        let ctx = ModelContext(try container())
        let prospects = buildCorpus(ctx)
        let sources = buildSources(ctx)
        #expect(prospects.count == LiveShape.prospects)

        // The two whole-corpus derivations that can be called on their own, timed alone, so the split
        // between "work proportional to the store" and "work proportional to the rows" is measured
        // rather than argued. Both come from the code's own implementation, never a copy of it (L107).
        var engagementSeconds = 0.0
        var brandsSeconds = 0.0
        var totalSeconds = 0.0

        // A warm pass first, so the number is not dominated by first-touch faulting of 893 model objects.
        _ = QueueModel.items(from: prospects, sources: sources)

        engagementSeconds = seconds {
            _ = EngagementLink.group(prospects.map(EngagementLink.Row.init))
        }
        brandsSeconds = seconds {
            _ = ProducerGate.VenueBrands(
                shows: prospects.map { ProducerGate.Show(presenter: $0.presenter, venue: $0.venue) },
                overrides: .none)
        }
        totalSeconds = seconds {
            _ = QueueModel.items(from: prospects, sources: sources)
        }

        let remainder = totalSeconds - engagementSeconds - brandsSeconds
        let ms = { (s: Double) in String(format: "%.1f", s * 1000) }
        let share = { (s: Double) in String(format: "%.0f", totalSeconds > 0 ? s / totalSeconds * 100 : 0) }

        print("""
        queue-rebuild-cost: one rebuild of \(LiveShape.prospects) rows
          total                       \(ms(totalSeconds)) ms
          engagement grouping         \(ms(engagementSeconds)) ms  (\(share(engagementSeconds))%)
          presenter and venue walk    \(ms(brandsSeconds)) ms  (\(share(brandsSeconds))%)
          everything else             \(ms(remainder)) ms  (\(share(remainder))%)
        """)

        // The only assertion, and it is about the measurement being real rather than about the number:
        // a rebuild that took no measurable time at all means the corpus never got built or the call was
        // optimised away, and a zero would then be reported as a fast path (L102).
        #expect(totalSeconds > 0)
    }
}
