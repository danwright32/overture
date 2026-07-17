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
    }

    // The lifetime tally for one source across every prospect it ever surfaced, whatever became of them:
    // this is the "has it earned its place over a year" question, so a past show counts as much as a live
    // one. A show surfaced by several sources (the upsert merges a venue's calendar and the presenter's
    // own site into one row) credits each of them, because each genuinely did surface it.
    static func tally(sourceId: String, in prospects: [Prospect]) -> Tally {
        var t = Tally(found: 0, unreviewed: 0, kept: 0, approved: 0, sent: 0, booked: 0)
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
