import Foundation

// #794: which watched sources actually earn their place.
//
// Once the standing watchlist (#768) holds thirty sources, nothing shows which are worth watching. A
// source can extract perfectly and still produce nothing Dan would ever photograph (the #770 spike found
// Symphony Space returns twelve upcoming events, almost all film screenings and literary talks): it would
// sit there generating junk indefinitely, invisibly, costing a fetch plus an extraction every day. The
// feature has to be judged on qualified LEADS, not shows found.
//
// This is the lifetime funnel per source, read straight off the provenance #771 records (`sourceIds`).
// It is a pure function, never a computation inside the Sources sheet, for the reason two rules have
// already drifted here under a green suite (#863, #885): a rule computed in a SwiftUI body is a rule no
// test can reach.
//
// It removes NOTHING. Per Dan's rule only a refusal (or his explicit removal) takes a source off the
// list. This makes dead weight visible and leaves the decision his.
enum SourceYield {

    // The funnel, widest to narrowest. It is CUMULATIVE by construction (see `tally`): a booked show is
    // also counted sent, approved and kept, so `found >= kept >= approved >= sent >= booked` always holds
    // and Dan can never read "1 sent" sitting above "0 kept".
    //
    // `unreviewed` sits OUTSIDE that funnel: it is the shows Dan has not opened yet (status `.new`), the
    // ones the summary leads with (#1029). It never overlaps `kept`, because a kept show has by definition
    // been moved past `.new`, so `unreviewed + reviewed == found` where `reviewed == found - unreviewed`.
    struct Tally: Equatable, Sendable {
        var found: Int
        var unreviewed: Int
        var kept: Int
        var approved: Int
        var sent: Int
        var booked: Int

        // A source that surfaced nothing. It is what `tally` returns for a source no prospect credits, and
        // what a reader defaults to for a source absent from `tallies(in:)`'s map (#1429), so the two paths
        // agree on the empty case.
        static let zero = Tally(found: 0, unreviewed: 0, kept: 0, approved: 0, sent: 0, booked: 0)
    }

    // The lifetime tally for one source across every prospect it ever surfaced, whatever became of them:
    // this is the "has it earned its place over a year" question, so a past show counts as much as a live
    // one. A show surfaced by several sources (the upsert merges a venue's calendar and the presenter's
    // own site into one row) credits each of them, because each genuinely did surface it.
    static func tally(sourceId: String, in prospects: [Prospect]) -> Tally {
        var t = Tally.zero
        for p in prospects where p.sourceIds.contains(sourceId) {
            t.found += 1

            // Not yet looked at. The scout writes every show `.new`; Dan keeps or dismisses it from there.
            // This is what the summary leads with, and what a freshly scouted source is entirely made of,
            // so it can never again read as "0 kept" (#1029).
            if p.status == .new { t.unreviewed += 1 }

            // Read deepest-stage-first and let each stage subsume the ones below it, so the count stays
            // monotonic even when the current status has moved on. The load-bearing case is a show sent
            // and LATER dismissed: its status is `.dismissed`, but it was still sent, so reading "kept"
            // from status membership alone would show sent above a smaller kept.
            let booked = p.outcome == .booked
            let sent = p.wasContacted || booked
            let approved = p.status == .approved || sent
            let kept = keptStatuses.contains(p.status) || approved

            if kept { t.kept += 1 }
            if approved { t.approved += 1 }
            if sent { t.sent += 1 }
            if booked { t.booked += 1 }
        }
        return t
    }

