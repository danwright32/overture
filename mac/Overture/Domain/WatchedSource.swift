import Foundation
import SwiftData

// #800 / #768: a source Overture re-checks on every scout. Carnegie stops being a hardcoded call and
// becomes row one of this table.
//
// Two things are held apart here on purpose, because Dan named the confusion he fears:
//
//   isActive   Dan's and the org's. False means STOPPED, and only ever that: the org asked to be left
//              alone, or Dan removed a permanently dead source. It never means "broken".
//   health     The scout's. ok / failing / neverChecked. A failing source is STILL WATCHED, still
//              reported every run, and is never auto-deactivated.
//
// One status enum would make "broken" and "they asked us to stop" representable as the same state, and
// every future UI change would be one careless `if !isActive { grey it out }` away from showing an org
// that asked Dan to stop as merely a source with a bad scraper, or the reverse. They are different
// facts about different things, so they are different fields.
@Model
final class WatchedSource {
    // Not `id`. PersistentModel already refines Identifiable through persistentModelID, and a stored
    // `var id` collides with that conformance. `naturalKey` on Prospect is the same convention.
    @Attribute(.unique) var sourceId: String

    var orgName: String
    // For an html source, the page we fetch. For Carnegie it is DISPLAY ONLY (what Dan clicks in the
    // Sources sheet): its real endpoint is a POST search API. See `isGenericallyFetchable`.
    var listingsURL: String?
    var kindRaw: String

    var isActive: Bool
    var inactiveReasonRaw: String?

    // Scout-owned, all of it.
    var healthRaw: String
    var lastErrorRaw: String?
    var lastCheckedAt: Date?
    // #1189: the manual scout's OWN fairness clock, held apart from the shared lastCheckedAt above.
    //
    // lastCheckedAt is the shared fetch/hash clock: the free daily watch-only run stamps it on EVERY
    // fetchable source every morning. That daily flatten is exactly what broke coverage. The manual read
    // plan used to order purely by oldest lastCheckedAt, so once the overnight run had reset all ~37
    // sources to one identical value, "the first 20" was the same 20 every press and the same ~17-source
    // tail was deferred forever, their changed calendars silently never read.
    //
    // This clock is advanced ONLY by a run Dan started (ScoutService's fetch loop at .readChanged) and
    // only for the sources that run actually checked; the daily watch-only run never touches it. Ordering
    // the read plan by it means a source the last press deferred stays genuinely next in line across days,
    // no matter how many times the daily run re-stamps lastCheckedAt. Defaulted, so existing rows migrate
    // cleanly as a lightweight SwiftData migration and simply carry no manual-read history (nil sorts
    // oldest, so every source is fairly first-in-line on the first manual press after upgrade).
    var lastManualReadAt: Date? = nil
    var lastSucceededAt: Date?
    // Stamped ONLY after a successful ingest that saved, never at fetch time. Stamp it at fetch time
    // and a run that classifies everything and then fails to persist (the #499 saveFailed path) leaves
    // the hash saying "nothing changed": the source then fetches fine, reports fine, and silently
    // ingests nothing, forever.
    var lastContentHash: String?

    // The warmup counter (Phase 3): a source accrues no misses until it has a feed history of its own.
    var successfulCheckCount: Int

    // #802: this source's listings page has changed since the last time we successfully ingested it.
    // Set by any check that sees a new hash; cleared only by an ingest that actually saved.
    //
    // It exists because of Dan's 4th decision: the free daily run fetches and hashes every source but
    // never reads one, so it needs somewhere to say "there is something here we have not read yet"
    // without spending a token to find out what. Defaulted, so existing rows migrate cleanly.
    var hasUnreadChanges: Bool = false

