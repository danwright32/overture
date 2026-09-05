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
                allProspects: QueueRenderPass.Corpus(prospects),
                inquiries: [], orgAnswers: answers, sources: sources,
                context: .at(QueueModel.easternToday(), now: Date()),
                focusedStage: .scout, focusedKeys: nil))
        }
        let passSeconds = seconds {
            _ = QueueRenderPass.make(QueueRenderPass.Inputs(
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

    // #3507: does the SECOND prospect query cost anything, or does SwiftData share the row cache?
    //
    // `QueueView` holds two `@Query` properties over `Prospect` (`QueueView.swift:26` and `:38`),
    // differing only in scope: one drops dismissed shows and sorts, the other is the whole-store corpus
    // the producer gate and inherited answers are judged against. The reading above times a fetch of the
    // table ONCE and calls it `fetch and materialise`, so the claim that a store notification pays that
    // term TWICE is arithmetic performed on one measurement rather than a measurement (L107).
    //
    // #3507's own direction says so and says what to do about it: "whether SwiftData actually
    // materialises twice or shares the row cache between two descriptors over one entity is an
    // assumption here, not a measurement", and "the first step is to time the two fetches separately and
    // confirm the second is not nearly free. If it is nearly free, this issue closes with that recorded."
    //
    // THREE fetches, not two, because two cannot tell the answers apart. A cheap second fetch could mean
    // either that this particular descriptor is cheap or that ANY repeat is cheap once the objects are
    // resident, and those imply different fixes. So: the corpus descriptor, then the queue's own filtered
    // and sorted one, then the corpus descriptor AGAIN.
    //
    // Each fetch is timed in TWO PARTS, the query and then a property touch over every row it returned,
    // because folding them into one number cannot answer the question. A `fetch` hands back objects whose
    // values may not have been read yet, so timing the call alone measures the query and not the
    // materialisation; timing them together cannot say which of the two a repeat actually re-pays, and
    // those imply different fixes. One query plus an in-memory filter removes the QUERY half and nothing
    // of the touch half, so the split is the whole decision.
    @Test(.enabled(if: liveStoreExists, "no live store on this machine"))
    func measureTheSecondProspectFetchOverTheSameTable() throws {
        guard ProcessInfo.processInfo.environment["MEASURE_QUEUE_LIVE_STORE"] != nil else {
            print("queue-live-store-second-fetch: not measured. Set TEST_RUNNER_MEASURE_QUEUE_LIVE_STORE=1 to run it.")
            return
        }

        let clone = try cloneLiveStore()
        let ctx = ModelContext(try openContainer(at: clone))

        // The app's own two descriptors, spelled the way `QueueView` spells them, so this measures the
        // queries that actually run rather than a pair written beside them (L107).
        let corpus = FetchDescriptor<Prospect>()
        let queueScope = FetchDescriptor<Prospect>(
            predicate: #Predicate<Prospect> { $0.statusRaw != "dismissed" },
            sortBy: [SortDescriptor(\Prospect.performanceDate, order: .forward),
                     SortDescriptor(\Prospect.fitScore, order: .reverse)])

        struct Reading { var rows = 0; var query = 0.0; var touch = 0.0
                         var total: Double { query + touch } }

        func fetchThenTouch(_ descriptor: FetchDescriptor<Prospect>) -> Reading {
            var r = Reading()
            var rows: [Prospect] = []
            r.query = seconds { rows = (try? ctx.fetch(descriptor)) ?? [] }
            var touched = 0
            r.touch = seconds {
                for row in rows where row.statusRaw.isEmpty == false { touched += 1 }
            }
            r.rows = touched
            return r
        }

        // #3507 asks whether the other views holding a prospect query share this cost. `RootView`'s
        // second one is the same SHAPE (a filtered descriptor beside an unfiltered one) and is measured
        // here rather than reasoned about from the two above, because it returns a far smaller set and
        // whether that matters is the whole question (L107).
        let keptToPrep = FetchDescriptor<Prospect>(predicate: PrepQueueBuilder.needsPrepPredicate)

        let first = fetchThenTouch(corpus)
        let second = fetchThenTouch(queueScope)
        let third = fetchThenTouch(corpus)
        let fourth = fetchThenTouch(keptToPrep)

        let ms = { (s: Double) in String(format: "%.1f", s * 1000) }
        let perRow = { (r: Reading) -> String in
            guard r.rows > 0 else { return "n/a" }
            return String(format: "%.3f", r.total / Double(r.rows) * 1000)
        }

        print("""
        queue-live-store-second-fetch: two @Query descriptors over one table (#3507)
                                     rows      query      touch      total   per row
          1. whole corpus, cold      \(first.rows)   \(ms(first.query)) ms   \(ms(first.touch)) ms   \(ms(first.total)) ms   \(perRow(first)) ms
          2. queue scope, filtered   \(second.rows)   \(ms(second.query)) ms   \(ms(second.touch)) ms   \(ms(second.total)) ms   \(perRow(second)) ms
          3. whole corpus, repeated  \(third.rows)   \(ms(third.query)) ms   \(ms(third.touch)) ms   \(ms(third.total)) ms   \(perRow(third)) ms
          4. RootView kept-to-prep    \(fourth.rows)   \(ms(fourth.query)) ms   \(ms(fourth.touch)) ms   \(ms(fourth.total)) ms   \(perRow(fourth)) ms

          Reading 3 against 1 is the answer to #3507. A repeat of the IDENTICAL descriptor, over objects
          the context already holds, is what one query plus an in-memory filter would remove. If it is
          near the cold figure the second query is paid in full; if it is near zero the row cache is
          shared and the change buys nothing.

          Read 2 against 3 as well, so a cheap second reading cannot be credited to the wrong cause: a
          filtered descriptor returning fewer rows is cheaper for that reason alone, and per-row is the
          column that separates the two.

          Row 4 is the sibling question. `RootView` holds the same two-query shape, so if the cost is
          per row returned rather than per query, its second one is cheap for a reason `QueueView`'s was
          not, and the two do not want the same fix.
        """)

        // The assertions are about the measurement being REAL, never about the numbers, which move with
        // whatever else this Mac is running (L224). A run where a fetch returned no rows would report a
        // reassuring near-zero for the emptiest possible reason (L98).
        #expect(first.rows > 0, "the corpus fetch touched no rows, so nothing was materialised")
        #expect(second.rows > 0, "the queue-scope fetch touched no rows, so its timing means nothing")
        #expect(third.rows == first.rows, "the repeated corpus fetch saw a different table than the first")
        #expect(second.rows < first.rows, "the queue scope returned the whole table, so its predicate did nothing")
        #expect(first.query > 0, "the first query took no measurable time, so it never ran")
        #expect(fourth.rows >= 0, "the kept-to-prep descriptor could not be run at all")
    }
}
