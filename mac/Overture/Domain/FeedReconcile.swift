import Foundation

// Reconciles stored prospects against the latest scout feed (#133). The scout only ever
// inserts/updates, so a kept prospect that later gets cancelled or pulled would linger in
// the queue as if still happening. After a scout, this bumps a per-prospect "missed" counter
// for anything that came from a scouted source and is still in the future but was NOT in this
// run's feed; a prospect that reappears resets to 0. Two consecutive misses
// (`goneThreshold`) mark it gone, so a one-off partial feed never wrongly cancels a real show.
//
// Deliberately NEVER touches Dan's keep/dismiss/outcome state — `disappearedFromFeed` is an
// orthogonal scout-owned signal the queue reads to hide untouched ones and flag pursued ones.
enum FeedReconcile {
    // Consecutive misses before a prospect is treated as gone. Two, so a single partial/empty
    // feed (a transient Carnegie glitch) can't cancel a still-real show on its own.
    static let goneThreshold = 2

    // The hosts the scout actually covers today. Only prospects from these sources are
    // reconciled, so a Carnegie scout never flags a future prospect sourced elsewhere.
    static let scoutedHosts: Set<String> = ["carnegiehall.org"]

    static func reconcile(stored: [Prospect], seenKeys: Set<String>, today: String,
                          scoutedHosts: Set<String> = scoutedHosts) {
        for p in stored {
            if seenKeys.contains(p.naturalKey) {
                p.missedScoutCount = 0                       // present this run: definitely live
            } else if isFromScoutedSource(p, hosts: scoutedHosts) && isFuture(p, today: today) {
                p.missedScoutCount += 1                       // expected in this feed, but absent
            }
            // Past performances and other-source prospects are left untouched: their absence is
            // not evidence of cancellation.
        }
    }

    private static func isFromScoutedSource(_ p: Prospect, hosts: Set<String>) -> Bool {
        guard let url = p.sourceListingURL else { return false }
        return hosts.contains { url.contains($0) }
    }

    // Future = any night of the (possibly multi-night) run is today or later. A run whose
    // opening night has passed but whose end date is still ahead is still a live show.
    private static func isFuture(_ p: Prospect, today: String) -> Bool {
        let last = p.runEndDate ?? p.performanceDate
        guard let last else { return false }
        return last >= today
    }
}