    // #1027: the page hash Dan CONFIRMED as acceptably empty ("this really is the org's calendar, it
    // is just quiet right now"). A future no_dated_content read whose bytes still hash to this value is
    // not a failure and does not nag; the instant the page changes, the hash differs and it nags again.
    // That is "until its content changes" expressed as the same hash test the rest of the feature uses.
    // Defaulted, so existing rows migrate cleanly and simply carry no confirmation.
    var confirmedEmptyHash: String? = nil

    // The hash of the page we pinned and handed to the extract run, held until that run comes back.
    //
    // It has to be remembered, because the results file does not echo it and the ingest happens minutes
    // later in a different process: by then the live page may have changed again, so re-hashing it would
    // stamp a hash for bytes nobody ever read. Promoted to `lastContentHash` ONLY by an ingest that
    // actually saved. A run that dies before reaching this source leaves it set, so the next run picks
    // the source up again rather than skipping it forever. Defaulted, so existing rows migrate cleanly.
    var pendingContentHash: String? = nil

    // #897: the months SourceFetcher stitched into the pinned page this run is about to read (#858), held
    // alongside pendingContentHash until the run comes back. A stitched multi-month page is a trustworthy
    // feed for reconcile ONLY once the run has read every one of these; a run that covered fewer of them
    // read a SHORTER page than the app fetched and hashed, and its silence about a show is then worth
    // nothing (SweepCoverage). Stored as a newline-joined scalar rather than a `[String]` column so
    // existing rows migrate with no transformable storage. Empty for the single-month watchlist default
    // (monthHorizon 1), where the check is inert, which is what keeps this dormant until pagination is on.
    var pendingPageMonthsRaw: String = ""

    var pendingPageMonths: [String] {
        get { pendingPageMonthsRaw.isEmpty ? [] : pendingPageMonthsRaw.components(separatedBy: "\n") }
        set { pendingPageMonthsRaw = newValue.joined(separator: "\n") }
    }

    // #1048: the hash of the page the most recent fetch actually SAW, whether or not that run read or
    // ingested it. Unlike lastContentHash (last INGESTED) and pendingContentHash (last READ and pinned,
    // awaiting ingest), this is "the live page as far as we know", updated by every successful fetch
    // including the free daily watch-only pass that notices a change but never re-reads.
    //
    // It exists for exactly that watch-only pass. When it sees the page move on it records the new hash
    // here and sets hasUnreadChanges, but leaves pendingContentHash on the old bytes it never re-read. So
    // in the Sources sheet a confirm can anchor to bytes the live page no longer serves, and the next real
    // read will not match, so the confirmation silently fails to suppress. Comparing this against the
    // anchor is what tells a fresh read from a stale one (see confirmReadIsStale). Defaulted, so existing
    // rows migrate cleanly and simply carry no observation until their next check.
    var lastObservedContentHash: String? = nil

    // The three UserDefaults keys of the #150/#152 self-heal machinery, per source. A merged
    // multi-source feed count must never feed a shared baseline: one healthy source's big season would
    // mask another source's dead scraper, which is the exact failure this whole model exists to make
    // structurally impossible.
    var baselineFeedCount: Int
    var degradedStreak: Int
    var lastDegradedCount: Int

    // #891: what the last run that READ this source managed to read, and what it could not (an event whose
    // own detail page was never reached comes back with no venue and is dropped).
    //
    // Persisted rather than merely reported in the run summary, because the consequence persists: past
    // FeedReconcile's tolerance this source has forfeited the right to mark anything cancelled (#887), and
    // it keeps forfeiting it until it can read its pages again. A fact Dan can only see in the seconds
    // after a scout is a fact he will never see, because that is not when he opens the Sources sheet.
    //
    // Defaulted, so existing rows migrate cleanly and simply carry no history.
    var lastReadableCount: Int = 0
    var lastUnreadableCount: Int = 0
    // #1032: of `lastUnreadableCount`, how many were dropped for having no TITLE (a row with no name)
    // rather than no venue. The Sources note's "no venue on their own detail page" sentence is true only
    // of the venue drops, so it counts these apart instead of mislabeling a titleless row. Defaulted, so
    // existing rows migrate cleanly and simply carry no title-drop history.
    var lastUnreadableTitleCount: Int = 0
    // #1472: rows the last run did not import because the SOURCE published no venue for them, kept apart from
    // `lastUnreadableCount` rather than added to it. OPERA America leaves 34 of its 92 NY-area rows blank, per
    // production, on every scout; counted as unreadable pages that is 37% against a 5% tolerance, so the
    // source forfeited gone-marking forever and sat in the toolbar badge with nothing Dan could do about it.
    // Disclosed on the row (SourceReadability) and deliberately absent from SourceAttention.needsALook.
    // Defaulted, so existing rows migrate cleanly and simply carry no history of it.
    var lastStructuralGapCount: Int = 0

