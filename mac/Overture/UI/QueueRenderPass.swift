import Foundation

// #1913: one render pass of the queue, lifted out of the SwiftUI body so that what it COSTS can be
// measured instead of reasoned about.
//
// Every issue in this milestone was found by reading code after Dan reported the queue stuttering, and
// nothing in the suite measured what a pass costs, so once they were fixed there was no mechanism that
// would notice the cost creeping back: the detector was Dan, months later, and the same investigation
// would run again.
//
// A SwiftUI body cannot be evaluated in a unit test (QueueView's nine @Query properties need a live
// container), so the derivation lives here as a plain function over values, and the view's body does
// nothing but gather those values and call it. That is what makes the cost measurable at all, and it is
// deliberately the REAL function the app runs rather than a copy of it in a test: a test that measured a
// reimplementation would sit green while the shipping pass grew a new sweep (L1).
enum QueueRenderPass {

    // The corpus, handed over in a way that counts every whole-store sweep taken from it.
    //
    // Nothing inside the pass can reach the rows except through `all`, so a sweep added later is counted
    // whether or not whoever adds it thinks about the cost. That is the whole point: a counter the new
    // code has to opt into would measure only the costs somebody already knew about.
    @MainActor
    struct Corpus {
        private let rows: [Prospect]
        private let tally: CostTally?

        init(_ rows: [Prospect], tally: CostTally? = nil) {
            self.rows = rows
            self.tally = tally
        }

        // One whole-store sweep. Counted.
        var all: [Prospect] {
            tally?.recordSweep()
            return rows
        }

        // Free: an array's count reads no rows. Here so a caller that only needs the size is not pushed
        // into taking a sweep it does not need.
        var count: Int { rows.count }

        // #3507: a NARROWER corpus derived from this one, rather than fetched by a second `@Query` over
        // the same table.
        //
        // `QueueView` used to hold two of those, differing only in scope. Measured against the live store
        // on 2026-09-05, a repeat of the identical descriptor cost 96% of the cold one over 1153 rows, so
        // nothing was shared between them and the second table read was paid in full
        // (`QueueRenderPassLiveStoreCostTests`).
        //
        // It goes through `all`, so the walk is COUNTED like every other. That is the point: deriving the
        // narrower list in the view instead would have moved a whole-store walk to where the sweep
        // counter cannot see it, which is how a pass gets cheaper on paper and not in the app.
        func narrowed(_ transform: ([Prospect]) -> [Prospect]) -> Corpus {
            Corpus(transform(all), tally: tally)
        }
    }

    // What one pass spent. A class so the corpus values handed around a single pass all report to one
    // tally; test-only in practice, since the app builds a pass without one.
    @MainActor
    final class CostTally {
        private(set) var sweeps = 0
        func recordSweep() { sweeps += 1 }
    }