    // Every source's tally in ONE pass over prospects, keyed by sourceId (#1429). The Sources sheet used to
    // call `tally` above once PER source row, each an O(all prospects) scan, and its scroll-hold binding
    // re-ran the whole list on every scroll tick, so one long scroll multiplied (rows x every prospect)
    // across many redraws on the main thread and froze the app. This loops the store once and credits each
    // source a prospect surfaced, so the sheet caches the map and reads each row's tally in O(1).
    //
    // The stage flags are computed once per prospect and then applied to each of its sources, mirroring
    // `tally` EXACTLY (deepest-stage-first, monotonic), so the two can never drift; a test asserts they
    // agree source-for-source. A source no prospect credits is simply absent from the map, and the reader
    // defaults it to `Tally.zero`, which is what `tally` returns for it too.
    static func tallies(in prospects: [Prospect]) -> [String: Tally] {
        var out: [String: Tally] = [:]
        for p in prospects {
            let isNew = p.status == .new
            let booked = p.outcome == .booked
            let sent = p.wasContacted || booked
            let approved = p.status == .approved || sent
            let kept = keptStatuses.contains(p.status) || approved

            // `Set` so a prospect that lists the same source twice credits it ONCE, matching `tally`'s
            // membership test (`contains`) rather than a raw count over `sourceIds`.
            for sourceId in Set(p.sourceIds) {
                var t = out[sourceId] ?? .zero
                t.found += 1
                if isNew { t.unreviewed += 1 }
                if kept { t.kept += 1 }
                if approved { t.approved += 1 }
                if sent { t.sent += 1 }
                if booked { t.booked += 1 }
                out[sourceId] = t
            }
        }
        return out
    }

    // The change-key the Sources sheet evaluates every redraw to decide whether the cached `tallies` map is
    // stale (#1429), the same signature-then-recompute shape #1356/#1374 used for that sheet's coverage
    // list. It captures exactly the four fields a tally reads (a prospect's status, whether it was
    // contacted, its outcome, and which sources credited it), so it changes precisely when some tally would
    // and never on a mere scroll or unrelated redraw.
    //
    // Order-independent (an overflow-add of each prospect's own hash, and sourceIds sorted within a
    // prospect) so a re-fetch that returns the same prospects in a different order does not force a needless
    // full-store recompute. A hash collision can only mean one stale redraw, never a wrong number, because
    // the next real change re-fires; the funnel is refreshed from scratch each time the sheet opens.
    static func signature(_ prospects: [Prospect]) -> Int {
        var acc = prospects.count
        for p in prospects {
            var h = Hasher()
            h.combine(p.status)
            h.combine(p.wasContacted)
            h.combine(p.outcome)
            for sourceId in p.sourceIds.sorted() { h.combine(sourceId) }
            acc = acc &+ h.finalize()
        }
        return acc
    }

    // A show Dan moved past `.new` toward a pitch, on its status alone (the `approved`/`sent` OR in
    // `tally` covers the cases where the status has since regressed). A show still `.new`, or `.dismissed`
    // before he ever kept it, is not here: he has not decided to pursue it, and counting it would flatter
    // a source that only produces things he throws away.
    private static let keptStatuses: [ReviewStatus] = [.queued, .drafted, .approved, .contacted]

    // The line the Sources sheet shows, led by the thing Dan ACTS on (#1029): the shows this source
    // surfaced that he has not opened yet. A freshly scouted source is entirely those, so it now reads
    // "8 new shows waiting for you" and never "0 of 8 kept", which read as dead weight on a source that
    // had simply not been reviewed yet (Dan, on 54 Below: "extensive shows through August, only 5 counted
    // and 0 kept"). "Not reviewed yet" and "reviewed and kept none" are two different states and must not
    // collapse to one sentence.
    //
    // Behind the waiting count, the lifetime kept tally still earns its place (#794): a source Dan has
    // reviewed and kept nothing from is dead weight, and that stays visible as "0 of N kept". Its
    // denominator is the shows he has REVIEWED (found minus waiting), never the found total, or the ones
    // still waiting would read as shows he looked at and passed over.
    //
    // nil when the source has surfaced nothing at all: a brand-new or off-season source is neither dead
    // weight nor broken (its read state and health already speak for it).
    static func line(_ tally: Tally) -> String? {
        guard tally.found > 0 else { return nil }
        let reviewed = tally.found - tally.unreviewed

        // What to do now. Written as two complete literals (not `Plural.count` + a suffix) so each lands
        // in the copy inventory as a whole sentence for the cold read, never as a "waiting for you"
        // fragment.
        let waitingClause: String? = tally.unreviewed > 0 ? waiting(tally.unreviewed) : nil

        // What this source has earned over what he has reviewed. Silent until something has been reviewed,
        // so it can never be the sentence a fresh source shows.
        let keptClause: String? = reviewed > 0 ? keptLine(tally, reviewed: reviewed) : nil

        switch (waitingClause, keptClause) {
        case let (waiting?, kept?): return "\(waiting) · \(kept)"
        case let (waiting?, nil):   return waiting
        case let (nil, kept?):      return kept
        case (nil, nil):            return nil   // unreachable given found > 0; stated, not forced.
        }
    }