    // #986: how many of the last run's kept shows said WHERE they are, and whether this source has EVER said
    // so. #970's gate reads only that `location` string (EventPlace.resolve never sees the venue), so a run
    // that silently stopped reporting it looks exactly like a page that never named a city, and both keep and
    // flag everything. Only the source's own history tells those apart.
    //
    // The stored flag is what was true BEFORE the last run, not after it, and that is deliberate: the note
    // has to distinguish a source's FIRST placing run (say the baseline once) from its tenth (say nothing),
    // and a plain high-water mark set during the run makes those two identical the moment it is written.
    //
    // Defaulted, so existing rows migrate cleanly. An already-placing source reads as new on its next run and
    // says its baseline line once, which is the harmless direction: the alternative is silence forever.
    var lastPlacedCount: Int = 0
    var hadPlacedBeforeLastRun: Bool = false

    // #1175: the venue's real location, supplied by Dan, for a single-venue feed source whose synthesized
    // document carries no city (VenueTix reports only an opaque venue id). When set, it is stamped into
    // every event's place line so the extractor reads a real address and the geography gate places the
    // shows in-region instead of `.unknown`. nil for the ordinary source, whose events carry their own
    // location (a national calendar, a fetched page), so this changes nothing for them.
    var venueLocation: String? = nil

    // #1209: Dan's manual override of whether this source is a known client's (see ClientHorizon). nil (the
    // default) means "decide automatically", by matching the org name against the Downbeat client list, so
    // a client added or removed in Downbeat arms or disarms the year-ahead read on its own with no stale
    // flag. true force-ARMS a source the name-match cannot catch (a client performing at a shared venue,
    // whose source org name is the venue, not the client); false force-DISARMS a coincidental name match.
    // Defaulted nil so the SwiftData migration is lightweight and every ordinary source is unaffected.
    var clientTagOverride: Bool? = nil

    // #1358: which Downbeat client a `clientTagOverride == true` tag NAMES (the client's stable Downbeat
    // id), for the shared-venue case where the source org name is the venue, not the client, so the
    // automatic name-match can never recognize the client. Only meaningful when clientTagOverride == true;
    // nil means a bare "always" tag that arms the year-ahead horizon (ClientHorizon) but names no specific
    // client. When set, ClientCoverage.isArmed counts that client as covered for real, instead of leaving it
    // a standing gap Dan can only silence by hiding it. Defaulted nil for a lightweight SwiftData migration.
    var clientTagClientId: String? = nil

    // #1236: some sources list one concert as several rows, one per conductor (DCINY). When set, the scout
    // merges every same-date, same-venue listing from this source into one prospect (via a synthetic
    // seriesId stamped at ingest, see SameDateVenueMerge), keeping every conductor name. Defaulted false so
    // the SwiftData migration is lightweight and every ordinary source is unaffected: a normal presenter's
    // matinee and evening on one date must stay two concerts, so this is never global.
    var mergeSameDateVenue: Bool = false