    // #2048: what one pass spent PER CARD, which the sweep count above cannot see.
    //
    // #2033 part 2 tripled the per-card work entirely inside one sweep: three `SendGroup.pendingGroup`
    // calls, each running the draft lint over every contact. The sweep count did not move, the guard
    // passed, and the suite stayed green while the quantity it exists to protect grew threefold. A
    // regression guard must assert the quantity it protects, never a proxy for it, because the pinned
    // number stays constant for the whole time the defect is growing (L63).
    //
    // A TASK LOCAL rather than a parameter, and that is the design decision worth understanding.
    //
    // The work is done deep inside value types: `QueueItem.init` builds a card, `SendGroup.CardGroups`
    // resolves who a send reaches, and `DraftCheck.blockingFindings` runs the lint over a body. None of
    // them can be handed a tally without threading one through every caller, and `QueueItem(` has
    // hundreds of construction sites, the overwhelming majority of them in test files that are not about
    // cost. Making it a parameter would buy compile-time coverage of a handful of app sites at the price
    // of every one of those edits, and each of those tests would then carry an argument it never reads.
    //
    // #3654: the RATIO is what the argument turns on, and it is not written down here any more. It was,
    // as "318 construction sites, 314 of them in 93 test files", measured in the #2048 era and stale by
    // 74 by the time anybody looked (L32, L316, and #3487's rule for a count quoted in prose).
    // `CardConstructionCensusTests` re-derives it on every run and refuses if the app's share ever grows
    // enough to change the answer, so the reasoning above is re-measurable rather than dated.
    //
    // What the task local buys instead is the property `Corpus.all` already has and the reason that
    // counter works: nothing has to opt in. A new call site anywhere is counted whether or not whoever
    // adds it thinks about the cost, which matters because #2033's three calls were added by someone who
    // was not thinking about cost. A counter the new code must opt into only ever measures the costs
    // somebody already knew about.
    //
    // It is also the one shared-state shape that cannot collide between tests running at once: a task
    // local is scoped to the task that bound it, so two suites measuring in parallel each read their own.
    // A `static var` here would be exactly what scripts/check-test-shared-state.sh exists to report.
    //
    // COST WHEN NOBODY IS MEASURING: one task-local read per counted call, which is nil, and then
    // nothing. `nothingIsCountedWhenNobodyIsMeasuring` pins that the app leaves no tally behind, which is
    // a DIFFERENT claim: it proves no counting happened, never that asking was free.
    //
    // #3500 MEASURED it rather than leaving that sentence to be trusted, because a task-local read walks
    // the task's local storage rather than reading a plain global, and the call volume scales with the
    // row count, which grows every night (L353). On the 1,142 row fixture, 2026-09-05: one pass makes
    // 2,284 counted calls, and making that many with no tally bound costs 0.289 ms against a pass of
    // 559.3 ms, which is 0.052%. Binding a tally, which only a test does, costs nothing measurable
    // either. So the sentence above is true, and `WorkTallyCostTests` re-takes the reading on every push
    // rather than this comment being the record (L32, L316).
    // NOT @MainActor, and that is forced rather than chosen: `SendGroup.CardGroups(of:)` is a
    // nonisolated synchronous initialiser, so a main-actor tally cannot be recorded from the very place
    // the send groups are built. The counters are guarded by a lock instead, which is the honest way to
    // be reachable from wherever the work happens without reasoning about every caller's isolation.
    //
    // The lock costs nothing when nobody is measuring, because `current` is nil and no lock is taken.
    final class WorkTally: @unchecked Sendable {
        @TaskLocal static var current: WorkTally?

        private let lock = NSLock()
        private var counts = (queueItems: 0, sendGroupBuilds: 0, draftLintRuns: 0,
                              selfBookingShowsExamined: 0, recipientReaches: 0, queueRows: 0,
                              oracleCards: 0, oracleSendGroupBuilds: 0, oracleDraftLintRuns: 0,
                              oracleRecipientReaches: 0, nightTimeMapBuilds: 0,
                              stagePlacements: 0, producerIndexes: 0,
                              producerKeyFolds: 0)

        // #3654 step 4c: the in-app divergence check is a SECOND WRITER of this tally, and that is
        // settled here rather than discovered in a red run.
        //
        // It rebuilds one sampled card per pass through the shipping card builder, so without this every
        // measured pass would count that card, its send groups, its lint runs and its contacts read, and
        // `detailCards == requestedCardKeys.count` could not hold (L375). The exclusion is STATED and
        // SCOPED rather than implicit (L324): it covers exactly the work done inside
        // `QueueModel.checkOneCardAgainstAFreshBuild` and nothing else, and
        // `TheOracleIsCountedApartTests` asserts a measured pass reports the same numbers with the check
        // on and off.
        @TaskLocal static var asOracle = false

