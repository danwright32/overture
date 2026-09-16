import Testing
import Foundation

// #3908: how much of a scout sweep is re-normalizing the same names, measured before anything is cached.
//
// WHAT THE ISSUE CLAIMS, and it is the reason this exists rather than a cache. `HistoryMatch.
// matchRelationship` normalizes BOTH names on every comparison, and one event is compared against every
// Downbeat client and every history record: measured 2026-09-13, 31 clients and 46 history records, so
// a single event re-derives the same 77 names and a sweep does that once per event. The proposed fix is
// to normalize each name ONCE per sweep. The issue also says, in its own words, to measure first,
// because the lists are small and the win may not be worth the shape.
//
// So this measures the CEILING on that win rather than assuming it. Three arms in one run, because a
// figure from one arm compared with a figure from another day is reading the machine (L395):
//
//   THE SWEEP        `ScoutClassify.run` over the events, as it ships.
//   NO CORPUS        the same sweep with no clients and no history, so nothing is compared at all.
//                    The difference is everything the matching costs, cache or no cache.
//   NORMALIZING      `GroupNameMatch.tokens` over the 77 corpus names, once per event, which is exactly
//                    the work a per-sweep cache would remove and nothing else. It is an UPPER BOUND:
//                    a real cache still pays it once per sweep and still pays every comparison.
//
// WHAT IT CANNOT SAY. It is a fixture, sized from the dated counts above rather than from Dan's export,
// so it under-represents production the day those lists grow (L354). The sizes are printed with the
// reading for exactly that reason. It also cannot say what the SHAPE of a cache would cost to maintain,
// which is the other half of the issue's question and is a judgement rather than a measurement.
@Suite("What a scout sweep spends on re-normalizing the same names (#3908)")
struct ScoutClassifyMatchCostTests {

    // From the issue's own measurement, 2026-09-13. Named rather than inlined so the reading can print
    // what it was sized against instead of asserting a number nobody can check (L48, L354).
    static let measuredClients = 31
    static let measuredHistory = 46
    // A sweep's worth of events. Larger than any one source so the per event cost is readable above the
    // noise; the reading is reported per event as well as whole.
    static let events = 400

    private static func clients() -> [DownbeatClient] {
        (0..<measuredClients).map { n in
            DownbeatClient(id: "c\(n)",
                           displayName: "The \(["Sinfónica", "Chamber", "Baroque", "Choral"][n % 4]) "
                               + "Society of \(["Brooklyn", "Morningside", "Tribeca"][n % 3]) \(n)",
                           shortName: n % 3 == 0 ? "TCS\(n)" : nil,
                           email: "c\(n)@example.org", contractEmail: "c\(n)@example.org",
                           phoneNumber: nil, isTaxExempt: nil, hasLeftReview: false,
                           specialBehaviors: [], notes: nil, hostingSite: "")
        }
    }

    private static func history() -> [HistoryRecord] {
        (0..<measuredHistory).map { n in
            // The messy shapes the normalizer exists for: an org line, a "Presented by" prefix, and a
            // subtitle after a dash. A fixture of clean single line names would measure a different
            // function from the one that runs (L48).
            HistoryRecord(groupName: n % 3 == 0
                            ? "Presented by the \(["Éclat", "Meridian", "Harbor"][n % 3]) Ensemble \(n)"
                            : "\(["Éclat", "Meridian", "Harbor"][n % 3]) Ensemble \(n) - An Evening of Song",
                          status: ["booked", "contacted", "lost_soft", "passed"][n % 4],
                          origin: n % 2 == 0 ? .bookingImport : .overtureActivity)
        }
    }

    private static func extracted() -> [ExtractedEvent] {
        (0..<events).map { n in
            ExtractedEvent(title: "\(["Éclat", "Meridian", "Harbor", "Aurora"][n % 4]) Ensemble \(n) "
                               + "- \(["Winter Songs", "A Recital", "New Works"][n % 3])",
                           presenter: n % 2 == 0 ? "The Chamber Society of Brooklyn \(n % 7)" : nil,
                           venue: "Weill Recital Hall",
                           performanceDate: "2027-03-1\(n % 9)",
                           sourceUrl: nil)
        }
    }

    private func seconds(_ work: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        work()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
    }

    private func median(_ work: () -> Void) -> (median: Double, low: Double, high: Double) {
        var runs: [Double] = []
        for _ in 0..<5 { runs.append(seconds(work)) }
        runs.sort()
        return (runs[2], runs[0], runs[4])
    }

    @Test func measureWhatRenormalizingCosts() {
        guard ProcessInfo.processInfo.environment["MEASURE_SCOUT_MATCH"] != nil else {
            // Not silently skipped: an instrument that says nothing is indistinguishable from one that
            // ran and found nothing (L98).
            print("scout-match-cost: not measured. Set TEST_RUNNER_MEASURE_SCOUT_MATCH=1 to run it.")
            return
        }

        let clients = Self.clients()
        let history = Self.history()
        let events = Self.extracted()
        let brands = ProducerGate.VenueBrands.none

        func sweep(clients: [DownbeatClient], history: [HistoryRecord]) {
            _ = ScoutClassify.run(events: events, clients: clients, history: history,
                                  venueBrands: brands, sourceIds: [])
        }

        _ = sweep(clients: clients, history: history)          // warm
        let whole = median { sweep(clients: clients, history: history) }
        _ = sweep(clients: [], history: [])
        let noCorpus = median { sweep(clients: [], history: []) }

        // The names a cache would hold: every client name and every history name, tokenized once per
        // event, which is what the sweep does today and what a per-sweep cache would do once.
        let corpusNames = clients.flatMap { HistoryMatch.clientNames($0) } + history.map(\.groupName)
        _ = corpusNames.map(GroupNameMatch.tokens)
        let normalizing = median {
            for _ in 0..<Self.events { _ = corpusNames.map(GroupNameMatch.tokens) }
        }

        let matching = whole.median - noCorpus.median
        func ms(_ s: Double) -> String { String(format: "%.1f", s * 1000) }
        func each(_ s: Double) -> String { String(format: "%.3f", s * 1000 / Double(Self.events)) }

        print("""
        scout-match-cost: one sweep of \(Self.events) events against \(clients.count) clients and \
        \(history.count) history records
          Sized from the counts #3908 measured on 2026-09-13, not from Dan's export, so it says what \
        the shape costs at THAT size and nothing about the day those lists grow (L354).

          the sweep as it ships      \(ms(whole.median)) ms   (\(each(whole.median)) ms an event)
          the same with no corpus    \(ms(noCorpus.median)) ms   (\(each(noCorpus.median)) ms an event)
          so everything the matching costs
                                     \(ms(matching)) ms
          of which re-normalizing the \(corpusNames.count) corpus names, once per event, which is the
          ENTIRE ceiling on what a per-sweep cache could remove:
                                     \(ms(normalizing.median)) ms
          that ceiling as a share of the whole sweep: \
        \(String(format: "%.1f", 100 * normalizing.median / whole.median))%
        """)

        // The controls, asserted, so a reading of "nothing to save" cannot be a harness that measured
        // nothing (L159, L98).
        #expect(whole.median > noCorpus.median, """
            the sweep with a corpus must cost more than the sweep with none, or this harness is not \
            exercising the matching at all and every number above is noise
            """)
        #expect(normalizing.median > 0, "the normalizing arm measured no time at all")
    }
}