    var pageCount: Int
    var addedAt: Date
    // #875: the last run's own account of this source, verbatim, as it wrote it. Kept whole (sentence
    // AND log tail); SourceNote decides which half Dan reads where.
    //
    // This field already existed and was dead: declared, set to nil, never read or written. It is the
    // note, so it becomes the note, rather than a second field doing the same job beside it.
    var notes: String?

    // The line the Sources sheet shows, or nothing when this source read everything and came back its usual
    // size. Decided beside the data and NOT in the view (#863/#885), and drawn from the same rules the
    // reconcile used, so the sheet can never tell Dan cancellation is working on a source where it is
    // switched off.
    //
    // #897: the baseline goes in too, because a shrunken feed switches cancelling off just as an unreadable
    // one does. `baselineFeedCount` is the post-run value, which is the RIGHT one to compare against: a run
    // too small to be believed leaves the baseline where it was (updatedHealth), so this asks exactly the
    // question the next reconcile will ask, and clears itself the moment the smaller size is accepted.
    var readabilityNote: String? {
        SourceReadability.note(readable: lastReadableCount, unreadable: lastUnreadableCount,
                               titleRejected: lastUnreadableTitleCount,
                               structuralGaps: lastStructuralGapCount, baseline: baselineFeedCount)
    }

    // #1428/#1472: whether `readabilityNote` reports something no action of Dan's would change (a smaller feed
    // read cleanly, or rows the source itself published with no venue) rather than an actionable forfeit. The
    // Sources sheet colors those lines as plain text, not the gold an actionable problem gets. Derived from the
    // same rule as the sentence, so the flag and the words can never disagree.
    var readabilityNoteIsInformationalOnly: Bool {
        SourceReadability.noteIsInformationalOnly(readable: lastReadableCount,
                                                  unreadable: lastUnreadableCount,
                                                  structuralGaps: lastStructuralGapCount,
                                                  baseline: baselineFeedCount)
    }

    // #986: has this source EVER said where one of its shows is? A high-water mark, derived rather than
    // stored, so it cannot disagree with the two facts it is made of. Never goes back to false: a source that
    // could once place and now cannot has drifted, and one that forgot would quietly rejoin the venue
    // calendars and never be asked about it again.
    var hasEverPlaced: Bool { hadPlacedBeforeLastRun || lastPlacedCount > 0 }

    // #1001/#1005: the bookkeeping a successful, fully read run folds into this source, shared by BOTH
    // ingest paths (the native Carnegie sweep in ScoutService.recordCheck and the agent extract run in
    // ScoutExtractIngest.recordSuccess). It used to be two near-identical copies, and the #986 placement
    // detector was wired into only one of them, so a native run silently never recorded whether its shows
    // said where they are. One function means the health fold, the #891 readable/unreadable counts and the
    // #986 placement detector can never again diverge between the two doors.
    //
    // Every count is written HERE, on the caller's success branch, so it can only ever describe the run
    // that produced it and never a later or earlier one (#891). The pre-run placement answer is captured
    // BEFORE this run's count overwrites it, and in THAT order (#986), or a source's first placing run
    // would be indistinguishable from its tenth and the baseline line would never appear.
    //
    // Deliberately does NOT touch the content hash. That is the agent path's alone (the native Algolia feed
    // has no fetched page to hash), so its caller promotes the hash itself after this returns.
    func recordSuccessfulRead(events: Int, unreadable: Int, titleUnreadable: Int = 0,
                              structuralGaps: Int = 0, placed: Int,
                              feedHealth: FeedReconcile.FeedHealthState, now: Date) {
        // #1114: record this scout's movement (current vs the previous scout's count, and the baseline)
        // BEFORE the fields below overwrite them, so #913 has real per-source movement to retune against.
        FeedMovementLog.record(for: self, current: events, now: now)

        lastReadableCount = events
        lastUnreadableCount = unreadable
        lastUnreadableTitleCount = titleUnreadable
        lastStructuralGapCount = structuralGaps

        hadPlacedBeforeLastRun = hasEverPlaced
        lastPlacedCount = placed

        let updated = FeedReconcile.updatedHealth(feedHealth, currentCount: events)
        baselineFeedCount = updated.baseline
        degradedStreak = updated.degradedStreak
        lastDegradedCount = updated.lastDegradedCount

        lastCheckedAt = now
        lastSucceededAt = now
        health = .ok
        lastFailure = nil
        successfulCheckCount += 1
    }

