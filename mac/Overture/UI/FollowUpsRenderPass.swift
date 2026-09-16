import Foundation

// #3814: one render pass of the FOLLOW-UPS SHEET, lifted out of the SwiftUI body so that what it COSTS
// can be measured instead of reasoned about.
//
// WHY THIS SURFACE WENT FIRST OF THE SEVEN. #3814 enumerated seven views holding a whole-store
// `@Query private var prospects: [Prospect]` and deriving from it inside a body, and said the first job
// was to RANK them rather than to lift anything, because a surface nobody has open cannot freeze
// anything. #3827 supplied the ranking evidence a day later, and it is not close. Read off Dan's live
// freeze log and its archive on 2026-09-12: of 1,659 stall records, 97 name `followUps`, and they are the
// only records in the entire file naming any surface other than the queue. Their distribution is p50
// 0.227 s, p90 1.248 s, and the worst is 21.38 s AT BASELINE LOAD, with four more between 7.7 s and
// 12.9 s inside the same two minutes. So this is the one surface on that list of seven with measured
// freezes against its name, and the other six have none.
//
// WHAT WAS ALREADY RIGHT HERE, said first so the change is not read as bigger than it is. Unlike the
// Sources sheet before #3645, this sheet's derivation was ALREADY a pure function over values:
// `DueWork.rows` has lived in Domain since #2878 and is well tested. `FollowUpsView` also already counted
// its own rebuild, since #3762. What was missing is everything between those two: the store walk was not
// counted, the pass had no duration beside its count (#3815), the calendar index and the row clock were
// derived inside a `@ViewBuilder` where no counter can see them, and the sheet read TWO different
// instants (`Date()` inside `rows`, and a second `Date()` further down the body) for one drawing.
//
// THE COUNTERS ARE THE QUEUE'S, REUSED RATHER THAN RE-IMPLEMENTED, on `SourcesRenderPass`'s precedent and
// for its reason exactly: two `Corpus` types would be two answers to "how many times did this pass read
// the store", and the day one of them learned something the other did not is the day a sweep here stopped
// being counted.
//
// WHAT THE SWEEP COUNT DOES AND DOES NOT SAY, because it would otherwise be read as more than it is.
// `Corpus` counts reads OF THE STORE. This pass takes exactly one, and hands the resulting array to
// `DueWork.rows`, which walks it four times, once per rule. Those four are walks of an array already in
// memory, not four fetches, and they are deliberately NOT counted as sweeps: calling them that would make
// this surface look four times more expensive than the queue for doing something cheaper. What prices
// them is the pass duration `FollowUpsView` now records beside the count (#3815) and the per-rule
// decomposition in `QueueRenderPassLiveStoreCostTests`. `DueWork` is not given a `Corpus` of its own for a
// concrete reason rather than a stylistic one: `DueWork.counts` is called from a nonisolated context
// (`AgentRoster`, `ReconcileScheduler`) and `Corpus` is main-actor isolated, so threading one through
// would isolate a type three schedulers depend on.
enum FollowUpsRenderPass {
    // Reused, not re-declared. See the header.
    typealias Corpus = QueueRenderPass.Corpus
    typealias CostTally = QueueRenderPass.CostTally

    // Everything one pass derives FROM. Values only: every file-backed answer (whether a reply-classify
    // run is still beating) is READ BY THE CALLER and handed in, so the pass itself cannot reach the
    // filesystem. `FollowUpsRenderPassCostTests` holds it to that.
    @MainActor
    struct Inputs {
        // The whole store, through the counted accessor. Nothing here can reach a prospect any other way,
        // so a sweep added later is counted whether or not whoever adds it thinks about the cost.
        var prospects: Corpus
        // #3890: hire inquiries, for the replies waiting on an answer. A plain array rather than a
        // `Corpus` for the reason `sources` gives: a different table, counted apart.
        var inquiries: [Inquiry]
        // The watchlist, for the link label each row draws (#2816). Not a `Corpus`: it is a different
        // table, and a counter that folded the two would report a number nothing could act on.
        var sources: [WatchedSource]
        // ONE instant for the whole pass. The sheet used to take two, and the second one's own comment
        // (#2919) said why that is wrong while the first one sat eight lines above it doing it.
        var now: Date
        // #2878: a classify run still beating means nothing is stalled (#471). Read by the caller from
        // the marker file, so the pass stays pure and a test can render both sides of it.
        var replyRunAlive: Bool
    }

    // What one pass decided the sheet should draw. Every list the body renders and every index its rows
    // read, so a section cannot quietly start deriving from inside a `@ViewBuilder` where no counter can
    // see it.
    @MainActor
    struct RenderData {
        var rows: DueWork.Rows
        // #2816: built ONCE for every section rather than per row (#1121). It was already built once, but
        // inside the body's scroll holder, which is a place no test can reach and no counter can see.
        var sourceCalendars: [String: String]
        // Carried rather than re-read by the body, so every sentence this drawing dates is dated from the
        // instant the pass was taken.
        var now: Date
    }

    @MainActor
    static func make(_ i: Inputs) -> RenderData {
        // ONE store read for the whole pass, counted. `DueWork.rows` runs its four rules over the array
        // this returns; see the header for why those four are not four sweeps.
        let rows = DueWork.rows(prospects: i.prospects.all, inquiries: i.inquiries, now: i.now,
                                replyRunAlive: i.replyRunAlive)

        // The sheet draws one sentence and no rows when nothing is due, so the index it would thread into
        // those rows must not be built. Not an optimisation: it is what the empty screen already renders,
        // and a pass that indexed the watchlist to draw one sentence would be a cost nobody could see
        // from the screen. `SourcesRenderPass` refuses its own derivations on the same rule.
        let calendars = rows.isEmpty ? [:] : QueueModel.sourceCalendarIndex(i.sources)

        return RenderData(rows: rows, sourceCalendars: calendars, now: i.now)
    }
}
