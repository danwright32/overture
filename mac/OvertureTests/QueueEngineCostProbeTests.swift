import Foundation
import SwiftData
import Testing

// #4358 (slice E1): what the queue engine's intake costs per change, on the live store's clone and on the 4x
// corpus, against plan v7's budget of 10 ms for intake and resolve at 5,376 shows.
//
// OPT IN, on #4106's rule for every probe of this kind: it clones Dan's store and runs a stopwatch, and a timing
// on a shared Mac measures whatever else the machine is doing (L224). Without the variable it says it did not
// run, rather than passing silently (L98):
//
//   TEST_RUNNER_MEASURE_4358_ENGINE=1 mac/scripts/run-tests-locked.sh \
//     -only-testing:OvertureTests/QueueEngineCostProbeTests
//
// Medians of five with their spread, Debug, load average beside each block (L395, L356). Counts and durations
// only, never a name (L222).
//
// THE VALUE PASS IS NOT TIMED HERE, and says so. Plan v7 projects 275 to 624 ms at 5,376 and 68 to 155 at
// 1,344 for `QueueRenderPass.make` over facts, which cannot run until every term is generic over the facts
// protocols and RenderData holds no model (#4357). Today's pass over models on the same corpus is timed beside
// the intake as the yardstick that projection is judged against, never as the value pass itself.
@Suite("#4358 queue engine intake cost (opt in, live store clone)")
@MainActor
final class QueueEngineCostProbeTests {

    private let sandboxes = TemporarySandboxes()

    private static var enabled: Bool { ProcessInfo.processInfo.environment["MEASURE_4358_ENGINE"] != nil }

    @Test(.enabled(if: Phase0.liveStoreExists, "no live store on this machine"))
    func intakeCostPerChangeAtOneAndFourTimesTheStore() async throws {
        guard Self.enabled else {
            print("engine-cost: not measured. Set TEST_RUNNER_MEASURE_4358_ENGINE=1 to run it.")
            return
        }
        let dir = try sandboxes.make(named: "engine-cost")
        guard let clone = try LiveStoreClone.makeClone(in: dir) else {
            throw LiveStoreClone.Refusal.backupFailed("no live store on this machine")
        }
        let big = try Phase0.scaledCopy(of: clone, factor: 4, in: dir)
        for (label, url) in [("live clone", clone), ("4x", big)] {
            let container = try Phase0.openContainer(at: url)
            container.mainContext.autosaveEnabled = false
            let context = container.mainContext
            let turns = EngineTurns()
            let clock = EngineTestClock()
            // A derivation that costs nothing, so each reading is the engine's own work and never a stand-in
            // pass's: the value pass's cost is a separate line below.
            let nothing = QueueEngineDerivation<Int>(derive: { $0.facts.shows.count },
                                                     differingFields: { $0 == $1 ? [] : ["shows"] },
                                                     nextChange: { _ in nil }, builtCardKeys: { _ in [] })
            func engine() -> QueueEngine<Int> {
                QueueEngine(context: context, derivation: nothing, saves: StoreSaveCount(),
                            clock: clock.clock,
                            events: QueueEngineSystemEvents(workspace: NotificationCenter(), system: NotificationCenter()),
                            schedule: turns.schedule, refused: { _, _ in })
            }
            // The full read, which is the start and the foreign save path (the launch fill is #4358 E3's).
            let fullRead = Phase0.median5 {
                let e = engine()
                e.start()
                turns.run()
            }
            let live = engine()
            live.start()
            turns.run()
            let shows = Prospect.inKeyOrder(try context.fetch(FetchDescriptor<Prospect>()))
            let rows = shows.count
            var sample = 0
            // One row edited and saved: the pass that takes it in (the tracker, the save's identifiers, the
            // resolve step, the re-read and the equality gate), timed from the turn's start to its end.
            var edits: [Double] = []
            var equals: [Double] = []
            var nights: [Double] = []
            for _ in 0..<5 {
                sample += 1
                let show = shows[(sample * 977) % rows]
                show.fitReason = "engine cost sample \(sample)"
                try Phase0.save(context, step: "engine cost edit")
                edits.append(Phase0.time { turns.run() })
                let same = shows[(sample * 389) % rows]
                same.groupName = same.groupName
                try Phase0.save(context, step: "engine cost equal write")
                equals.append(Phase0.time { turns.run() })
                for (i, row) in shows.enumerated() where (i + sample) % max(1, rows / 40) == 0 {
                    row.reprepDraftRequested.toggle()
                }
                try Phase0.save(context, step: "engine cost night")
                nights.append(Phase0.time { turns.run() })
            }
            let edit = Phase0.Reading(runs: edits)
            let equal = Phase0.Reading(runs: equals)
            let night = Phase0.Reading(runs: nights)

            // The yardstick: today's pass over models on the same corpus, the viewport's cards built.
            let inquiries = try context.fetch(FetchDescriptor<Inquiry>())
            let answers = try context.fetch(FetchDescriptor<OrgReachabilityAnswer>())
            let sources = try context.fetch(FetchDescriptor<WatchedSource>())
            let refusals = ContactRefusal.ledger(from: try context.fetch(FetchDescriptor<RefusedContactAddress>()))
            let overrides = ProducerOverrides(promotedRows: try context.fetch(FetchDescriptor<PromotedProducer>()),
                                              demotedRows: try context.fetch(FetchDescriptor<DemotedHouse>()))
            func pass(_ keys: Set<String>?) -> QueueView.RenderData {
                QueueRenderPass.make(QueueRenderPass.Inputs(
                    allProspects: QueueRenderPass.Corpus(shows), inquiries: inquiries, orgAnswers: answers,
                    sources: sources, refusals: refusals, overrides: overrides,
                    context: .at(QueueModel.easternToday(), now: Date()),
                    focusedStage: .scout, focusedKeys: nil, requestedCardKeys: keys))
            }
            let viewport = Set(pass([]).focusedRows.prefix(QueueViewportAssumption.rows).map(\.id))
            _ = pass(viewport)
            let today = Phase0.median5 { _ = pass(viewport) }
            print("""
                engine-cost [\(label)] \(Phase0.load())
                  shape                                     \(Phase0.shape(shows))
                  full read (start, or a foreign save)       \(fullRead.text)
                  pass taking in one edited row             \(edit.text)
                  pass taking in one equal-value write      \(equal.text)  (no derivation)
                  pass taking in about 40 rows in one save  \(night.text)
                  value pass over facts                     UNMEASURED: make over facts needs #4357 (plan: 68 to 155 ms at 1,344, 275 to 624 at 5,376)
                  today's pass over models, viewport cards  \(today.text)  (the yardstick)
                  engine passes \(live.counters.passes), rows read again \(live.counters.rowsReread), equal reads dropped \(live.counters.equalValueReads)
                """)
        }
    }
}