        var queueItems: Int { lock.withLock { counts.queueItems } }
        // #3653 step 3a: how many cheap SCOPE ROWS the pass built, which is a different quantity from
        // `queueItems` the moment #3654 lands and only the rendered shows get a card.
        //
        // A SECOND counter rather than a rename, and the difference matters: the ratio of the two is what
        // Phase 4 is judged by, so folding them would make the saving unmeasurable at the exact moment it
        // starts happening. Until then they are equal by construction, which is what
        // `QueueRenderPassCostTests` pins.
        var queueRows: Int { lock.withLock { counts.queueRows } }
        var sendGroupBuilds: Int { lock.withLock { counts.sendGroupBuilds } }
        var draftLintRuns: Int { lock.withLock { counts.draftLintRuns } }
        // #3438: how many OTHER shows the self-booking check had to look at. Counted as shows
        // EXAMINED rather than calls, because the term is quadratic in shows sharing a date and a
        // call count is the same number whether each call reads one night's bucket or walks the
        // whole queue (L63).
        var selfBookingShowsExamined: Int { lock.withLock { counts.selfBookingShowsExamined } }
        // #3653 step 3d: how many times building a card REACHES for a show's contacts.
        //
        // Counted rather than name-listed, which is the whole point of this counter. A source guard
        // forbidding `DraftCheck`, `SendGroup` and friends in the tier-one file asserts a PROXY for the
        // quantity it protects, and would pass unchanged while tier one took three walks per row naming
        // none of them (L63). That is the shape #2033 used in this same file to triple per-card work
        // while the sweep counter did not move.
        //
        // REACHES, not rows walked: every reach walks the contacts, so this is the quantity #3654 must
        // take to one, and it moves with the CODE rather than with how many contacts the store happens
        // to hold.
        var recipientReaches: Int { lock.withLock { counts.recipientReaches } }

        // #3737: how many times a show's night-to-curtain map is BUILT from its stored entries.
        //
        // Counted rather than timed, and counted as BUILDS rather than as calls to the function that
        // consults it, for the reason `selfBookingShowsExamined` above already records: a call count is
        // the same number whether each call rebuilds the map or reads one it was handed (L63). Each build
        // runs a `DateFormatter` parse over every entry, so this is the quantity the quadratic lived in.
        var nightTimeMapBuilds: Int { lock.withLock { counts.nightTimeMapBuilds } }

        // #3738: how many times every show's stages were decided from scratch in one pass.
        //
        // The quantity, not a proxy for it. `matches` faults a prospect's recipients, and the pass used
        // to ask it through three separate sweeps; a count of CALLS to `queueKeys` would have read 1 the
        // whole time while the work behind it was tripled (L63).
        var stagePlacements: Int { lock.withLock { counts.stagePlacements } }

        // #3743: how many times the presenter-against-venue index was built from the corpus in one pass.
        //
        // Two whole-corpus derivations needed one, and each built its own: the venue-brand table and the
        // inherited answer ledger. Measured at 27.2 ms each on the live store. Counted rather than timed,
        // and counted as BUILDS rather than as calls to either of them, because a call count reads the
        // same whether the callee builds an index or reads one it was handed (L63).
        var producerIndexes: Int { lock.withLock { counts.producerIndexes } }

        // #3742: how many times a presenter or venue NAME was folded into a producer key.
        //
        // The quantity, because folding is the cost: a regex, a Unicode fold and several trims per call.
        // A count of index BUILDS cannot see a build that folds every show's name rather than every
        // distinct name, which is the same number of builds and five times the work (L63).
        var producerKeyFolds: Int { lock.withLock { counts.producerKeyFolds } }

        // What the divergence check itself spent, held apart from every number above so the pass's own
        // pins mean what their names say.
        var oracleCards: Int { lock.withLock { counts.oracleCards } }
        var oracleSendGroupBuilds: Int { lock.withLock { counts.oracleSendGroupBuilds } }
        var oracleDraftLintRuns: Int { lock.withLock { counts.oracleDraftLintRuns } }
        var oracleRecipientReaches: Int { lock.withLock { counts.oracleRecipientReaches } }