    // A source needs a read history of its own before Overture judges its yield, the same bar the
    // self-heal machinery uses before it will let a source mark a show gone (WatchedSource.warmupRuns).
    // Three full reads that have still never once surfaced a pitchable show is a real pattern, not a
    // source still warming up.
    static let neverYieldedAfterReads = 3

    // #978: the standing signal `line(_:)` above cannot give. That line goes silent when a source has
    // surfaced nothing at all (found == 0), because a brand-new or off-season source is neither dead
    // weight nor broken. But a source READ many times that has still never once surfaced a pitchable show
    // is exactly the dead weight #794 exists to make visible: an org homepage watched in place of a
    // calendar, a season page that renders empty, a site gone dormant. #794's own "0 of N kept" needs a
    // show to have been found first, so it cannot see a page that never yielded even one. The single fact
    // that tells that apart from a source simply new to the watchlist is how many times it has actually
    // been read, so the read count is the one extra input this overload takes.
    //
    // `reads` is the source's successfulCheckCount: the times a page was read IN FULL and landed (an
    // all-past or all-filtered read counts, having genuinely produced no pitchable show; a failed or
    // confirmed-empty read never increments it). That is the honest denominator for "read N times and
    // produced no dated event".
    //
    // Informational ONLY, exactly like line(_:): it removes nothing and disables nothing. Retiring or
    // repointing the source stays Dan's call, served by the Stop watching and Fix controls on the row.
    static func line(_ tally: Tally, reads: Int) -> String? {
        // Once there is any yield to describe, this is the ordinary #794 line: the read count changes
        // nothing, and the never-yielded signal is only ever the found == 0 case.
        guard tally.found == 0 else { return line(tally) }
        guard reads >= neverYieldedAfterReads else { return nil }
        // #1178: an actionable nudge, not a bare fact. A page that reads fine yet has surfaced nothing over
        // many reads is most likely aimed at the wrong page (The Cell's empty box office read as perfectly
        // healthy while its real programming was on another host, #1127). Now that #1177 offers the Fix
        // control on this very row, the line points Dan at it instead of leaving the gap silent. Still
        // informational only: it removes and disables nothing, the re-point stays his call.
        return "Read \(reads) times but never turned up a show. It may be pointed at the wrong page."
    }

    // "8 new shows waiting for you" / "1 new show waiting for you". Two complete literals rather than a
    // composed one, per the copy-inventory rule above.
    private static func waiting(_ n: Int) -> String {
        n == 1 ? "1 new show waiting for you" : "\(n) new shows waiting for you"
    }

    // The lifetime funnel over reviewed shows, kept-first (Dan's choice), with sent and booked appended
    // only when they are above zero so the common case carries no trailing "· 0 sent · 0 booked" noise.
    private static func keptLine(_ tally: Tally, reviewed: Int) -> String {
        var line = "\(tally.kept) of \(reviewed) kept after review"
        if tally.sent > 0 { line += " · \(tally.sent) sent" }
        if tally.booked > 0 { line += " · \(tally.booked) booked" }
        return line
    }
}
