import Testing
import Foundation
import SwiftData

// #1992: time one render pass against a copy of the REAL store, not the fixture.
//
// `QueueRenderPassCostTests` pins how many whole-store sweeps a pass makes and, since #2048, how much
// per-card work it does. Neither is a time, and neither can be: both are counts, which is exactly what
// makes them stable enough to sit on the mandatory pre-push gate. What no count can see is a sweep that
// gets SLOWER without getting more numerous.
//
// AND THE FIXTURE CANNOT BE THE THING TIMED. Its container is `isStoredInMemoryOnly: true`, so it
// exercises no disk and no object materialisation, and every value in it is invented to fit a measured
// SHAPE rather than being the data itself. That is the right design for a guard (#3426, #2048) and the
// wrong one for a cost reading: the 275ms recorded on #1930 came from exactly that corpus and was then
// read as though it described Dan's store. It did not.
//
// So this reads the real thing, and reports a SPLIT rather than one number, because #1992's own point is
// that WHERE the time goes decides which fix is worth building:
//
//   1. fetch and materialise    the two @Query-equivalent table reads, which the in-memory fixture never
//                               pays and which happen twice per store notification
//   2. build the cards          QueueModel.items, including the recipient relationship access that only
//                               real data faults
//   3. the rest of the pass     everything else QueueRenderPass.make does
//
// PRIVACY. It prints counts and durations ONLY: never a name, a venue, an address or a URL. Anything a
// test prints reaches transcripts, terminal scrollback and whatever somebody pastes them into, by a route
// no repository scanner inspects (L222). The store it reads is Dan's real prospect data.
//
// OPT IN, like `QueueRebuildCostTests` and for its reason: it clones the store and runs a stopwatch, and
// a timing assertion on a shared Mac measures what else the machine is running (L224). Its AGE is what
// rides along on every push, through the `Queue rebuild cost:` readout (#2597).
@MainActor
@Suite("Queue render pass cost against the live store (#1992)")
struct QueueRenderPassLiveStoreCostTests {
    // `nonisolated` because Swift Testing evaluates `.enabled(if:)` in a Sendable closure outside the
    // suite's actor, and this suite is @MainActor for QueueRenderPass.make's sake. Neither property
    // touches main-actor state.
    nonisolated private static var liveStoreURL: URL {
        StoreLocation.storeURL(appSupport: StoreLocation.appSupport, isDebugBuild: false)
    }

    nonisolated private static var liveStoreExists: Bool {
        FileManager.default.fileExists(atPath: liveStoreURL.path)
    }

    private let sandboxes = TemporarySandboxes()

    // Through the ONE shared clone (#1672). Copying the .store, its -wal and its -shm one file at a time
    // races a live writer, and a clone whose -wal does not match the .store beside it makes whatever this
    // concludes a statement about a torn copy rather than about Dan's data.
    private func cloneLiveStore() throws -> URL {
        let dir = try sandboxes.make(named: "queue-live-cost")
        guard let clone = try LiveStoreClone.makeClone(in: dir) else {
            throw LiveStoreClone.Refusal.backupFailed("no live store on this machine")
        }
        return clone
    }

    private func openContainer(at url: URL) throws -> ModelContainer {
        let schema = Schema([Prospect.self, Recipient.self, Inquiry.self, OrgReachabilityAnswer.self,
                             WatchedSource.self, RefusedContactAddress.self,
                             PromotedProducer.self, DemotedHouse.self])
        return try ModelContainer(for: schema,
                                  configurations: [ModelConfiguration(schema: schema, url: url,
                                                                      cloudKitDatabase: .none)])
    }

    private func seconds(_ work: () -> Void) -> Double {
        let start = Date()
        work()
        return Date().timeIntervalSince(start)
    }

