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

    // #2231: a source that has never successfully read, once it is past its grace window. Both conditions
    // below are judgments about a source that HAS read and did badly, so the one shape they cannot see is
    // the source that never worked at all: it grades `.neverChecked`, contributes nothing, and sits under
    // "Not checked yet" beside a source added five minutes ago, which carries no time dimension at all.
    // Measured 2026-08-06 on The Players Theatre, which sat there with broken routing (#2229) and zero
    // shows, and could only ever be repaired once somebody happened to notice.
    //
    // The grace is the whole design question, because this state is legitimate and expected for a source
    // added minutes ago, and an alarm on that is exactly the cry-wolf failure #1428 and #1498 pulled back
    // from. Three days: the scout runs daily, so a source that has had three scheduled runs and still
    // never read one page is not waiting, it is broken. Judged from `addedAt`, which is on the row
    // already, and it stays flagged after a repointing until a read actually SUCCEEDS, because repointing
    // is a hope rather than evidence.
    static let neverReadGrace: TimeInterval = 3 * 24 * 60 * 60

    // #2211: a source that has come back empty on this many CONSECUTIVE runs is not having a quiet week.
    // Three, matching the scout's daily cadence and `FeedReconcile.selfHealThreshold`'s own "three stable
    // reads" for the mirror-image judgment, so the two halves of feed health escalate on the same clock.
    //
    // Once, deliberately, is not work: the scout summary already says so on the day it happens, and an
    // established calendar genuinely does have quiet days. What Dan could not see was the difference
    // between the first and the fifth, which is exactly the judgment the warning was asking him for.
    static let emptyStreakThreshold = 3

    static func hasGoneQuiet(_ source: WatchedSource) -> Bool {
        source.emptyStreak >= emptyStreakThreshold
    }

    static func hasNeverRead(_ source: WatchedSource, now: Date) -> Bool {
        guard source.successfulCheckCount == 0, source.lastSucceededAt == nil else { return false }
        return now.timeIntervalSince(source.addedAt) > neverReadGrace
    }

    // Three conditions, and consent outranks all of them. An org that asked Dan to stop, or a source he
    // chose to stop watching, can never appear as work he owes anyone, whatever its scraper is doing:
    // reading a refusal as "broken" invites him to go and fix it, and the natural end of fixing it is
    // pitching them again (#800). That mistake cannot be taken back, so it is not left to a view to avoid.
    static func needsALook(_ source: WatchedSource, now: Date = Date()) -> Bool {
        guard source.isActive else { return false }
        if SourceGrade(source) == .failing { return true }
        if hasNeverRead(source, now: now) { return true }
        if hasGoneQuiet(source) { return true }
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

    static func count(_ sources: [WatchedSource], now: Date = Date()) -> Int {
        sources.filter { needsALook($0, now: now) }.count
    }

    // #1541: the sheet's own ordering, decided here so the badge's number and the rows behind it are ONE
    // number by construction rather than two counts that happen to agree (#805/#863/#885).
    //
    // The toolbar told Dan a source needed him and then dropped him at the top of 66 alphabetical rows
    // with no route to it. Measured 2026-07-26: the source counted was The Players Theatre, fifty rows
    // down under T, while the FIRST row on screen carried a prominent "Change the page link" button and was a
    // different source entirely. The state that fires here grades as `.watching`, so no existing section
    // grouped it.
    //
    // Rows that need a look are lifted out of `rest`, never copied, so nothing is listed twice: a failing
    // source is real attention AND grades as Failing, and would otherwise appear in both places.
    // Alphabetical inside the section, so the sheet cannot reshuffle between redraws.
    static func split(_ sources: [WatchedSource], now: Date = Date())
    -> (needsALook: [WatchedSource], rest: [WatchedSource]) {
        let attention = sources.filter { needsALook($0, now: now) }.sorted { $0.orgName < $1.orgName }
        let ids = Set(attention.map(\.sourceId))
        return (attention, sources.filter { !ids.contains($0.sourceId) })
    }

    // The section's own words. Kept beside the rule rather than in the view (#863/#885), so the copy
    // inventory reads them and a test can pin them.
    // #2231: the row's own sentence for a source that has never read. Every row in this section says why
    // it is there, more specifically than the heading could (see the note below on why the heading itself
    // carries no explanation), and the never-read state had no sentence anywhere: it rendered under "Not
    // checked yet" exactly like a source added minutes ago.
    //
    // It names the AGE, because the age is the whole difference between this and the legitimate state it
    // looks like, and it says what has not happened rather than guessing why, since nothing here knows
    // whether the link is wrong, the site is down, or the page cannot be parsed.
    static func neverReadLine(addedAt: Date, now: Date) -> String {
        let days = max(1, Int(now.timeIntervalSince(addedAt) / 86_400))
        let dayWord = days == 1 ? "day" : "days"
        return "Watched for \(days) \(dayWord) and has never read its calendar once. Check the link."
    }

    // #2211: the row's own sentence for a source that has come back empty on several runs in a row. It
    // names WHICH run this is and WHEN it last listed anything, which is the whole of what the per-run
    // warning could not say: without them, run five reads exactly like run one, every run, forever.
    //
    // A row with no recorded last-non-empty date says so by leaving the clause out rather than inventing
    // one: this began recording after the fact, so an old row genuinely does not know.
    static func goneQuietLine(runs: Int, lastNonEmptyAt: Date?, now: Date) -> String {
        let runWord = runs == 1 ? "run" : "runs"
        guard let lastNonEmptyAt else {
            return "Came back empty \(runs) \(runWord) in a row. Check the link."
        }
        let days = max(1, Int(now.timeIntervalSince(lastNonEmptyAt) / 86_400))
        let dayWord = days == 1 ? "day" : "days"
        return "Came back empty \(runs) \(runWord) in a row, and hasn't listed a show for \(days) \(dayWord). Check the link."
    }

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
        // #2231 added the middle reason. Three is as many as this line can carry, and each names a
        // different state Dan would act on differently.
        return "\(subject) a look: failing, never read at all, empty run after run, or can't mark shows as gone until it reads its calendar properly again"
    }
}
