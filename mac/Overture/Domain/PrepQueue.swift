import Foundation
import SwiftData

// The work-list the app hands to the Prep run: which kept prospects need a contact
// and a draft. `naturalKey` is an OPAQUE token the run must echo back verbatim into
// PrepResults (never reconstruct it; that is what caused the silent-mismatch risk).
// The human-readable fields are for the run's research only.

struct PrepQueue: Codable, Equatable, Sendable {
    var version: Int
    var generatedAt: String
    var items: [PrepQueueItem]
}

struct PrepQueueItem: Codable, Equatable, Sendable {
    var naturalKey: String        // opaque; echo verbatim, do NOT rebuild
    var groupName: String         // research only
    var venue: String?
    var performanceDate: String?  // the run's OPENING night (also the grouping/natural-key date)
    // v4 (#1122): the run's CLOSING night, nil for a single-night show. Present so a draft can pitch the
    // whole run (performanceDate through runEndDate), not just the opening night.
    var runEndDate: String? = nil
    var discipline: String
    var websiteURL: String?
    var sourceListingURL: String?
    var possibleMatchName: String?
    var priorRelationship: String
    var production: String?       // v2 (#586): self | agency | unknown, from Prospect.production/#349
    // v3 (#367): "draft_only" | "contacts_only", absent means do both. Set only for a prospect Dan
    // asked to re-prep; tells the run which half to skip for this item.
    var reprepMode: String? = nil
    // v4 (#1122): true only when this is a multi-night run whose OPENING night has already passed while
    // later dates remain. Absent (the common case: single-night, or a run not yet started) means "no
    // passed opening to work around". Derived with Swift date math (openingNightPassed below), never left
    // to the drafter to infer, so a draft never pitches or names the gone opening night.
    var openingNightPassed: Bool? = nil
}

enum PrepQueueBuilder {
    static let version = 4

    // v4 (#1122): true when `performanceDate` (the opening night) is behind us AND the run is still live
    // (its closing night, runEndDate ?? performanceDate, is today or later). A fully past run is false
    // (no dates remain to pitch), and so is a single-night show whatever its date, since there is no
    // "opening passed but later dates remain" case for one night. Judged through the same closing-night
    // helper the queue label and filter use (EasternDate.runLastNight/runHasPassed), so all three agree.
    static func openingNightPassed(performanceDate: String?, runEndDate: String?, today: String) -> Bool {
        let lastNight = EasternDate.runLastNight(runEndDate: runEndDate, performanceDate: performanceDate)
        guard !EasternDate.runHasPassed(lastNight: lastNight, today: today) else { return false }
        guard let performanceDate else { return false }
        return performanceDate < today
    }

    // A prospect is "to prep" when Dan kept it (.queued) and it has no draft yet, OR (#367) he
    // explicitly asked for a re-prep on a prospect that already has one, restricted to statuses
    // that still make sense to redraft/re-research (never .contacted or .dismissed). This is the
    // single source of truth every other eligibility check below should call, plain-Swift call
    // sites can call this function directly; the one SwiftData #Predicate-driven @Query
    // (RootView's "Prep kept" button gate) can't call an arbitrary function from inside a
    // #Predicate macro, so needsPrepPredicate below expresses the SAME logic as a standalone
    // Predicate value and PrepQueueEligibilityParityTests pins the two never drifting apart.
    // `hasUnclearedConflict` is deliberately NOT defaulted, and it is the only argument here that isn't.
    //
    // Defaulted, it was silently wrong the moment it shipped: StageNavigation called this without it, so
    // the Prep pill counted a show Dan is booked against and took him to it, while the Prep run refused to
    // draft it. That is exactly #863 (a pill's number is a promise about rows), reappearing in a new place
    // through a default value that made forgetting invisible. Required, forgetting it is a compile error.
    static func needsPrep(status: ReviewStatus, hasDraft: Bool,
                          reprepDraftRequested: Bool = false,
                          reprepContactsRequested: Bool = false,
                          hasUnclearedConflict: Bool) -> Bool {
        // #901: a show on a day Dan cannot work is not drafted until he says he can work it. Not a drop
        // (he still sees it, flagged, and decides), but no contacts are researched and no email is
        // written for a night he is already booked or away for: that is his money and the model's time
        // spent on a show that cannot happen.
        if hasUnclearedConflict { return false }
        if status == .queued && !hasDraft { return true }
        let reprepEligible = status == .queued || status == .drafted || status == .approved
        return reprepEligible && (reprepDraftRequested || reprepContactsRequested)
    }