        // Each recorded through the TYPE rather than on an instance, so a call site does not need to know
        // whether anybody is listening, and reads one task local before doing anything else.
        static func recordQueueItem() {
            guard let t = current else { return }
            let oracle = asOracle
            t.lock.withLock { if oracle { t.counts.oracleCards += 1 } else { t.counts.queueItems += 1 } }
        }
        static func recordProducerKeyFold() {
            guard let t = current else { return }
            t.lock.withLock { t.counts.producerKeyFolds += 1 }
        }
        static func recordProducerIndex() {
            guard let t = current else { return }
            t.lock.withLock { t.counts.producerIndexes += 1 }
        }
        static func recordStagePlacement() {
            guard let t = current else { return }
            t.lock.withLock { t.counts.stagePlacements += 1 }
        }
        static func recordNightTimeMapBuild() {
            guard let t = current else { return }
            t.lock.withLock { t.counts.nightTimeMapBuilds += 1 }
        }
        static func recordQueueRow() {
            guard let t = current else { return }
            t.lock.withLock { t.counts.queueRows += 1 }
        }
        static func recordSendGroupBuild() {
            guard let t = current else { return }
            let oracle = asOracle
            t.lock.withLock { if oracle { t.counts.oracleSendGroupBuilds += 1 } else { t.counts.sendGroupBuilds += 1 } }
        }
        static func recordDraftLintRun() {
            guard let t = current else { return }
            let oracle = asOracle
            t.lock.withLock { if oracle { t.counts.oracleDraftLintRuns += 1 } else { t.counts.draftLintRuns += 1 } }
        }
        static func recordRecipientReach() {
            guard let t = current else { return }
            let oracle = asOracle
            t.lock.withLock { if oracle { t.counts.oracleRecipientReaches += 1 } else { t.counts.recipientReaches += 1 } }
        }
        static func recordSelfBookingShowsExamined(_ n: Int) {
            guard n > 0, let t = current else { return }
            t.lock.withLock { t.counts.selfBookingShowsExamined += n }
        }

        // Run `body` with a fresh tally bound, and hand back what it spent. The ONLY way to read these
        // counters, so a test cannot accidentally report on a pass it did not run.
        static func measure(_ body: () -> Void) -> WorkTally {
            let tally = WorkTally()
            WorkTally.$current.withValue(tally) { body() }
            return tally
        }
    }

    // Everything one pass derives FROM. Values only: every file-backed answer (the Gmail connection,
    // whether a detached run is alive) is READ BY THE CALLER and handed in, so the pass itself cannot
    // reach the filesystem. QueueRenderPassCostTests holds it to that.
    @MainActor
    struct Inputs {
        // #3507: ONE corpus, the whole table. The queue's own scope (every show but the dismissed ones,
        // date then fit) is derived from it inside `make` rather than arriving as a second `@Query`,
        // which is what makes "the table is read once per store change" true by construction rather than
        // by everyone remembering.
        var allProspects: Corpus
        var inquiries: [Inquiry]
        var orgAnswers: [OrgReachabilityAnswer]
        var sources: [WatchedSource] = []
        // #2392: the addresses Dan has struck, as a value. Read by the CALLER from its own @Query, on the
        // same rule as everything else here: this pass may not reach the store or the filesystem itself.
        var refusals: ContactRefusal.Ledger = .none
        var overrides: ProducerOverrides = .none
        // #2365: the day, the instant and Dan's geography refusals as ONE value. They were three
        // independent fields, so an Inputs could carry a `today` that was not the Eastern day of its own
        // `now`, and every sweep below reasoned in one while dating in the other. See StageContext.
        var context: StageContext
        var focusedStage: StageFocus?
        var focusedKeys: [String]?
        var gmailConnected: Bool = false
        // #2614: WHICH run holds the single detached slot, or nil for none. One value rather than a
        // `prepRunning` boolean beside a `probeRunning` one: a check is by definition also running, so
        // the pair had a corner the app can never be in, and the roster was handed only the first of them.
        // #2267's per-card re-check state is derived from it below, so the card and the pill read one fact.
        var runInFlight: RunKind? = nil
        // #3186: the check's start and size, for the row's own re-check label.
        var checkRunSince: Date? = nil
        var checkLookups: Int? = nil
        var replyRunAlive: Bool = false
        // #1930's fingerprint of what this view derives FROM, gathered by the caller because it describes
        // the caller's own state. DEBUG only in effect: the pass records it and nothing else reads it.
        var trace: [String: String] = [:]
        // #3654: the shows the LAST frame actually drew, plus whatever else a surface asked for, or nil
        // for every row in scope.
        //
        // KEYS REGISTERED DURING FRAME N FEED THE MAP FOR FRAME N+1, and that ordering is the contract
        // rather than a limitation. The card map is computed BEFORE the body renders; which rows a
        // `LazyVStack` realizes is discovered DURING it. So the first frame of a newly drawn or newly
        // scrolled surface asks for keys nobody predicted, those cards are built on the spot, and the
        // store counts them as EXPECTED misses. What must never happen is a request for a key this set
        // named and the pass did not build, which is `unexpectedCardMisses` and is pinned at zero.
        var requestedCardKeys: Set<String>? = nil
        // Where this pass's own render path will record what it draws, for the pass after it. Nil in
        // every test that measures one pass on its own, which have no next frame.
        var cardKeyRegistry: QueueModel.CardKeyRegistry? = nil
    }

