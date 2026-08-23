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
    }

    // What one pass spent. A class so the corpus values handed around a single pass all report to one
    // tally; test-only in practice, since the app builds a pass without one.
    @MainActor
    final class CostTally {
        private(set) var sweeps = 0
        func recordSweep() { sweeps += 1 }
    }

    // Everything one pass derives FROM. Values only: every file-backed answer (the Gmail connection,
    // whether a detached run is alive) is READ BY THE CALLER and handed in, so the pass itself cannot
    // reach the filesystem. QueueRenderPassCostTests holds it to that.
    @MainActor
    struct Inputs {
        var prospects: Corpus
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
        var replyRunAlive: Bool = false
        // #1930's fingerprint of what this view derives FROM, gathered by the caller because it describes
        // the caller's own state. DEBUG only in effect: the pass records it and nothing else reads it.
        var trace: [String: String] = [:]
    }

    @MainActor
    static func make(_ i: Inputs) -> QueueView.RenderData {
        // #1962: every show's place worked out once for this pass and shared by the three sweeps below.
        let context = i.context.resolvingPlaces(of: i.prospects.all)
        let geo = context.geo
        // #2968: the whole store, INCLUDING the dismissed shows `i.prospects` drops, taken once and read
        // twice. `QueueModel.items` already needed it as its corpus; the Follow-ups count is a second
        // READER of that same list rather than a second reason to walk the store, and taking it again
        // would spend one of the eight sweeps `QueueRenderPassCostTests` pins (#1913).
        let everyProspect = i.allProspects.all
        // #1121/#1774: the whole-store derivation, paid ONCE here and threaded down, rather than by each
        // computed property that wants a row.
        let items = QueueModel.items(from: i.prospects.all, answers: i.orgAnswers,
                                     corpus: everyProspect, overrides: i.overrides,
                                     sources: i.sources, refusals: i.refusals,
                                     // #2524: the same window the stage rule applies, so the card's
                                     // sentence and the stage's decision come from one answer.
                                     clients: context.clients, now: context.now, today: context.today)
        #if DEBUG
        QueueRenderCounter.recordDerivation(inputs: i.trace, rows: items)
        #endif
        let reachedOut = ReachedOutQueue.activeWithDates(from: i.prospects.all, now: context.now)
        let reachedOutKeys = Set(reachedOut.map(\.prospect.naturalKey))
        // #1567: counted through StageNavigation, the same predicate as the pills beneath it, so the
        // masthead can no longer state a smaller backlog than the pills it sits above.
        let inAStage = StageNavigation.queueKeys(in: i.prospects.all, reachedOutKeys: reachedOutKeys,
                                                 context: context)
        let visible = items.filter { inAStage.contains($0.id) }
        // #1774/#1140: in stage mode membership is re-derived live (a sent draft drops out); in leads mode
        // the frozen key set stands. The dispatch lives in StageNavigation so it is tested.
        let wanted = Set(StageNavigation.focusedKeys(stage: i.focusedStage, leadKeys: i.focusedKeys ?? [],
                                                     in: i.prospects.all, context: context))
        let focusedRows = items.filter { wanted.contains($0.id) }
        return QueueView.RenderData(
            items: items, visible: visible,
            agentInputs: AgentInputs.from(prospects: i.prospects.all,
                                          // #2968: the Follow-ups number alone is taken over
                                          // everything, because the sheet and the toolbar badge
                                          // behind that pill query everything, and this list
                                          // drops dismissed shows.
                                          allProspects: everyProspect,
                                          inquiries: i.inquiries,
                                          context: context, gmailConnected: i.gmailConnected,
                                          runInFlight: i.runInFlight, replyRunAlive: i.replyRunAlive),
            gmailConnected: i.gmailConnected,
            probeRunning: i.runInFlight == .reachabilityCheck,
            reachedOut: reachedOut,
            reachedOutKeys: reachedOutKeys,
            pendingBookings: QueueModel.pendingBookingCount(items),
            fanOutLine: fanOutWarning(i.prospects.all),
            focusedRows: focusedRows,
            dateGroups: QueueModel.groupByDate(focusedRows),
            inquiryRows: inquiryRows(i.inquiries, stage: i.focusedStage, now: context.now),
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