    // #1029: the venue-precision line this source used to show Dan is gone (he did not understand why it
    // mattered). The placement DATA above (lastPlacedCount / hadPlacedBeforeLastRun / hasEverPlaced) is
    // still recorded on every run, kept for #970's drift detection; only the Dan-facing sentence and its
    // SourcePlacement.note generator were removed.

    // #875: what the run itself said about this source, in words, and the raw log behind it. Same rule as
    // above: decided here, never in the view.
    var runNote: String? { SourceNote.summary(notes) }
    var runNoteDetail: String? { SourceNote.detail(notes) }

    // #1048: would a "This page is right" confirm made right now silently fail to stick? confirmEmpty
    // anchors confirmedEmptyHash to the bytes last READ (pendingContentHash, or the last ingested hash).
    // If a watch-only pass has since seen the live page change (lastObservedContentHash moved past that
    // anchor), the next real read will not match the anchor, so the confirmation would not suppress and
    // the source would nag again. Decided beside the data and NOT in the view (#863), so the Sources
    // confirm affordance can warn on a tested rule rather than reasoning about hashes in SwiftUI.
    var confirmReadIsStale: Bool {
        SourceConfirmation.readIsStaleForConfirm(anchorHash: pendingContentHash ?? lastContentHash,
                                                 lastSeenHash: lastObservedContentHash)
    }

    init(sourceId: String, orgName: String, listingsURL: String? = nil, kind: SourceKind,
         addedAt: Date = Date()) {
        self.sourceId = sourceId
        self.orgName = orgName
        self.listingsURL = listingsURL
        self.kindRaw = kind.rawValue
        self.isActive = true
        self.inactiveReasonRaw = nil
        self.healthRaw = SourceHealth.neverChecked.rawValue
        self.lastErrorRaw = nil
        self.lastCheckedAt = nil
        self.lastSucceededAt = nil
        self.lastContentHash = nil
        self.successfulCheckCount = 0
        self.baselineFeedCount = 0
        self.degradedStreak = 0
        self.lastDegradedCount = 0
        self.lastReadableCount = 0
        self.lastUnreadableCount = 0
        self.lastUnreadableTitleCount = 0
        self.pageCount = 1
        self.addedAt = addedAt
        self.notes = nil
    }

    // Carnegie's row. A constant, not a lookup: the scout stamps it on every prospect it inserts, and
    // Phase 4 is what starts iterating real rows.
    static let carnegieId = "carnegie"
    // The pseudo-source for a lead Dan added by hand (#799). It has no row and no feed, which is why it
    // can never be reconciled against one (#826, and permanently in Phase 3).
    static let manualId = "manual"

    // A source accrues no misses until it has this many successful checks of its own. A brand-new
    // source imports a whole season on its first check and may legitimately look different on its
    // second; it must not be able to mark anything gone before it has a baseline to judge against.
    static let warmupRuns = 3

    // The id for a newly watched calendar. Derived from its host, so it is stable, readable in a queue
    // file and a pinned page's filename, and cannot collide with the two reserved ids above.
    //
    // Never derived from the full URL: an org that publishes /events and /calendar would otherwise get
    // two ids for one organization. The host is what identifies them, which is the same rule the
    // already-watching check uses.
    static func newSourceId(for listingsURL: String) -> String {
        let host = URL(string: listingsURL)?.host?.lowercased()
            .replacingOccurrences(of: "www.", with: "") ?? "source"
        return ScoutPagePin.safeName(host)
    }

