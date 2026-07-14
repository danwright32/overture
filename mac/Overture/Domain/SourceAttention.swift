import Foundation

// #805: which watched sources need Dan's eyes, defined once.
//
// The failure this exists for has no symptom of its own. A source that 404s is loud, and reads as
// "Failing" in the sheet. A source that half works is silent: the fetch succeeds, the verdict is healthy,
// health stays .ok, and it returns 8 of the 12 shows it used to. It costs Dan four leads a season,
// indefinitely, and nothing anywhere says so.
//
// #917 gave that state a sentence (SourceReadability). A sentence inside a sheet Dan has no reason to open
// is not a symptom: it is a fact he will never see, which is the thing this issue said was the bug. So the
// toolbar carries the count, and the button he clicks changes how it LOOKS while a source needs him.
//
// The rule lives here and not in the toolbar's body for the reason DueWork exists: the number on the pill
// and the rows behind it must be the same number by construction, never two counts that happen to agree
// (#863, #885). A badge that says nothing is wrong while the sheet behind it is full of problems is worse
// than no badge at all, because Dan would learn to trust it.
enum SourceAttention {

    // Two conditions, and consent outranks both. An org that asked Dan to stop, or a source he chose to
    // stop watching, can never appear as work he owes anyone, whatever its scraper is doing: reading a
    // refusal as "broken" invites him to go and fix it, and the natural end of fixing it is pitching them
    // again (#800). That mistake cannot be taken back, so it is not left to a view to avoid.
    static func needsALook(_ source: WatchedSource) -> Bool {
        guard source.isActive else { return false }
        if SourceGrade(source) == .failing { return true }
        // The silent half: it ran, it looks fine, and it has quietly forfeited the right to say a show is
        // gone. Asked of FeedReconcile, which is the one place that line is drawn, so this can never come
        // to a different answer than the reconcile that acted on it or the sentence Dan reads in the sheet.
        return FeedReconcile.hasForfeitedAbsence(readable: source.lastReadableCount,
                                                 unreadable: source.lastUnreadableCount,
                                                 baseline: source.baselineFeedCount)
    }

    static func count(_ sources: [WatchedSource]) -> Int {
        sources.filter(needsALook).count
    }

    // A zero never sits on the masthead pretending to be work (#885). ToolbarHoverLabel shows this title
    // only while the pointer is on it, so the count is the detail, not the signal: the signal is the gold
    // tint the toolbar puts on the button, which is what Dan sees without going looking.
    static func badgeTitle(count: Int) -> String {
        count == 0 ? "Sources" : "Sources (\(count))"
    }

    // Words, never color alone (#800). The tint catches his eye; this says what it means, and it names the
    // consequence rather than merely reporting that something is off, because the consequence is the part
    // he can act on: a source in this state is no longer telling him when a show has been cancelled.
    static func help(count: Int) -> String {
        guard count > 0 else {
            return "The calendars Overture re-checks on every scout, and how each one is doing"
        }
        let subject = count == 1 ? "1 source needs" : "\(count) sources need"
        return "\(subject) a look: failing, or can't mark shows as gone until it reads its calendar properly again"
    }
}
