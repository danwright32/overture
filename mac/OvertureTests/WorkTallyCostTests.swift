import Testing
import Foundation
import SwiftData

// #3500: what the per-card counters COST on the path this milestone exists to make cheaper.
//
// `QueueRenderPass.WorkTally`'s three entry points read a task local before deciding whether to count,
// and one render pass makes roughly 2,300 of those calls on the refreshed fixture, every one on the main
// thread. The source said the cost was "one task-local read per counted call, which is nil, and then
// nothing", and `nothingIsCountedWhenNobodyIsMeasuring` asserts only that no tally is LEFT BEHIND, which
// is a different claim: it proves no counting happened, never that asking was free. A task-local read
// walks the task's local storage rather than reading a plain global, so it is not obviously free.
//
// That is L353, and the lesson was minted from this app: name the quantity the cost scales with and what
// bounds it, because an estimate is a measurement nobody took. The quantity scales with the row count,
// which grows every night.
//
// HOW IT IS MEASURED, and what that can and cannot say.
//
// The calls cannot be REMOVED without a build flag, so what is timed instead is the same operation at the
// same volume: one pass is run to COUNT the calls it makes, then that many `record` calls are made
// directly with no tally bound, which is exactly what the app does. The share is computed against a pass
// timed in the SAME RUN, because a fixed millisecond figure measures what else this Mac is running
// (L224, and this suite's neighbours record the same rule).
//
// What it cannot see is a compiler that would have optimised the calls away entirely had they never been
// written. That is not the question #3500 asks: the calls exist, the app makes them, and this is what
// making them costs.
@MainActor
@Suite("What the per-card counters cost (#3500)")
struct WorkTallyCostTests {

    private static let corpusSize = 1142

    // A generous ceiling, set from the measured share and deliberately far above it rather than at a
    // round number just over it: the reading below is a small fraction of one percent, so anything
    // approaching this is a change in kind rather than noise (L172). It is a SHARE, never a duration.
    private static let allowedShareOfOnePass = 0.05

    private func container() throws -> ModelContainer {
        try ModelContainer(
            for: Schema([Prospect.self, Recipient.self, Inquiry.self, OrgReachabilityAnswer.self,
                         WatchedSource.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func seed(_ ctx: ModelContext) -> [Prospect] {
        let dates = LiveDateClustering.dates(forRows: Self.corpusSize)
        var rows: [Prospect] = []
        for n in 0..<Self.corpusSize {
            let p = Prospect(naturalKey: "row-\(n)", groupName: "Ensemble \(n % 90)", discipline: "music",
                             venue: "Venue \(n % 169) Hall", performanceDate: dates[n],
                             sourceListingURL: nil, priorRelationship: "none",
                             production: n % 3 == 0 ? "self" : "presenter", profile: "strong",
                             coverage: "likely_uncovered", fitScore: 4 + (n % 5), tier: "mid",
                             fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                             possibleMatchName: nil, status: n % 3 == 0 ? .drafted : .new)
            p.presenter = "Ensemble \(n % 90) Presents"
            p.location = "New York, NY"
            ctx.insert(p)
            rows.append(p)
        }
        try? ctx.save()
        return rows
    }

    private func inputs(_ rows: [Prospect]) -> QueueRenderPass.Inputs {
        QueueRenderPass.Inputs(
            allProspects: QueueRenderPass.Corpus(rows),
            inquiries: [], orgAnswers: [],
            context: .at("2026-08-02", now: Date(timeIntervalSince1970: 1_785_000_000)),
            focusedStage: .scout, focusedKeys: nil)
    }

    private func seconds(_ work: () -> Void) -> Double {
        let start = Date()
        work()
        return Date().timeIntervalSince(start)
    }

    // ONE test, one seed, and four passes rather than two tests seeding twice: this rides along on the
    // mandatory pre-push gate, so its own cost is part of the answer it gives (#3435 2f).
    @Test func askingCostsALotLessThanThePassItRidesOn() throws {
        let ctx = ModelContext(try container())
        let rows = seed(ctx)

        // How many times a pass asks. Taken with a tally bound, which is the only way to count them, and
        // it doubles as the warm pass so the timings below are not dominated by first touch.
        let counted = QueueRenderPass.WorkTally.measure { _ = QueueRenderPass.make(inputs(rows)) }
        let calls = counted.queueItems + counted.sendGroupBuilds + counted.draftLintRuns

        // The pass, as the APP runs it: no tally bound anywhere, so every `record` call reads a nil task
        // local and returns.
        let passSeconds = seconds { _ = QueueRenderPass.make(inputs(rows)) }

        // The same number of asks, in isolation, also with no tally bound. Split across the three entry
        // points in the proportion the pass uses them, so this measures what the pass really does rather
        // than one entry point repeated.
        let askingSeconds = seconds {
            for _ in 0..<counted.queueItems { QueueRenderPass.WorkTally.recordQueueItem() }
            for _ in 0..<counted.sendGroupBuilds { QueueRenderPass.WorkTally.recordSendGroupBuild() }
            for _ in 0..<counted.draftLintRuns { QueueRenderPass.WorkTally.recordDraftLintRun() }
        }

        // And the other half of the claim, which the source comment did not make: BINDING a tally is the
        // part that could cost, and only a test ever does it. Reported, never pinned, because it bounds
        // nothing the app pays.
        let boundSeconds = seconds {
            _ = QueueRenderPass.WorkTally.measure { _ = QueueRenderPass.make(inputs(rows)) }
        }

        let share = passSeconds > 0 ? askingSeconds / passSeconds : 1
        let bindingRatio = passSeconds > 0 ? boundSeconds / passSeconds : 0
        print("""
        work-tally-cost: what asking costs, against the pass it rides on (#3500)
          calls in one pass         \(calls)
          one pass, no tally        \(String(format: "%.1f", passSeconds * 1000)) ms
          the same asks, alone      \(String(format: "%.3f", askingSeconds * 1000)) ms
          share of one pass         \(String(format: "%.3f%%", share * 100))
          with a tally BOUND        \(String(format: "%.1f", boundSeconds * 1000)) ms  (\(String(format: "%.2fx", bindingRatio)))

          Measured rather than reasoned about (L82). Read the SHARE, never the milliseconds: a fixed
          figure measures what else this Mac was running at the time (L224). The bound figure is a test's
          cost and never the app's, which binds no tally anywhere.
        """)

        // The assertions are about the measurement being real first, and only then about the number,
        // because a run where the pass did nothing would report a reassuring tiny share (L98).
        #expect(calls > 1000, "a pass made only \(calls) counted calls, so this timed almost nothing")
        #expect(passSeconds > 0, "a pass took no measurable time, so the share below is meaningless")
        #expect(boundSeconds > 0, "the bound pass took no time, so its ratio means nothing")
        #expect(share < Self.allowedShareOfOnePass,
                Comment(rawValue: "asking cost \(String(format: "%.2f%%", share * 100)) of one pass. "
                        + "The counters are supposed to be a task-local read that finds nil. If this is "
                        + "real rather than a loaded Mac, the fix is to compile them out of the build Dan "
                        + "runs, which is a real trade: a counter absent from Release cannot catch a "
                        + "regression that only appears there (#3500, #3435)."))
    }
}