    var kind: SourceKind {
        get { SourceKind(rawValue: kindRaw) ?? .html }
        set { kindRaw = newValue.rawValue }
    }

    var health: SourceHealth {
        get { SourceHealth(rawValue: healthRaw) ?? .neverChecked }
        set { healthRaw = newValue.rawValue }
    }

    var inactiveReason: SourceInactiveReason? {
        get { inactiveReasonRaw.flatMap(SourceInactiveReason.init(rawValue:)) }
        set { inactiveReasonRaw = newValue?.rawValue }
    }

    var lastFailure: SourceFailure? {
        get { lastErrorRaw.flatMap(SourceFailure.init(raw:)) }
        set { lastErrorRaw = newValue?.raw }
    }

    // #1217: did this source's LAST check end in anything other than a clean success? Either a hard fetch
    // failure (health failing, or a recorded lastFailure), or a read that dropped one or more events (the
    // degraded "won't mark anything gone until it can confirm a venue" state, lastUnreadableCount > 0). A
    // clean unchanged success is NOT this. It is read off state Overture already stores, no new
    // persistence, and it is what lets a MANUAL scout force a re-read of a still-broken source even when
    // the page hash is unchanged, on the assumption Dan fixed the underlying cause between scouts.
    var lastCheckWasNotCleanSuccess: Bool {
        health == .failing || lastFailure != nil || lastUnreadableCount > 0
    }

    // The dispatch rule, stated as a property of the row so Phase 4's loop cannot be written any other
    // way. Carnegie's endpoint is a POST search API that needs an app id, an api key and a JSON body
    // (CarnegieExtractor.swift). SourceFetcher's GET cannot retrieve it, hash it or diff it, so the
    // whole html path (fetch, hash, budget, pin, extract queue) must skip this row and run
    // CarnegieExtractor natively instead.
    var usesNativeExtractor: Bool { kind.usesNativeExtractor }
    var isGenericallyFetchable: Bool { !usesNativeExtractor }
}

enum SourceKind: String, Codable, Equatable, Sendable, CaseIterable {
    case algolia        // a structured JSON feed we query directly (Carnegie, and only Carnegie)
    case html           // an org's rendered events page, read by the extract run
    // #1237: two host-routed feed adapters that already parse their venue's shows into clean structured
    // events. They ingest natively for FREE (no paid AI read), exactly as Carnegie's Algolia feed does.
    case operaAmericaFeed = "opera_america_feed"   // OPERA America's national opera calendar (Umbraco feed)
    case venueTixFeed = "venue_tix_feed"           // any *.venuetix.com single-venue feed (Green Room 42, ...)
    case ovationTixFeed = "ovation_tix_feed"       // any *.ovationtix.com single-venue feed (SoHo Playhouse, ...)

    // The dispatch rule, in one place so nothing can disagree about which sources cost a paid read. A
    // native source ingests structured events synchronously and free on every run (including the automatic
    // daily one); an html source is fetched, hashed, and read by the paid extract run only when it changes.
    var usesNativeExtractor: Bool {
        switch self {
        case .algolia, .operaAmericaFeed, .venueTixFeed, .ovationTixFeed: return true
        case .html: return false
        }
    }

    // #1472: whether a row from this kind that carries NO VENUE is the source's own blank field rather than a
    // page Overture failed to read. Those are opposite facts and #887's tolerance was adding them together,
    // so National Opera Center's 34 blank feed rows (OPERA America's data entry, per production, recurring on
    // every scout) read as a broken scraper and cost it gone-marking permanently.
    //
    // A native feed parses structured rows and never hops to a per-event detail page: there is no page that
    // could have failed, so a blank venue can only be what the publisher wrote. An .html source is read by the
    // extract run, which DOES fetch each event's own detail page, so a blank venue there stays suspicious
    // until the run itself says the page publishes none (#1469).
    //
    // Deliberately its own switch rather than a reuse of `usesNativeExtractor`, which answers a different
    // question (does this row cost a paid read). They agree today and an exhaustive switch means a new kind
    // has to decide this on its own terms.
    var venueGapsAreStructural: Bool {
        switch self {
        case .algolia, .operaAmericaFeed, .venueTixFeed, .ovationTixFeed: return true
        case .html: return false
        }
    }

