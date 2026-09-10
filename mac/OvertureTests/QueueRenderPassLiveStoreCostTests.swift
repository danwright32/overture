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
// KNOWN AND MEASURED, so nobody has to re-diagnose it: with three tests each cloning the store, the run
// prints `BUG IN CLIENT OF libsqlite3.dylib: ... vnode unlinked while in use` three times, once per
// clone. A SwiftData container holds its sqlite connection until it is deallocated and nothing here can
// make that happen on demand, so the sandbox is removed while the connection is still open.
//
// Measured 2026-09-05 rather than assumed: with two tests it printed nothing; with three it printed nine
// times, which one container per test and a fresh CONTEXT per reading brought down to three; making the
// suite a `final class`, so Swift Testing releases an instance per test, did not change it. The integrity
// it complains about is a THROWAWAY CLONE's, never Dan's store, which is read only and never opened here.
// Recorded rather than chased: this is an opt-in diagnostic and the alternative is leaving a clone behind,
// which is the leak #3065 exists to prevent.
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

    // #3660 Phase 10: how many rows a frame draws, as a STATED figure rather than a guess at the size
    // of Dan's window. Twelve is above what a laptop window shows and below what a tall one does, so the
    // narrowed reading is a conservative one: a real viewport is more likely to be smaller than this than
    // larger, which makes the measured saving a floor rather than a best case.
    private static let viewportRows = 12

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

    // #3660 Phase 10: how many samples every reading below is the MEDIAN of.
    //
    // A single reading is not a yardstick (L656). Measured 2026-09-09 while adding the narrowed arm: the
    // pass with no card and the same pass with twelve came out 442 ms and 435 ms, in that order, which
    // cannot be true (the second contains the first) and is simply what a difference smaller than the
    // run-to-run noise looks like on a shared Mac (L224). Both those numbers were real; neither was a
    // yardstick. The median of several is.
    private static let samples = 5

    /// The MEDIAN of `samples` runs, not the mean and not one reading. The median because these
    /// distributions have a long right tail (another process waking is a slow sample, and nothing makes a
    /// sample artificially fast), so a mean tracks whatever else this Mac happened to do.
    ///
    /// It also returns the spread, because a median quoted without one is a number nobody can tell a
    /// stable reading from a noisy one by (L172, L395).
    private func medianSeconds(_ work: () -> Void) -> (median: Double, low: Double, high: Double) {
        var runs: [Double] = []
        for _ in 0..<Self.samples { runs.append(seconds(work)) }
        runs.sort()
        return (runs[runs.count / 2], runs.first ?? 0, runs.last ?? 0)
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
        func makePass(cardKeys: Set<String>?) -> QueueView.RenderData {
            QueueRenderPass.make(QueueRenderPass.Inputs(
                allProspects: QueueRenderPass.Corpus(prospects),
                inquiries: [], orgAnswers: answers, sources: sources,
                context: .at(QueueModel.easternToday(), now: Date()),
                focusedStage: .scout, focusedKeys: nil,
                requestedCardKeys: cardKeys))
        }
        let work = QueueRenderPass.WorkTally.measure { _ = makePass(cardKeys: nil) }
        let pass = medianSeconds { _ = makePass(cardKeys: nil) }
        let passSeconds = pass.median

        // 4. #3660 Phase 10: THE PASS THE APP ACTUALLY RUNS, which is the one nothing here measured.
        //
        // THIS IS THE CORRECTION, and it is worth reading before the numbers. Every timing in this file
        // called `QueueModel.items(from:)` and left `requestedCardKeys` at nil, which means a card for
        // EVERY show in scope. Since #3654 the app asks for the keys the last frame drew, so the arm this
        // instrument was timing has not been the shipping arm since that merged, while the readout on
        // every push went on saying `Queue rebuild cost` (L400, L63: a check's NAME is not a statement of
        // its coverage, and an instrument aimed at the wrong arm keeps reporting a number nobody can act
        // on).
        //
        // The viewport is a STATED size rather than a guess at Dan's window, and the per-card marginal
        // cost is printed beside it so the reading generalises to a taller one instead of being true only
        // of this number (L172, L316).
        // 5. #3660 Phase 10: the PREAMBLE alone, with no card built at all.
        //
        // The fourth arm, and the one that changes what to do next. `QueueModel.scope` derives the
        // whole-corpus tables (the engagement clustering, the presenter-against-venue walk, the
        // organisation row counts, the inherited answer ledger) BEFORE it builds a single card, and every
        // one of them is over the whole store whatever the card set says. Narrowing the cards provably
        // cannot touch them, which is what makes them the term to read: without this arm the difference
        // between the two arms above reads as "the pass got cheaper" with no way to see how much of it
        // never could (L507, a remainder nobody records is where the unexplained cost accumulates).
        _ = QueueModel.scope(from: prospects, answers: answers, corpus: prospects, sources: sources,
                             cardKeys: [])
        let preamble = medianSeconds {
            _ = QueueModel.scope(from: prospects, answers: answers, corpus: prospects, sources: sources,
                                 cardKeys: [])
        }
        let preambleSeconds = preamble.median

        let focused = makePass(cardKeys: nil).focusedRows
        let viewport = Set(focused.prefix(Self.viewportRows).map(\.id))
        _ = makePass(cardKeys: viewport)                    // warm, as above
        let narrowedWork = QueueRenderPass.WorkTally.measure { _ = makePass(cardKeys: viewport) }
        let narrowed = medianSeconds { _ = makePass(cardKeys: viewport) }
        let narrowedSeconds = narrowed.median

        // 6. THE FLOOR: the same pass with NO card at all.
        //
        // The number that decides what is worth building next, and the one no arm above can give. Every
        // arm that builds cards mixes two costs, so "the pass got cheaper" says nothing about how much of
        // it COULD get cheaper. This is the part narrowing provably cannot reach: the whole-corpus tables,
        // a row for every show, the stage navigation, the reached-out sweep, the geography and the date
        // grouping. Measured over the pass's OWN corpus rather than over a differently scoped one, so it
        // is a component of the readings above rather than a number beside them (L118).
        _ = makePass(cardKeys: [])
        let floor = medianSeconds { _ = makePass(cardKeys: []) }
        let floorSeconds = floor.median

        // 7. #3660 Phase 10: WHERE INSIDE THE FLOOR the time goes.
        //
        // The floor is 99% of the shipping pass, so "the pass is expensive" is now a statement about
        // these terms and nothing else. Without this split the only available next step is to chunk the
        // whole thing, which is a large and risky change aimed at a cost nobody has located: a remainder
        // that is never decomposed is exactly where the unexplained time accumulates (L507).
        //
        // Each term is timed AS THE PASS CALLS IT, over the pass's own corpus, so these are components of
        // the floor above rather than numbers beside it (L118). They will not sum to it exactly: the pass
        // also allocates the RenderData and runs the terms not listed here, and any one reading carries
        // the noise its own spread reports.
        let everyProspect = prospects
        let inQueue = QueueRenderPass.Corpus(prospects).narrowed(QueueModel.queueScope)
        let baseContext = StageContext.at(QueueModel.easternToday(), now: Date())
        _ = baseContext.resolvingPlaces(of: inQueue.all)
        let geoTerm = medianSeconds { _ = baseContext.resolvingPlaces(of: inQueue.all) }
        let resolved = baseContext.resolvingPlaces(of: inQueue.all)

        let scopeTerm = medianSeconds {
            _ = QueueModel.scope(from: inQueue.all, answers: answers, corpus: everyProspect,
                                 sources: sources, clients: resolved.clients, now: resolved.now,
                                 cardKeys: [], today: resolved.today)
        }
        let reachedOutTerm = medianSeconds {
            _ = ReachedOutQueue.activeWithDates(from: inQueue.all, now: resolved.now)
        }
        let reachedOutKeys = Set(ReachedOutQueue.activeWithDates(from: inQueue.all,
                                                                now: resolved.now)
            .map(\.prospect.naturalKey))
        // #3738: the pass decides every show's stages ONCE and reads that table four ways, so the
        // decomposition is the table plus its projections rather than four independent sweeps. Timed the
        // other way the four lines each rebuilt the table and their sum exceeded the floor they are
        // components of, which is the arithmetic saying the split was wrong rather than the floor (L118).
        let placeTerm = medianSeconds { _ = StageNavigation.placements(in: inQueue.all, context: resolved) }
        // #3742: the SCOUT arm of the stage rule, which is 32.3 ms of the placement's 59.1 ms, measured by
        // reducing `countedFocuses` to one focus at a time. It walks no recipients; what it does is ask
        // whether each show is inside the lead-time window, and that runs `EasternDate.daysUntil`, which
        // is TWO `DateFormatter` parses per show. One of the two is `today`, the same string every time.
        //
        // Timed here so the claim is a number rather than a reading of the code (L107).
        let leadTimeTerm = medianSeconds {
            for p in inQueue.all {
                _ = QueueModel.isWithinOrdinaryLeadTime(performanceDate: p.performanceDate,
                                                        today: resolved.today)
            }
        }
        // And one parse on its own, over the same count, so the term above can be read as parses rather
        // than as an unexplained cost.
        let dayParseTerm = medianSeconds {
            for p in inQueue.all { _ = EasternDate.date(from: p.performanceDate ?? "2027-01-01") }
        }
        let placement = StageNavigation.placements(in: inQueue.all, context: resolved)
        let stageTerm = medianSeconds {
            _ = StageNavigation.queueKeys(in: placement, reachedOutKeys: reachedOutKeys)
        }
        let fanOutTerm = medianSeconds { _ = QueueRenderPass.fanOutWarning(inQueue.all) }

        // INSIDE `QueueModel.scope`, which is the largest term left once #3737 and #3738 landed.
        //
        // Same rule as the floor above: a remainder nobody decomposes is where the unexplained cost sits
        // (L507). These are the pieces reachable from a test; `inheritedAnswers` and the card build are
        // not, and what they cost shows up as this block's own remainder rather than being guessed at.
        let engagementTerm = medianSeconds {
            _ = EngagementLink.group(inQueue.all.map(EngagementLink.Row.init))
        }
        // #3743: the index is SHARED now, so the two terms that need it are timed with one in hand and
        // the index is timed once on its own. Measured the other way each rebuilt it and the block stopped
        // mirroring the pass, which is the same correction #3738 made to the stage terms (L118).
        let producerIndex = ProducerGate.Corpus(everyProspect.map {
            ProducerGate.Show(presenter: $0.presenter, venue: $0.venue)
        })
        let brandsTerm = medianSeconds {
            _ = ProducerGate.VenueBrands(corpus: producerIndex, overrides: .none)
        }
        let rowCountsTerm = medianSeconds {
            _ = QueueModel.organisationRowCounts(everyProspect.map(\.presenter))
        }
        // The row loop: one contacts walk and one `QueueScopeRow` per show, which is what `scope` does
        // for every show whatever the card set says.
        let rowsTerm = medianSeconds {
            for p in inQueue.all { _ = QueueScopeRow(p, facts: RecipientFacts.of(p)) }
        }
        // And the contacts walk ALONE, so the row's own cost can be told from the cost of reaching its
        // contacts. They are one line in the loop and two very different things to fix.
        let contactsTerm = medianSeconds {
            for p in inQueue.all { _ = RecipientFacts.of(p) }
        }
        // #3743: the term #3741 could not reach, which was almost all of that block's 41.3 ms remainder.
        //
        // It is SKIPPED ENTIRELY when the stored ledger is empty (`guard !answers.isEmpty`), so a reading
        // of zero here would mean the clone held no organisation answers rather than the work being free.
        // The count is printed beside it for exactly that reason (L98).
        // #3743: the index BOTH of the two big terms need, over the same corpus, in the same pass. They
        // used to build one each; `QueueModel.scope` builds it once and hands it to both now. Timed on
        // its own so the shared part is a line rather than something folded into whichever term happens
        // to be measured first (L370, L118).
        let producerCorpusTerm = medianSeconds {
            _ = ProducerGate.Corpus(everyProspect.map {
                ProducerGate.Show(presenter: $0.presenter, venue: $0.venue)
            })
        }
        let inheritedTerm = medianSeconds {
            _ = QueueModel.inheritedAnswers(answers, corpus: everyProspect, overrides: .none,
                                            refusals: .none, heldKeys: [], now: resolved.now,
                                            producerCorpus: producerIndex)
        }
        let scopeNamed = engagementTerm.median + brandsTerm.median + rowCountsTerm.median
            + rowsTerm.median + inheritedTerm.median + producerCorpusTerm.median

        // The terms the first decomposition left out, chased because they were the REMAINDER: the five
        // above came to 154 ms of a 421.7 ms floor, and a remainder that large is where the answer is
        // (L507). Timed in the same way, over the same corpus.
        let rowsForTerms = QueueModel.scope(from: inQueue.all, answers: answers, corpus: everyProspect,
                                            sources: sources, clients: resolved.clients,
                                            now: resolved.now, cardKeys: [], today: resolved.today).rows
        let agentTerm = medianSeconds {
            _ = AgentInputs.from(prospects: inQueue.all, allProspects: everyProspect, inquiries: [],
                                 context: resolved, gmailConnected: false,
                                 runInFlight: nil, replyRunAlive: false, placement: placement)
        }
        let focusedTerm = medianSeconds {
            _ = Set(StageNavigation.focusedKeys(stage: .scout, leadKeys: [], in: placement))
        }
        let selfBookingTerm = medianSeconds { _ = QueueModel.selfBookingIndex(rowsForTerms) }
        let pendingTerm = medianSeconds { _ = QueueModel.pendingBookingCount(rowsForTerms) }
        let groupTerm = medianSeconds { _ = QueueModel.groupByDate(rowsForTerms) }

        let named = geoTerm.median + scopeTerm.median + reachedOutTerm.median + stageTerm.median
            + placeTerm.median
            + fanOutTerm.median + agentTerm.median + focusedTerm.median + selfBookingTerm.median
            + pendingTerm.median + groupTerm.median
        let unaccounted = max(0, floorSeconds - named)

        let recipients = (try? ctx.fetch(FetchDescriptor<Recipient>()))?.count ?? 0
        let ms = { (s: Double) in String(format: "%.1f", s * 1000) }
        // #3660: this difference stopped being meaningful once the pass got cheaper than the standalone
        // build it subtracts, and it printed `0.0 ms`, which reads as a real measurement of nothing (L98).
        //
        // It was always two corpora (`itemsSeconds` builds over the whole store, the pass over its own
        // non-dismissed scope), and while the pass was the dearer of the two the difference was at least
        // a positive number with a caveat. Now that #3737 and #3738 have taken the pass below it, the
        // subtraction is negative and clamping it to zero states a measurement nobody took. So it says
        // which it is instead. The line is kept rather than deleted because every earlier reading of this
        // instrument was quoted from it (L277).
        let rest = passSeconds - itemsSeconds
        let restLabel = rest > 0
            ? "\(ms(rest)) ms"
            : "not meaningful: the pass is now CHEAPER than a whole-store card build, and the two "
              + "measure different corpora. Read THE FLOOR below."
        // The marginal card, derived from the two arms rather than assumed: the difference in time over
        // the difference in cards built. Stated so a taller window can be priced without re-measuring,
        // and so a reader can tell a pass that got cheaper from one that merely built fewer cards.
        let spread = { (r: (median: Double, low: Double, high: Double)) in
            "(\(Self.samples) runs, \(ms(r.low)) to \(ms(r.high)))"
        }
        let floorShare = narrowedSeconds > 0
            ? String(format: "%.0f%%", floorSeconds / narrowedSeconds * 100)
            : "not measurable"
        let extraCards = work.queueItems - narrowedWork.queueItems
        let perCard = extraCards > 0
            ? String(format: "%.3f", (passSeconds - narrowedSeconds) * 1000 / Double(extraCards))
            : "not measurable, both arms built the same number of cards"

        // Counts and durations only. Nothing here can name a show, a venue, a person or a URL.
        //
        // #3660 Phase 10: `the pass minus that` is a DIFFERENCE and not a component, and the label says
        // so now. `itemsSeconds` times a standalone `QueueModel.items` over the whole store, while the
        // pass derives its own scope over the non-dismissed subset, so subtracting one from the other
        // mixes two corpora. It was labelled `everything else` and read as the pass's non-card half,
        // which the floor arm below shows it is not: the pass with no card at all is 99% of the narrowed
        // pass, not 23% of it. Kept rather than deleted, because it is the number every earlier reading
        // of this instrument was quoted from and removing it would leave those unexplainable (L277).
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
          THE PASS itself, EVERY card built, which is what this instrument measured before #3660:
            a whole-store card build  \(ms(itemsSeconds)) ms
            the pass minus that       \(restLabel)
            the pass                  \(ms(passSeconds)) ms   \(spread(pass))
          END TO END, the fetch plus the pass:
            total                     \(ms(fetchSeconds + passSeconds)) ms

          work units in the pass: \(work.queueItems) cards, \(work.sendGroupBuilds) send groups, \(work.draftLintRuns) draft lint runs

          NARROWED to what a frame draws (#3654), which is the arm the app actually runs:
            viewport                  \(viewport.count) rows of \(focused.count) in the focused stage
            the pass                  \(ms(narrowedSeconds)) ms   \(spread(narrowed))
            END TO END with the fetch \(ms(fetchSeconds + narrowedSeconds)) ms
            work units                \(narrowedWork.queueItems) cards, \(narrowedWork.sendGroupBuilds) send groups, \(narrowedWork.draftLintRuns) draft lint runs
            marginal cost per card    \(perCard) ms

          THE FLOOR, the same pass with NO card built, which narrowing cannot reach:
            the pass                  \(ms(floorSeconds)) ms   \(spread(floor))
            share of the narrowed arm \(floorShare)
            of which the whole-corpus tables plus a row per show, over EVERY row in the store,
            which is a wider corpus than the pass's own and so reads dearer than the
            `QueueModel.scope` line below it. Two corpora, not two answers (L118):
                                      \(ms(preambleSeconds)) ms   \(spread(preamble))

          INSIDE THE FLOOR, each term timed as the pass calls it, over the pass's own corpus.
          These do not sum to the floor: the pass runs more than these and each carries its own noise.
            resolve every show's place \(ms(geoTerm.median)) ms   \(spread(geoTerm))
            QueueModel.scope, no cards \(ms(scopeTerm.median)) ms   \(spread(scopeTerm))
            reached-out sweep          \(ms(reachedOutTerm.median)) ms   \(spread(reachedOutTerm))
            place every show's stages \(ms(placeTerm.median)) ms   \(spread(placeTerm))
              of which the lead-time window, over every row:
                                       \(ms(leadTimeTerm.median)) ms   \(spread(leadTimeTerm))
              and one day-string parse each, for comparison:
                                       \(ms(dayParseTerm.median)) ms   \(spread(dayParseTerm))
            masthead membership        \(ms(stageTerm.median)) ms   \(spread(stageTerm))
            possible-match fan-out     \(ms(fanOutTerm.median)) ms   \(spread(fanOutTerm))
            pill counts, from the table \(ms(agentTerm.median)) ms   \(spread(agentTerm))
            focused rows, from the table \(ms(focusedTerm.median)) ms   \(spread(focusedTerm))
            self-booking night index   \(ms(selfBookingTerm.median)) ms   \(spread(selfBookingTerm))
            pending booking count      \(ms(pendingTerm.median)) ms   \(spread(pendingTerm))
            group by date              \(ms(groupTerm.median)) ms   \(spread(groupTerm))
            ---
            named terms                \(ms(named)) ms
            NOT ACCOUNTED FOR          \(ms(unaccounted)) ms

          INSIDE `QueueModel.scope`, the largest term left. The pieces a test can reach; what
          `inheritedAnswers` and the rest cost is this block's own remainder rather than a guess.
            engagement clustering      \(ms(engagementTerm.median)) ms   \(spread(engagementTerm))
            the producer index, ONCE, shared by the two terms under it (#3743):
                                       \(ms(producerCorpusTerm.median)) ms   \(spread(producerCorpusTerm))
            presenter against venue    \(ms(brandsTerm.median)) ms   \(spread(brandsTerm))
            organisation row counts    \(ms(rowCountsTerm.median)) ms   \(spread(rowCountsTerm))
            inheriting an org answer   \(ms(inheritedTerm.median)) ms   \(spread(inheritedTerm))
              over \(answers.count) stored answers, which is what it is skipped entirely without
            a row per show             \(ms(rowsTerm.median)) ms   \(spread(rowsTerm))
              of which the contacts walk
                                       \(ms(contactsTerm.median)) ms   \(spread(contactsTerm))
            ---
            named                      \(ms(scopeNamed)) ms
            NOT ACCOUNTED FOR          \(ms(max(0, scopeTerm.median - scopeNamed))) ms
        """)

        // The only assertions, and both are about the measurement being REAL rather than about the
        // numbers, which move with whatever else this Mac is running (L224).
        #expect(!prospects.isEmpty, "the clone held no prospects, so this timed an empty store")
        #expect(passSeconds > 0, "a whole pass took no measurable time, so it never ran")
        #expect(narrowedSeconds > 0, "the narrowed pass took no measurable time, so it never ran")
        // The two arms really are different arms. Without this, a narrowing that silently stopped
        // narrowing would print two numbers that agree and read as a pass that got no cheaper, which is
        // indistinguishable from an instrument measuring the same thing twice (L70, L98).
        #expect(narrowedWork.queueItems < work.queueItems,
                Comment(rawValue: "the narrowed arm built \(narrowedWork.queueItems) cards and the full "
                        + "arm \(work.queueItems). If those are equal the narrowing is not in force and "
                        + "both lines above describe one arm."))
        #expect(preambleSeconds > 0, "the preamble took no measurable time, so it never ran")
        #expect(floorSeconds > 0, "the floor took no measurable time, so it never ran")
        // The arms are ORDERED, which is the one thing about them that cannot be a matter of what else
        // the machine is running: more cards cannot be cheaper. A reading that breaks this is the
        // instrument misfiring rather than a finding about the code (L224).
        // ORDERED, within the noise this run actually measured rather than exactly. More cards cannot be
        // cheaper, but two arms differing by less than the spread of their own samples are not ordered by
        // anything, and demanding they be would make this fire on the ordinary case (L224, L172). The
        // tolerance is DERIVED from the widest spread in this run, so it tracks how noisy the machine is
        // rather than being a number somebody picked.
        let noise = max(pass.high - pass.low, max(narrowed.high - narrowed.low, floor.high - floor.low))
        #expect(preambleSeconds <= floorSeconds + noise,
                Comment(rawValue: "scope alone (\(ms(preambleSeconds)) ms) came out dearer than the whole "
                        + "pass with no cards (\(ms(floorSeconds)) ms) by more than this run's own noise "
                        + "(\(ms(noise)) ms), which cannot be true: the second contains the first"))
        #expect(floorSeconds <= narrowedSeconds + noise,
                Comment(rawValue: "the no-card pass (\(ms(floorSeconds)) ms) came out dearer than the same "
                        + "pass with \(viewport.count) cards (\(ms(narrowedSeconds)) ms) by more than this "
                        + "run's own noise (\(ms(noise)) ms)"))
        #expect(narrowedWork.queueItems <= viewport.count,
                Comment(rawValue: "the narrowed arm built \(narrowedWork.queueItems) cards for a viewport "
                        + "of \(viewport.count), so it built cards nothing asked for"))
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

    // #3501: does loading each card's contacts in one go help, now that a fixture with real contacts
    // exists to measure it against?
    //
    // `QueueItem.init` reads `p.recipients` about fifteen times while building one card, `recipients` is
    // a to-many SwiftData `@Relationship`, and neither of the queue's descriptors prefetches it, so a
    // pass can FAULT the relationship rather than read it from memory.
    //
    // WHY THIS IS BEING ASKED A SECOND TIME. It was proposed on #1930 and explicitly WITHDRAWN, for a
    // good reason recorded there: the corpus it would have been measured against inserted 724 prospects
    // and not one `Recipient`, so every array was empty, faulting contributed nothing to the 275 ms
    // figure, and nothing justified the change. #2048 rebuilt that fixture at the live spread, so the
    // measurement that could not be taken can be taken. A withdrawn proposal whose reasoning was about
    // the INSTRUMENT rather than about the code gets re-proposed every few months by whoever next reads
    // a profile; answering it with a number closes it in whichever direction the number points.
    //
    // A NULL RESULT IS A REAL RESULT and is written down as one (L248), because the work that would
    // exercise this again is exactly the work a recorded negative prevents.
    //
    // THREE readings, not two, and the third is what makes the other two readable. A prefetched pass run
    // second is helped by the operating system's own page cache whatever SwiftData does, so a plain pass
    // is run AGAIN afterwards: if the second plain reading is as fast as the prefetched one, the saving
    // belonged to the cache and not to the prefetch (L70). Each opens its OWN container, so no reading
    // is served objects a previous one already materialised.
    @Test(.enabled(if: liveStoreExists, "no live store on this machine"))
    func measureWhetherPrefetchingTheContactsHelps() throws {
        guard ProcessInfo.processInfo.environment["MEASURE_QUEUE_LIVE_STORE"] != nil else {
            print("queue-live-store-prefetch: not measured. Set TEST_RUNNER_MEASURE_QUEUE_LIVE_STORE=1 to run it.")
            return
        }

        // ONE container, and a fresh CONTEXT per reading. Opening a second container on the same clone
        // leaves both connections alive when the sandbox is removed, and the run then prints
        // `BUG IN CLIENT OF libsqlite3.dylib: vnode unlinked while in use` nine times over. That is a
        // real complaint rather than noise (L219): a SwiftData container holds its sqlite connection
        // until it is deallocated, and nothing here can make that happen on demand. Measured both ways
        // on 2026-09-05: three containers print it whether they share a clone or each get their own,
        // one container prints nothing.
        //
        // A fresh context is enough for what this asks. The prefetch is a property of the FETCH, so it
        // is taken afresh on every reading whatever is resident, and the three build figures below are
        // within half a millisecond of each other, which is what says residency is not the variable.
        let clone = try cloneLiveStore()
        let container = try openContainer(at: clone)

        // One reading: a fresh context, a fetch with the given descriptor, and building every card from
        // what came back. The FETCH is timed separately from the build, because a prefetch moves work
        // INTO the fetch and out of the build, so a single total cannot say whether anything was saved
        // or merely moved.
        func reading(prefetching: Bool) throws -> (fetch: Double, build: Double, rows: Int, contacts: Int) {
            let ctx = ModelContext(container)
            var descriptor = FetchDescriptor<Prospect>()
            if prefetching { descriptor.relationshipKeyPathsForPrefetching = [\Prospect.recipients] }
            var rows: [Prospect] = []
            let fetch = seconds { rows = (try? ctx.fetch(descriptor)) ?? [] }
            let build = seconds {
                _ = QueueModel.items(from: rows, answers: [], corpus: rows, sources: [])
            }
            // Counted through the same context, so no fourth container is opened just to ask.
            let contacts = (try? ctx.fetchCount(FetchDescriptor<Recipient>())) ?? 0
            return (fetch, build, rows.count, contacts)
        }

        let plain = try reading(prefetching: false)
        let prefetched = try reading(prefetching: true)
        let plainAgain = try reading(prefetching: false)

        let ms = { (s: Double) in String(format: "%.1f", s * 1000) }

        print("""
        queue-live-store-prefetch: does loading the contacts in one go help? (#3501)
          rows \(plain.rows), contacts \(plain.contacts)
                                        fetch      build      total
          1. plain                      \(ms(plain.fetch)) ms   \(ms(plain.build)) ms   \(ms(plain.fetch + plain.build)) ms
          2. prefetching recipients     \(ms(prefetched.fetch)) ms   \(ms(prefetched.build)) ms   \(ms(prefetched.fetch + prefetched.build)) ms
          3. plain again                \(ms(plainAgain.fetch)) ms   \(ms(plainAgain.build)) ms   \(ms(plainAgain.fetch + plainAgain.build)) ms

          Read 2 against 3, never against 1. Reading 3 is the control: it is a plain fetch run after the
          same file has been read twice, so anything the operating system's page cache explains shows up
          there too. A prefetch is only worth building if 2 beats 3 on the TOTAL.
        """)

        // The assertions are about the measurement being real, never about the numbers, which move with
        // whatever else this Mac is running (L224).
        #expect(plain.rows > 0, "the plain fetch returned no rows, so nothing was built")
        #expect(prefetched.rows == plain.rows, "the two fetches saw different tables")
        #expect(plain.contacts > 0, Comment(rawValue:
                "the store holds no contacts at all, so every recipients array was empty and this "
                + "measured the same nothing #1930 withdrew the proposal over"))
        #expect(plain.build > 0, "building every card took no measurable time, so it never ran")
    }

    // #3654: WHERE the per-card time actually goes, before anybody designs around a guess.
    //
    // What is known: the card-build term is roughly 420 to 480 ms over 1,224 rows, and #2598 established
    // that the cost is the per-card construction rather than the corpus scan. What was ASSUMED, by me in
    // #3671 and corrected in #3673, is that walking each show's contacts is where that sits. Measured, it
    // is not: collapsing twelve contact reaches per card to one moved nothing, because SwiftData faults a
    // to-many relationship once and caches it.
    //
    // So this asks the question the live store can answer without any refactor at all. 962 of its shows
    // carry NO contact and 262 carry at least one (measured 2026-09-07). A contactless card runs no draft
    // lint, builds no `RecipientSnapshot`, and every contact-derived fact short-circuits on an empty
    // array. If per-card cost is contact-derived, the two groups must differ sharply. If they cost the
    // same, what a card costs is the construction itself, and a design aimed at contact work is aimed at
    // nothing (L107: a number quoted to justify a design must be produced by the code's own predicate).
    //
    // WHAT THIS CANNOT SAY, stated so nobody over-reads it. It compares two POPULATIONS of Dan's real
    // shows, not one population two ways, so the groups differ in more than their contacts: a show with
    // contacts has been prepped, so it more often carries a draft body, an outcome and a send state. That
    // makes it the WEAKER direction for the contact hypothesis and the stronger one for its refutation: if
    // the group that does MORE work costs the same per card, contact work is not the term.
    @Test func measureWhetherContactsAreWhatACardCosts() throws {
        guard ProcessInfo.processInfo.environment["MEASURE_QUEUE_LIVE_STORE"] != nil else {
            print("queue-live-store-cards: not measured. Set TEST_RUNNER_MEASURE_QUEUE_LIVE_STORE=1 to run it.")
            return
        }

        let clone = try cloneLiveStore()
        let container = try openContainer(at: clone)
        let ctx = ModelContext(container)
        let rows = (try? ctx.fetch(FetchDescriptor<Prospect>())) ?? []

        // Split AFTER the fetch and after one warming pass, so neither group pays for the other's
        // materialisation and residency is not the variable (the prefetch reading beside this one
        // establishes that a warm and a cold build differ by under half a millisecond).
        for r in rows { _ = r.recipients.isEmpty }

        let withContacts = rows.filter { !$0.recipients.isEmpty }
        let without = rows.filter { $0.recipients.isEmpty }

        // Guarded rather than assumed: a split that put everything on one side would report a per-card
        // figure for a population of nothing, and a division by zero reads as a finding (L98).
        guard withContacts.count > 50, without.count > 50 else {
            print("""
            queue-live-store-cards: UNMEASURED. The store split \(withContacts.count) with contacts
              against \(without.count) without, which is too lopsided to compare per-card costs.
            """)
            return
        }

        func build(_ rows: [Prospect]) -> Double { seconds { for r in rows { _ = QueueItem(r) } } }
        // Each group built twice, alternating, so a drift in machine load lands on both rather than on
        // whichever ran second (L224: a duration compared against a fixed number measures the machine).
        let a1 = build(withContacts), b1 = build(without)
        let a2 = build(withContacts), b2 = build(without)

        let withPer = ((a1 + a2) / 2) / Double(withContacts.count) * 1000
        let withoutPer = ((b1 + b2) / 2) / Double(without.count) * 1000
        let ratio = withoutPer > 0 ? withPer / withoutPer : 0

        print("""
        queue-live-store-cards: is building a card about its contacts? (#3654)
          shows with a contact      \(withContacts.count)
          shows with none           \(without.count)
                                     per card
          with contacts             \(String(format: "%.4f", withPer)) ms
          without                   \(String(format: "%.4f", withoutPer)) ms
          ratio                     \(String(format: "%.2f", ratio))x

          Read the RATIO. Near 1 means a card costs the same whether or not it has contacts, so what a
          card costs is its construction and a tier-one design aimed at contact work is aimed at
          something already free (#3673 measured that directly). Far above 1 means contact-derived work
          is the term after all and tier one should carry exactly the fields that avoid it.

          It compares two POPULATIONS of real shows rather than one population two ways, so the groups
          differ in more than contacts: a show with contacts has been prepped, so it more often carries a
          draft body and an outcome. That is the weaker direction for the contact hypothesis and the
          stronger one for refuting it.
        """)

        #expect(withPer > 0 && withoutPer > 0,
                "a group built in no measurable time, so nothing here was timed (L98)")
    }

}