    // A (Prospect) -> Bool wrapper over needsPrep, for passing straight to `.filter(...)` instead
    // of a closure with named arguments and defaults (the latter is slow enough for the Swift
    // type-checker to warn about in a plain-array `.filter { ... }`, this form checks instantly).
    static func needsPrepEligible(_ p: Prospect) -> Bool {
        needsPrep(status: p.status, hasDraft: p.hasDraft,
                 reprepDraftRequested: p.reprepDraftRequested,
                 reprepContactsRequested: p.reprepContactsRequested,
                 hasUnclearedConflict: p.hasUnclearedConflict)
    }

    // #953: whether a kept prospect defaults to INCLUDED when Dan opens a Prep run, decided purely by
    // how far out its performance is. A show inside the calendar horizon (today through today +
    // `monthsAhead` months) defaults checked; one beyond it defaults held (unchecked), so a long
    // lead-time show is not drafted before it is worth reaching out. This is only the DEFAULT: Dan can
    // toggle any row before running, and the selection is per-run and transient, never a stored flag.
    //
    // An undated prospect defaults IN: there is no date to hold it by, and this preserves the pre-#953
    // behaviour of prepping everything eligible. The horizon reuses CalendarMonthIndex.defaultHorizon
    // (the same four-month cap the scout reads its calendars to, Dan's call) so this window and that one
    // can never drift into two different answers.
    static func defaultsIncludedInPrepRun(performanceDate: String?, now: Date,
                                          monthsAhead: Int = CalendarMonthIndex.defaultHorizon) -> Bool {
        guard let performanceDate, let showDay = EasternDate.date(from: performanceDate) else { return true }
        let todayStart = EasternDate.date(from: EasternDate.today(now)) ?? now
        guard let boundary = EasternDate.calendar.date(byAdding: .month, value: monthsAhead, to: todayStart)
        else { return true }
        return showDay <= boundary
    }

    // #1209: which kept prospects a Prep run defaults to covering, held out of the SwiftUI view init so the
    // rule is testable (#863). Each prospect is measured against its OWN window: a known client's show (its
    // source is a client's, or it itself matched a client) gets the twelve-month client window, everyone
    // else the ordinary four, so a returning client's far-future date is not silently defaulted out of the
    // run the same way it is now surfaced a year ahead by the scout. Returns the naturalKeys to pre-check.
    static func prepDefaultSelection(prospects: [Prospect], sources: [WatchedSource],
                                     clients: [DownbeatClient], now: Date) -> Set<String> {
        Set(prospects.filter { p in
            defaultsIncludedInPrepRun(
                performanceDate: p.performanceDate, now: now,
                monthsAhead: ClientHorizon.prepMonths(for: p, sources: sources, clients: clients))
        }.map(\.naturalKey))
    }

    // The #Predicate mirror of needsPrep above, for the one call site (RootView's toPrep @Query)
    // that needs a compiled SwiftData predicate rather than a plain Swift function. Kept as a
    // single named, shared value so there is exactly one place this expression lives, not one
    // reinvented inline in RootView.swift.
    static var needsPrepPredicate: Predicate<Prospect> {
        #Predicate<Prospect> { p in
            // #901: the conflict gate. It reads the SAME stored column Prospect.hasUnclearedConflict
            // does, rather than re-deriving the rule from the two keys, which is both why it is trivial
            // here and why it cannot drift from the plain-Swift function above. (Expressed inline from
            // the keys, it overran the #Predicate type-checker outright; see Prospect.conflictOpen.)
            !p.conflictOpen
            && ((p.statusRaw == "queued" && p.draftBody == nil)
                || ((p.reprepDraftRequested || p.reprepContactsRequested)
                    && (p.statusRaw == "queued" || p.statusRaw == "drafted" || p.statusRaw == "approved")))
        }
    }

    // #367: the wire value for a queue item's reprepMode, derived from the prospect's two
    // independent flags. Both true (a "both" request) or both false (a normal, never-drafted
    // prospect) both mean "do both", so both collapse to nil, exactly as an absent field always
    // has: the run's default behavior.
    static func reprepModeString(draftRequested: Bool, contactsRequested: Bool) -> String? {
        switch (draftRequested, contactsRequested) {
        case (true, false): return "draft_only"
        case (false, true): return "contacts_only"
        default: return nil
        }
    }

    static func build(from prospects: [PrepQueueItem], generatedAt: String) -> PrepQueue {
        PrepQueue(version: version, generatedAt: generatedAt, items: prospects)
    }

    static func encode(_ queue: PrepQueue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(queue)
    }

    static var defaultURL: URL {
        StoreLocation.handoffDirectory
            .appendingPathComponent("overture-prep-queue.json")
    }
}