    // #1450: whether this source is watched at an address a person could correct. Deliberately NOT the
    // same question as usesNativeExtractor: the three host-routed adapters ingest natively AND are watched
    // at a real URL that can be wrong, so they keep the address control. Only Carnegie's listings URL is a
    // display-only placeholder over a POST search API, which nothing may ever fetch.
    var hasEditablePage: Bool {
        switch self {
        case .algolia: return false
        case .html, .operaAmericaFeed, .venueTixFeed, .ovationTixFeed: return true
        }
    }

    // The kind a newly watched (or launch-migrated) listings URL should carry. #1237: the two host-routed
    // feed adapters ingest natively for free; everything else is read as html. Carnegie's .algolia is
    // seeded by hand (its listings URL is a display-only placeholder over a POST search API), never here.
    // One rule, shared by the add path and the migration, so a source can never be watched html on one
    // path and native on the other.
    static func forListingURL(_ url: URL?) -> SourceKind {
        guard let url else { return .html }
        if OperaAmericaCalendar.handles(url) { return .operaAmericaFeed }
        if VenueTixCalendar.handles(url) { return .venueTixFeed }
        if OvationTixCalendar.handles(url) { return .ovationTixFeed }
        return .html
    }
}

// Scout-owned. Never means "stopped": see SourceInactiveReason for that.
enum SourceHealth: String, Codable, Equatable, Sendable, CaseIterable {
    case ok
    case failing        // still watched, still reported every run, never auto-deactivated
    case neverChecked
}

// The ONLY two things that take a source off the watchlist. Neither of them is "it broke".
enum SourceInactiveReason: String, Codable, Equatable, Sendable, CaseIterable {
    case orgRefusal     // they asked Dan to stop. The one mistake that cannot be taken back.
    case removedByDan   // a permanently dead source Dan chose to stop watching. Not a refusal.
}

// The named reason a check produced no usable listings.
//
// Deliberately NOT a third hand-written list of error names. It is composed from the two types that
// already own these facts: SourceFetchError (the fetch itself failed) and PageVerdict (the fetch
// worked and the page was useless anyway). A parallel list would drift from what the fetcher actually
// throws and what the extractor actually reports, and the first symptom would be a source reporting a
// failure nobody can act on.
enum SourceFailure: Equatable, Sendable {
    case fetch(SourceFetchError)
    case verdict(PageVerdict)
    // #857: the run's verdict disagreed with the events it returned (it claimed the page was empty or
    // unreadable and still handed back shows, or claimed it found listings and handed back none). The
    // specific contradiction is carried in the source's note (the WHY line); this token is the WHAT.
    case inconsistentResult

    // A verdict is only a failure when it means the page is broken or we are blind to it. A quiet
    // off-season is the NORMAL state (5 of the #770 spike's 7 real sites, in July) and reporting it as
    // a failure would train Dan to ignore the failing section, which is where the one source that is
    // genuinely broken has to be visible.
    init?(verdict: PageVerdict) {
        switch verdict {
        // #1012: `incompleteExtraction` is real data, not a failure, unlike the three below it. Its
        // hash-latch suppression is handled by ScoutExtractIngest's own partial-check path, which never
        // routes through SourceFailure at all.
        case .upcomingListings, .allPast, .incompleteExtraction: return nil
        // #856: `notRead` is a failure for the reason that matters most here: the hash must NOT be
        // stamped and the unread flag must stay set, so the next scout reads the page rather than
        // skipping it forever on the strength of a run that never opened it.
        case .noDatedContent, .unreadable, .notRead: self = .verdict(verdict)
        }
    }