    @MainActor
    static func make(_ i: Inputs) -> QueueView.RenderData {
        // #2968: the whole store, INCLUDING the dismissed shows the queue's own scope drops, taken once
        // and read several times. `QueueModel.items` already needed it as its corpus; the Follow-ups
        // count is a second READER of that same list rather than a second reason to walk the store, and
        // taking it again would spend one of the sweeps `QueueRenderPassCostTests` pins (#1913).
        let everyProspect = i.allProspects.all
        // #3507: the queue's own scope, derived from that corpus rather than fetched by a second @Query.
        let inQueue = i.allProspects.narrowed(QueueModel.queueScope)
        // #1962: every show's place worked out once for this pass and shared by the sweeps below.
        let context = i.context.resolvingPlaces(of: inQueue.all)
        let geo = context.geo
        // #1121/#1774: the whole-store derivation, paid ONCE here and threaded down, rather than by each
        // computed property that wants a row.
        let scope = QueueModel.scope(from: inQueue.all, answers: i.orgAnswers,
                                     corpus: everyProspect, overrides: i.overrides,
                                     sources: i.sources, refusals: i.refusals,
                                     // #2524: the same window the stage rule applies, so the card's
                                     // sentence and the stage's decision come from one answer.
                                     clients: context.clients, now: context.now,
                                     cardKeys: i.requestedCardKeys,
                                     cardKeyRegistry: i.cardKeyRegistry, today: context.today)
        // #3653 Phase 3: one build, two halves. The cards are what the screen draws; the rows are what
        // every whole-scope sweep below reads, and they cost one contacts walk between them rather than
        // one each.
        let rows = scope.rows
        #if DEBUG
        QueueRenderCounter.recordDerivation(inputs: i.trace, rows: rows)
        #endif
        let reachedOut = ReachedOutQueue.activeWithDates(from: inQueue.all, now: context.now)
        let reachedOutKeys = Set(reachedOut.map(\.prospect.naturalKey))
        // #3738: every show's stages, decided ONCE for this pass and read by all four answers below.
        //
        // This pass asked the same question three times: the masthead's membership, the pill counts and
        // the focused stage's rows. `matches` faults a prospect's recipients and was being evaluated
        // about 23,000 times per render on the live store, which #3736 measured at 152.1 ms of the pass's
        // floor. One table, four readers.
        let placement = StageNavigation.placements(in: inQueue.all, context: context)
        // #1567: counted through StageNavigation, the same predicate as the pills beneath it, so the
        // masthead can no longer state a smaller backlog than the pills it sits above.
        let inAStage = StageNavigation.queueKeys(in: placement, reachedOutKeys: reachedOutKeys)
        let visibleRows = rows.filter { inAStage.contains($0.id) }
        // #1774/#1140: in stage mode membership is re-derived live (a sent draft drops out); in leads mode
        // the frozen key set stands. The dispatch lives in StageNavigation so it is tested.
        let wanted = Set(StageNavigation.focusedKeys(stage: i.focusedStage, leadKeys: i.focusedKeys ?? [],
                                                     in: placement))
        let focusedRows = rows.filter { wanted.contains($0.id) }
        return QueueView.RenderData(
            cards: scope.cards,
            // #3507: the scope itself, so the render path reads the list this pass already derived rather
            // than deriving it again per row. Every caller that needs it during a render takes it from
            // here; only a user ACTION, which happens outside a pass, derives its own.
            queueScope: inQueue.all,
            // #3323: built once for the pass, from the WHOLE item set rather than the focused stage, so a
            // clash with a show in another stage still counts (#1246).
            selfBooking: QueueModel.selfBookingIndex(rows),
            agentInputs: AgentInputs.from(prospects: inQueue.all,
                                          // #2968: the Follow-ups number alone is taken over
                                          // everything, because the sheet and the toolbar badge
                                          // behind that pill query everything, and this list
                                          // drops dismissed shows.
                                          allProspects: everyProspect,
                                          inquiries: i.inquiries,
                                          context: context, gmailConnected: i.gmailConnected,
                                          runInFlight: i.runInFlight, replyRunAlive: i.replyRunAlive,
                                          // #3738: the table this pass already built, so the pill counts
                                          // read it rather than deciding every show's stages again.
                                          placement: placement),
            gmailConnected: i.gmailConnected,
            probeRunning: i.runInFlight == .reachabilityCheck,
            checkRunSince: i.checkRunSince,
            checkLookups: i.checkLookups,
            reachedOut: reachedOut,
            reachedOutKeys: reachedOutKeys,
            pendingBookings: QueueModel.pendingBookingCount(rows),
            fanOutLine: fanOutWarning(inQueue.all),
            rows: rows, visibleRows: visibleRows,
            // #3654 step 4c: what the in-app check found, REPORTED and never written here. This pass may
            // not touch the filesystem (`QueueRenderPassIsPureTests` holds it to that), so the caller
            // does the recording, exactly as it reads the Gmail connection and hands that in.
            cardCheck: scope.cardCheck,
            focusedRows: focusedRows,
            dateGroups: QueueModel.groupByDate(focusedRows),
            inquiryRows: inquiryRows(i.inquiries, stage: i.focusedStage, now: context.now),
            // #3738: read by the empty-stage card, which pointed Dan at the next stage with work by
            // counting every show again inside a SwiftUI body. One derivation, two readers (L16).
            stageCounts: StageNavigation.counts(in: placement),
            geo: geo)
    }

    // #1694: one possible-match record flagged across a crowd of shows, which is the tell that the rule
    // locked onto something those shows SHARE rather than onto the act. Counted over every prospect
    // rather than the visible rows, because a flagged show has usually already left the queue.
    static func fanOutWarning(_ prospects: [Prospect]) -> String? {
        PossibleMatchFanOut.warningLine(
            PossibleMatchFanOut.findings(rows: prospects.compactMap { p in
                p.possibleMatchName.map { (act: p.groupName, match: $0) }
            }))
    }

    // #1436: the stage's inquiries, as their own date-grouped block.
    static func inquiryRows(_ inquiries: [Inquiry], stage: StageFocus?, now: Date) -> [InquiryRow] {
        guard let stage else { return [] }
        return QueueModel.inquiryRows(inquiries.filter { StageNavigation.stage(for: $0) == stage }, now: now)
    }
}
