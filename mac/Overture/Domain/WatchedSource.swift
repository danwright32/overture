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

    // The hash of the page we pinned and handed to the extract run, held until that run comes back.
    //
    // It has to be remembered, because the results file does not echo it and the ingest happens minutes
    // later in a different process: by then the live page may have changed again, so re-hashing it would
    // stamp a hash for bytes nobody ever read. Promoted to `lastContentHash` ONLY by an ingest that
    // actually saved. A run that dies before reaching this source leaves it set, so the next run picks
    // the source up again rather than skipping it forever. Defaulted, so existing rows migrate cleanly.
    var pendingContentHash: String? = nil

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
                               baseline: baselineFeedCount)
    }

    // #875: what the run itself said about this source, in words, and the raw log behind it. Same rule as
    // above: decided here, never in the view.
    var runNote: String? { SourceNote.summary(notes) }
    var runNoteDetail: String? { SourceNote.detail(notes) }

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

    // The dispatch rule, stated as a property of the row so Phase 4's loop cannot be written any other
    // way. Carnegie's endpoint is a POST search API that needs an app id, an api key and a JSON body
    // (CarnegieExtractor.swift). SourceFetcher's GET cannot retrieve it, hash it or diff it, so the
    // whole html path (fetch, hash, budget, pin, extract queue) must skip this row and run
    // CarnegieExtractor natively instead.
    var usesNativeExtractor: Bool { kind == .algolia }
    var isGenericallyFetchable: Bool { !usesNativeExtractor }
}

enum SourceKind: String, Codable, Equatable, Sendable, CaseIterable {
    case algolia        // a structured JSON feed we query directly (Carnegie, and only Carnegie)
    case html           // an org's rendered events page, read by the extract run
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

    // A verdict is only a failure when it means the page is broken or we are blind to it. A quiet
    // off-season is the NORMAL state (5 of the #770 spike's 7 real sites, in July) and reporting it as
    // a failure would train Dan to ignore the failing section, which is where the one source that is
    // genuinely broken has to be visible.
    init?(verdict: PageVerdict) {
        switch verdict {
        case .upcomingListings, .allPast: return nil
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
        case .verdict(let v):                return "verdict_\(v.rawValue)"
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
        }
    }
}