    // Stored on the row as a stable token, payload included, so a failure stays actionable across a
    // relaunch ("redirects to thirdstreetmusicschool.org" rather than merely "redirected").
    var raw: String {
        switch self {
        case .fetch(.http(let code)):        return "http_\(code)"
        case .fetch(.notHTML(let type)):     return "not_html:\(type ?? "")"
        case .fetch(.redirectedAway(let h)): return "redirected:\(h)"
        case .fetch(.unreachable):           return "unreachable"
        case .fetch(.feedShapeChanged):      return "feed_shape_changed"
        case .verdict(let v):                return "verdict_\(v.rawValue)"
        case .inconsistentResult:            return "inconsistent"
        }
    }

    // An unrecognized token is refused, never guessed at: a row whose failure we cannot read is better
    // shown as "checked, no failure recorded" than as a confidently wrong reason.
    init?(raw: String) {
        let parts = raw.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let token = String(parts[0])
        let payload = parts.count > 1 ? String(parts[1]) : ""
        switch token {
        case "unreachable":
            self = .fetch(.unreachable)
        case "feed_shape_changed":
            self = .fetch(.feedShapeChanged)
        case "inconsistent":
            self = .inconsistentResult
        case "not_html":
            self = .fetch(.notHTML(payload.isEmpty ? nil : payload))
        case "redirected":
            guard !payload.isEmpty else { return nil }
            self = .fetch(.redirectedAway(payload))
        default:
            if token.hasPrefix("http_"), let code = Int(token.dropFirst("http_".count)) {
                self = .fetch(.http(code))
            } else if token.hasPrefix("verdict_"),
                      let v = PageVerdict(rawValue: String(token.dropFirst("verdict_".count))),
                      let failure = SourceFailure(verdict: v) {
                self = failure
            } else {
                return nil
            }
        }
    }

    // #1027: CONFIRM ("this page is right, stop nagging") is offered on exactly ONE failure: a page
    // that fetched and read fine but carried no dated listings. Confirming a broken fetch or a JS page
    // we can never read would silence a source that never delivers, which is the opposite of the goal.
    var offersConfirm: Bool {
        if case .verdict(.noDatedContent) = self { return true }
        return false
    }

    // #1027: FIX (correct the URL) is offered wherever a wrong web address could plausibly be the
    // cause, which is everything EXCEPT the two failures no address change can fix: a run that ended
    // before opening the page (it self-heals on the next scout) and a run that contradicted itself (a
    // run bug, not a bad page).
    var offersFix: Bool {
        switch self {
        // #1171: a changed feed FORMAT is not a wrong ADDRESS. Re-pointing the URL cannot fix a platform's
        // feed shape change, so offering "Fix the address" here would be a false affordance (like notRead).
        case .verdict(.notRead), .inconsistentResult, .fetch(.feedShapeChanged): return false
        default: return true
        }
    }

    // What Dan reads in the Sources sheet.
    var message: String {
        switch self {
        case .fetch(let e):
            return e.errorDescription ?? "That page couldn't be read."
        case .verdict(.noDatedContent):
            return "That page has no dated listings on it. It may be the wrong page for this org."
        case .verdict(.unreadable):
            return "That calendar is drawn by JavaScript, so there is nothing to read in the page we fetch."
        case .verdict(.notRead):
            // #856: says what actually happened, and nothing more. The page is very probably fine; the
            // RUN died before opening it. Claiming the calendar is broken would send Dan to fix a page
            // that was never the problem.
            return "The run ended before reading this page, so it has not been read. The next scout will try it again."
        case .verdict(let v):
            return "The page came back as \(v.rawValue)."
        case .inconsistentResult:
            // Generic WHAT. The specific contradiction (which claim disagreed with which events) is the
            // run's own note, shown on the WHY line beneath this, so this line never repeats it (#843).
            return "This run's results disagreed with themselves, so nothing from it was used."
        }
    }
}
