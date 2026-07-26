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
        // The silent half worth Dan's eyes: it ran and looks fine, but too many of its event pages came back
        // unreadable, so it has forfeited the right to say a show is gone and its scraper may be genuinely
        // broken. Asked of FeedReconcile, the one place that line is drawn, so this can never disagree with
        // the reconcile that acted on it or the sentence Dan reads in the sheet.
        //
        // #1428: deliberately NOT hasForfeitedAbsence, which also ORs in shrunkenFeedForfeitsAbsence. A feed
        // that simply came back smaller (every show read cleanly) is a SELF-HEALING hold: Overture pauses
        // marking its shows gone until the size holds, then re-baselines on its own after three stable reads
        // with no input from Dan. Counting that as "needs a look" makes the badge cry wolf (#805/#863/#885);
        // seen on 54 Below. The hold is still disclosed on the row, just not as work.
        return FeedReconcile.unreadPagesForfeitAbsence(readable: source.lastReadableCount,
                                                       unreadable: source.lastUnreadableCount)
    }

    static func count(_ sources: [WatchedSource]) -> Int {
        sources.filter(needsALook).count
    }

    // #1541: the sheet's own ordering, decided here so the badge's number and the rows behind it are ONE
    // number by construction rather than two counts that happen to agree (#805/#863/#885).
    //
    // The toolbar told Dan a source needed him and then dropped him at the top of 66 alphabetical rows
    // with no route to it. Measured 2026-07-26: the source counted was The Players Theatre, fifty rows
    // down under T, while the FIRST row on screen carried a prominent "Fix the address" button and was a
    // different source entirely. The state that fires here grades as `.watching`, so no existing section
    // grouped it.
    //
    // Rows that need a look are lifted out of `rest`, never copied, so nothing is listed twice: a failing
    // source is real attention AND grades as Failing, and would otherwise appear in both places.
    // Alphabetical inside the section, so the sheet cannot reshuffle between redraws.
    static func split(_ sources: [WatchedSource]) -> (needsALook: [WatchedSource], rest: [WatchedSource]) {
        let attention = sources.filter(needsALook).sorted { $0.orgName < $1.orgName }
        let ids = Set(attention.map(\.sourceId))
        return (attention, sources.filter { !ids.contains($0.sourceId) })
    }

    // The section's own words. Kept beside the rule rather than in the view (#863/#885), so the copy
    // inventory reads them and a test can pin them.
    static let sectionLabel = "Needs a look"
    static let sectionSystemImage = "exclamationmark.circle"

    // NO explanation line under the heading, deliberately, and this was caught by the #843/#844 cold read
    // rather than by any test. The obvious one ("Failing, or no longer able to tell you when a show has
    // been cancelled") reads one line above the row's OWN sentence, which for Dan's only current case says
    // "149 of 149 shows had no venue on their own detail page, so Overture won't mark anything from this
    // source as gone until it can confirm one." That is the same fact twice, a line apart, which is the
    // defect #840/#841/#843 keep being filed for. The heading names the group; each row says why it is in
    // it, more specifically than any shared sentence could. `.watching` lost its explanation for exactly
    // this reason.

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