    @Test(.enabled(if: liveStoreExists, "no live store on this machine"))
    func measureOnePassAgainstTheLiveStore() throws {
        guard ProcessInfo.processInfo.environment["MEASURE_QUEUE_LIVE_STORE"] != nil else {
            // Not silently skipped: an instrument that says nothing is indistinguishable from one that
            // ran and found nothing (L98).
            print("queue-live-store-cost: not measured. Set TEST_RUNNER_MEASURE_QUEUE_LIVE_STORE=1 to run it.")
            return
        }

        let clone = try cloneLiveStore()
        let ctx = ModelContext(try openContainer(at: clone))

        // 1. What a @Query costs: the table read plus materialising every object. The in-memory fixture
        //    never pays this, and QueueView holds two such queries over the prospect table, so this is the
        //    term #1992 asks about by name.
        var prospects: [Prospect] = []
        var answers: [OrgReachabilityAnswer] = []
        var sources: [WatchedSource] = []
        let fetchSeconds = seconds {
            prospects = (try? ctx.fetch(FetchDescriptor<Prospect>())) ?? []
            answers = (try? ctx.fetch(FetchDescriptor<OrgReachabilityAnswer>())) ?? []
            sources = (try? ctx.fetch(FetchDescriptor<WatchedSource>())) ?? []
        }

        // A warm pass first, so the split below is not dominated by first-touch faulting.
        _ = QueueModel.items(from: prospects, answers: answers, corpus: prospects, sources: sources)

        // 2. Building the cards, which on real data includes faulting each show's recipients.
        let itemsSeconds = seconds {
            _ = QueueModel.items(from: prospects, answers: answers, corpus: prospects, sources: sources)
        }

        // 3. The whole pass, so the remainder is everything else QueueRenderPass.make does.
        let work = QueueRenderPass.WorkTally.measure {
            _ = QueueRenderPass.make(QueueRenderPass.Inputs(
                prospects: QueueRenderPass.Corpus(prospects),
                allProspects: QueueRenderPass.Corpus(prospects),
                inquiries: [], orgAnswers: answers, sources: sources,
                context: .at(QueueModel.easternToday(), now: Date()),
                focusedStage: .scout, focusedKeys: nil))
        }
        let passSeconds = seconds {
            _ = QueueRenderPass.make(QueueRenderPass.Inputs(
                prospects: QueueRenderPass.Corpus(prospects),
                allProspects: QueueRenderPass.Corpus(prospects),
                inquiries: [], orgAnswers: answers, sources: sources,
                context: .at(QueueModel.easternToday(), now: Date()),
                focusedStage: .scout, focusedKeys: nil))
        }

        let recipients = (try? ctx.fetch(FetchDescriptor<Recipient>()))?.count ?? 0
        let ms = { (s: Double) in String(format: "%.1f", s * 1000) }
        let rest = max(0, passSeconds - itemsSeconds)

        // Counts and durations only. Nothing here can name a show, a venue, a person or a URL.
        //
        // GROUPED so the arithmetic cannot be misread. The first version listed the fetch beside the
        // pass's own two halves above a line reading `whole pass`, and those three do not add up to it:
        // the fetch happens BEFORE the pass and is not part of it, so a reader summing the block got
        // 985 against a stated 813 and had no way to tell which was wrong. Anything printed here is a
        // figure somebody will quote out of context, so the groups are named and the end to end total is
        // stated rather than left to be computed (L118, L287).
        print("""
        queue-live-store-cost: one pass over the live store
          rows                        \(prospects.count)
          recipients                  \(recipients)

          BEFORE the pass, paid once per store change, twice where two queries read the table:
            fetch and materialise     \(ms(fetchSeconds)) ms
          THE PASS itself, which these two divide between them:
            build the cards           \(ms(itemsSeconds)) ms
            everything else           \(ms(rest)) ms
            the pass                  \(ms(passSeconds)) ms
          END TO END, the fetch plus the pass:
            total                     \(ms(fetchSeconds + passSeconds)) ms

          work units in the pass: \(work.queueItems) cards, \(work.sendGroupBuilds) send groups, \(work.draftLintRuns) draft lint runs
        """)

        // The only assertions, and both are about the measurement being REAL rather than about the
        // numbers, which move with whatever else this Mac is running (L224).
        #expect(!prospects.isEmpty, "the clone held no prospects, so this timed an empty store")
        #expect(passSeconds > 0, "a whole pass took no measurable time, so it never ran")
    }
}
