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
    struct Tally: Equatable, Sendable {
        var found: Int
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
        var t = Tally(found: 0, kept: 0, approved: 0, sent: 0, booked: 0)
        for p in prospects where p.sourceIds.contains(sourceId) {
            t.found += 1

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

    // The quiet line the Sources sheet shows, kept-first (Dan's choice): "3 of 12 kept", with sent and
    // booked appended only when they are above zero, so a source that has produced nothing but leads to
    // pitch does not carry a trailing "· 0 sent · 0 booked" of noise.
    //
    // nil when the source has surfaced nothing yet: "0 of 0 kept" reads like a failure, and a brand-new
    // or off-season source is neither dead weight nor broken (its read state and health already speak for
    // it). The dead-weight signal this feature exists for is "0 of 12 kept", which is NOT silenced.
    static func line(_ tally: Tally) -> String? {
        guard tally.found > 0 else { return nil }
        var line = "\(tally.kept) of \(tally.found) kept"
        if tally.sent > 0 { line += " · \(tally.sent) sent" }
        if tally.booked > 0 { line += " · \(tally.booked) booked" }
        return line
    }
}
