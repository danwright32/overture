import Foundation
import SwiftData

// #802: adding and removing a watched calendar by hand.
//
// Until this existed, a calendar could only join the watchlist by pasting a lead, and if Dan unticked
// "keep watching" on that sheet he could never change his mind: re-pasting the same link is refused as
// already handed over, and the Sources sheet was read-only. A dead end with no way out of it.
//
// The refusal rule is enforced HERE, not in the sheet, for the same reason it is enforced in
// LeadIntakeModel.confirm rather than in its checkbox: an org that asked Dan to stop must not be able to
// get back onto the watchlist by any route, including one he types in himself, and a guarantee that
// lives in a view is a guarantee that lasts until the next view.
@MainActor
enum WatchlistEditing {

    // #885: the do-not-contact refusal, written ONCE.
    //
    // SourcesView's own header calls this "the one thing in the whole feature that must not be got wrong
    // quietly", and it was written out by hand in three view bodies across two files, in two different
    // wordings, with no test on any of them. The type that RETURNS `.refused(orgName)` is the type that
    // should say what a refusal means.
    static func refusedMessage(orgName: String) -> String {
        "\(orgName) asked not to be contacted, so Overture won't watch their calendar."
    }

    // Resuming a stopped source is a different action, and keeps its own true sentence: "again" is doing
    // real work in it, and would be a lie on a source being added for the first time.
    static func resumeRefusedMessage(orgName: String) -> String {
        "\(orgName) asked not to be contacted, so Overture won't watch them again."
    }

    static func alreadyWatchingMessage(orgName: String) -> String {
        "Already watching \(orgName)'s calendar."
    }

    static let invalidURLMessage = "That doesn't look like a web address."

    static let needsNameMessage = "Give the organization a name so you can recognize it here."
    enum Result: Equatable, Sendable {
        case added
        case resumed                       // a source Dan had stopped, revived with its history intact
        case alreadyWatching(orgName: String)
        case refused(orgName: String)      // they asked him to stop. Not by this route either.
        case invalidURL
        case needsName
    }

    @discardableResult
    static func add(orgName: String, listingsURL: String, into context: ModelContext) -> Result {
        let name = orgName.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = listingsURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .needsName }
        guard let host = URL(string: url)?.host, !host.isEmpty,
              URL(string: url)?.scheme?.hasPrefix("http") == true else { return .invalidURL }

        let existing = (try? context.fetch(FetchDescriptor<WatchedSource>())) ?? []

        // Matched on CalendarIdentity, so an org that publishes /events, /calendar and /concerts cannot end
        // up on the list three times, fetching, hashing and reading the same calendar three times every
        // run, while two venues sharing a ticketing host stay two calendars (#2377).
        if let match = existing.first(where: { sameCalendar($0.listingsURL, as: url) }) {
            if !match.isActive, match.inactiveReason == .orgRefusal {
                return .refused(orgName: match.orgName)
            }
            if match.isActive { return .alreadyWatching(orgName: match.orgName) }

            // Stopped by Dan, and he has changed his mind. Revive the EXISTING row rather than inserting
            // a second one: it carries the feed history it earned, and its id is stamped on every
            // prospect it ever surfaced.
            match.isActive = true
            match.inactiveReason = nil
            match.listingsURL = url
            try? context.save()
            return .resumed
        }

        // #1237: a URL on one of the two host-routed feed adapters (OPERA, VenueTix) is watched natively
        // (free, structured ingest on every run); everything else is html, read by the paid extract run.
        context.insert(WatchedSource(sourceId: WatchedSource.newSourceId(for: url), orgName: name,
                                     listingsURL: url, kind: SourceKind.forListingURL(URL(string: url))))
        try? context.save()
        return .added
    }

    // Dan stops watching a source. Recorded as HIS decision, never as a refusal: one is a choice he can
    // revisit and the other is a line he must not cross, and a Sources sheet that showed them the same
    // way would eventually get somebody emailed who asked not to be.
    //
    // The row is kept, not deleted. Deleting it would take its feed history with it, and its id is
    // stamped on every prospect it ever surfaced.
    static func stopWatching(_ source: WatchedSource, in context: ModelContext) {
        source.isActive = false
        source.inactiveReason = .removedByDan
        try? context.save()
    }

    // #845: the way back, in place.
    //
    // Reversing a stop was already possible and graceless: retype the org name and the URL into the add
    // form, which matches the row by host and revives it. Dan could not see that from the button he had
    // just clicked, so a fully reversible action read as a permanent one, and he hesitated over the one
    // action #802's design expects him to take (a failing source NEVER auto-deactivates, precisely so that
    // removing it stays his deliberate choice).
    //
    // This is the same revival, reached by identity rather than by retyping a URL, so an Undo in the
    // banner and a "Watch again" button on the row can both offer it.
    //
    // The refusal is re-checked HERE, not left to the sheet that draws the buttons. The Sources sheet only
    // offers them on a source Dan stopped himself, which is correct and is not the point: an org that
    // asked him to stop must be unable to return to the watchlist BY ANY ROUTE, and a guarantee that lives
    // in a view is a guarantee that lasts until the next view. This is the one mistake here that cannot be
    // taken back, because it ends with somebody being emailed who asked not to be.
    @discardableResult
    static func resumeWatching(_ source: WatchedSource, in context: ModelContext) -> Result {
        if source.isActive { return .alreadyWatching(orgName: source.orgName) }
        guard source.inactiveReason != .orgRefusal else { return .refused(orgName: source.orgName) }

        source.isActive = true
        source.inactiveReason = nil
        try? context.save()
        return .resumed
    }

    // #1027: correcting a source's URL in place.
    //
    // The one rule that matters: a corrected URL is a BRAND-NEW source for reconcile. The id is KEPT (it
    // is stamped on every prospect the old page ever produced), but the feed history and warmup are
    // reset, so the new page cannot conclude any of those prospects are gone until it has read its own
    // pages enough times to have a baseline. Keep the id AND the baseline and a same-sized replacement
    // page silently strikes Dan's live shows: the exact silent-cancellation hole #887/#897 closed.
    enum EditResult: Equatable, Sendable {
        case saved(sourceId: String)
        case invalidURL
        case conflict(orgName: String)     // a DIFFERENT source already watches this calendar
        case refused(orgName: String)      // the new address belongs to an org that asked to stop
    }

    @discardableResult
    static func editURL(_ source: WatchedSource, to newURL: String, in context: ModelContext) -> EditResult {
        let url = newURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let host = URL(string: url)?.host, !host.isEmpty,
              URL(string: url)?.scheme?.hasPrefix("http") == true else { return .invalidURL }

        let existing = (try? context.fetch(FetchDescriptor<WatchedSource>())) ?? []
        // Another source already on this calendar. A refusal is named as a refusal (the one mistake that
        // cannot be taken back); anything else is a plain collision, because the same calendar must never
        // be fetched, hashed and read twice every run.
        if let match = existing.first(where: { $0.sourceId != source.sourceId && sameCalendar($0.listingsURL, as: url) }) {
            if !match.isActive, match.inactiveReason == .orgRefusal {
                return .refused(orgName: match.orgName)
            }
            return .conflict(orgName: match.orgName)
        }

        let previousURL = source.listingsURL
        source.listingsURL = url
        // #2229: the kind follows the address, exactly as it does on the ADD path above. It decides whether
        // this source is parsed natively and free on every run or handed to the paid extract run, and which
        // adapter SourceExtractorRegistry hands it to, so a source repointed onto a ticketing host while
        // still labelled `.html` sits on the paid path forever and never has Dan's `venueName` threaded in.
        // Measured: theplayerstheatre-com was watched at web.ovationtix.com carrying kind `html`.
        //
        // `.algolia` is the one kind never derivable from a URL (Carnegie's listings URL is a display-only
        // placeholder over a POST search API), so it is preserved rather than rewritten. `.squarespaceFeed`
        // is likewise unreachable from `forListingURL`, being assigned by a CONTENT probe, so a correction
        // demotes it to `.html`; that is right rather than lossy, because the new address may not be
        // Squarespace at all, and ScoutService re-probes any `.html` source on its next check.
        if source.kind != .algolia {
            source.kind = SourceKind.forListingURL(URL(string: url))
        }
        clearStateDerivedFromTheWatchedPage(source)
        // #2233: and, only when the correction moves the source to a DIFFERENT HOST, the two answers
        // that describe the building rather than the page.
        //
        // #2229 kept `venueName` and `venueLocation` through a correction on purpose: they are Dan's own
        // assertions, not observations of a page, and discarding an answer he typed is its own defect
        // (L5). That reasoning holds for what "Fix the address" is named for, a better page for the SAME
        // venue, which is every live use of it so far. It does not hold for the other case: repointed at
        // a genuinely different venue, the old room and street survive onto it, and for a single-venue
        // ticketing feed both are threaded into every show the source produces, so the new venue's shows
        // are attributed to the old room at the old address and the geography gate places them by it. A
        // wrong room in a pitch names the wrong building to the person reading it.
        //
        // The host is the same signal the conflict check above already computes. Cleared rather than
        // merely flagged, which is the simpler of the two shapes the issue weighed, and it costs Dan
        // nothing he cannot see: #1529's control already renders its gold "which room?" prompt for a
        // ticketing-feed source carrying no `venueName`, so the row asks again rather than asserting
        // something that was true of a different building.
        if !sameHost(previousURL, as: url) {
            source.venueName = nil
            source.venueLocation = nil
        }
        source.hasUnreadChanges = true          // so the next scout reads the corrected page
        try? context.save()
        return .saved(sourceId: source.sourceId)
    }

    // #2229: everything the row knows because of the page it USED to watch, cleared in one place.
    //
    // This used to be a hand-written list of assignments inside editURL, and the model grew past it. What
    // survived was not harmless: the sheet went on saying "147 of 147 listings named no venue" and NAMING
    // two of those shows about an address the source no longer fetches, the row claimed it had been checked
    // an hour ago when that was true of the previous page, and the stored run note was a paragraph
    // describing HTML from the old host. A corrected URL is a brand-new source for reconcile (#1027), so a
    // fact that came from reading the old page has no standing on the new one.
    //
    // What is NOT here is as deliberate as what is. Dan's own answers (`venueName`, `venueLocation`, the
    // client tag, the same-date merge rule) are assertions about the ORG, not observations of a page, and
    // silently discarding an answer he typed is its own defect (L5). Consent (`isActive`,
    // `inactiveReasonRaw`) is never a health signal (#800). The id stays because it is stamped on every
    // prospect the old page ever produced.
    //
    // AddressCorrectionTests guards the CLASS rather than today's fields: a stored property added to
    // WatchedSource must be cleared here or named there as surviving, so the next one cannot be forgotten.
    static func clearStateDerivedFromTheWatchedPage(_ source: WatchedSource) {
        // Feed history + warmup: the new page must re-earn the right to mark anything gone.
        source.baselineFeedCount = 0
        source.successfulCheckCount = 0
        source.degradedStreak = 0
        source.lastDegradedCount = 0
        // #2211: and the OTHER streak, for the same reason. "Came back empty five runs in a row" is a
        // claim about the page that was being watched, and the new address has not been read once. Left
        // standing it would put that sentence, and the attention badge behind it, on a source nobody has
        // given a chance yet, which is precisely the correction being punished for the fault it fixed.
        source.emptyStreak = 0

        // What the last run managed to read, and what it dropped. All of it was about the old page, and
        // `readabilityNote` is built from these, so a survivor here becomes a sentence Dan reads.
        source.lastReadableCount = 0
        source.lastUnreadableCount = 0
        source.lastUnreadableTitleCount = 0
        source.lastStructuralGapCount = 0
        source.lastDroppedShowLabelsRaw = ""
        source.lastPlacedCount = 0
        source.hadPlacedBeforeLastRun = false

        // When it was looked at. #1758 made the row's largest slot say CHECKED only when something was
        // actually read, because beside an org name it reads as "we have current information about this
        // org". After a correction that claim belongs to the previous address.
        source.lastCheckedAt = nil
        source.lastSucceededAt = nil
        source.lastManualReadAt = nil
        source.pageCount = 0
        source.health = .neverChecked          // it has not been checked at this address yet

        // Bytes, and what was concluded from them. Every hash here anchors to the old page, and a
        // confirmation of an empty page is void the moment the page is a different one.
        source.lastContentHash = nil
        source.pendingContentHash = nil
        source.pendingPageMonthsRaw = ""
        source.lastObservedContentHash = nil
        source.confirmedEmptyHash = nil
        source.lastFetchWasInsecure = false     // earned by a host this source no longer touches

        // The scout's own account of a specific page, and the failure it ended in.
        source.notes = nil
        source.lastErrorRaw = nil

        // #1529: recorded the first time a ticket-link hop landed on a single-venue feed. It is a machine
        // observation about the OLD page (unlike `venueName` beside it, which is Dan's answer and stays),
        // and it is what makes the Sources sheet ask for the room on this row, so carrying it onto an
        // unrelated address asks the question about a page that never prompted it.
        source.ticketingFeedURL = nil
    }

    // #1175: Dan supplies the real location for a single-venue feed source whose synthesized document
    // carries no city. Unlike editURL this does NOT reset feed history: the SET of shows is unchanged,
    // only their place annotation, so the source keeps the baseline it earned. It IS marked for a fresh
    // read so the correction reaches the store on the next scout instead of waiting for the calendar to
    // change on its own. An empty string clears the location back to nil.
    //
    // #1751: and it places THIS source's blank rows straight away, returning how many, rather than only
    // marking the source for a fresh read. Applying the answer at ingest alone meant a correct save
    // changed nothing about the shows already sitting in Dan's queue until that calendar next happened to
    // change, and a control that visibly does nothing after a correct save reads as a failed save.
    // Scoped to this source, so saving one address never quietly re-derives the whole store.
    @discardableResult
    static func setVenueLocation(_ source: WatchedSource, to newLocation: String,
                                 in context: ModelContext) -> Int {
        let trimmed = newLocation.trimmingCharacters(in: .whitespacesAndNewlines)
        source.venueLocation = trimmed.isEmpty ? nil : trimmed
        markForFreshRead(source)
        // Nothing to place when the answer was withdrawn. The fill is additive, so it could not un-place
        // rows an earlier save already wrote in any case, and saying "placed 0 shows" about a clear would
        // be reporting an action nobody asked for.
        let placed = trimmed.isEmpty ? 0 : LocationBackfill.run(in: context,
                                                                onlySourceId: source.sourceId)
        try? context.save()
        return placed
    }

    // #1529: Dan names the ROOM every show from this source plays in. Needed where the shows come from a
    // ticketing feed that publishes no venue anywhere and the app reached it by following the org's ticket
    // link, so nothing on the page entitles it to assume the org's own name (the Bargemusic rule). Like
    // setVenueLocation this does NOT reset feed history: the set of shows is unchanged, only what Overture
    // may say about where they are. An empty string clears it back to nil, and those shows leave the queue
    // again on the next read, which is the honest consequence of withdrawing the answer.
    static func setVenueName(_ source: WatchedSource, to newName: String, in context: ModelContext) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        source.venueName = trimmed.isEmpty ? nil : trimmed
        markForFreshRead(source)
        try? context.save()
    }

    // Makes the next scout READ this source again instead of skipping it as unchanged.
    //
    // `hasUnreadChanges` alone does not do that, and believing it did was the flaw in #1175's own comment:
    // the read decision compares the fetched page's hash against `lastContentHash` (SourceSchedule.decide),
    // so an answer Dan supplies about a calendar that has not itself changed would sit unused until the
    // venue happened to publish something new. Clearing the ingested hash is what that code already calls
    // "changed by definition", and it costs exactly one re-read.
    private static func markForFreshRead(_ source: WatchedSource) {
        source.lastContentHash = nil
        source.hasUnreadChanges = true
    }

    // #1027: Dan confirms a no_dated_content page is the right calendar, just quiet right now.
    //
    // Anchors the confirmation to the exact bytes just read (pendingContentHash), and stamps that hash as
    // the last ingested one so the free daily run sees no change and never re-reads it. If there is no
    // hash to anchor to (nothing has been read), the failing display is still cleared, but the page will
    // nag again if it fails again: there is nothing to suppress against.
    enum ConfirmResult: Equatable, Sendable {
        case confirmed
        case noHash
    }

    @discardableResult
    static func confirmEmpty(_ source: WatchedSource, in context: ModelContext) -> ConfirmResult {
        source.health = .ok
        source.lastFailure = nil
        guard let hash = source.pendingContentHash ?? source.lastContentHash else {
            try? context.save()
            return .noHash
        }
        source.confirmedEmptyHash = hash
        source.lastContentHash = hash
        source.pendingContentHash = nil
        source.hasUnreadChanges = false
        try? context.save()
        return .confirmed
    }

    // #2377: one shared answer to "is this the same calendar", not a third spelling of it. The rule is
    // still host-based for an organisation publishing its own site, and tenant-aware on a multi tenant
    // ticketing host where the path is the only thing that scopes the feed to a venue.
    private static func sameCalendar(_ urlString: String?, as other: String) -> Bool {
        CalendarIdentity.same(urlString, other)
    }

    // #2233: are these two addresses the same site? Deliberately the HOST rather than
    // `CalendarIdentity.same`, which asks a narrower question (is this the same calendar) and would
    // answer no for two pages on one venue's own site, which is the ordinary correction this must not
    // disturb.
    //
    // `www.` is folded, because a correction that only adds or drops it is not a different building. An
    // unreadable previous address answers NO, so a row whose old URL cannot be parsed has its venue
    // answers cleared and is asked again, which is the safe direction: the alternative is asserting a
    // room nobody can now check the provenance of.
    static func sameHost(_ previous: String?, as next: String) -> Bool {
        guard let previous, let previousHost = host(of: previous), let nextHost = host(of: next) else {
            return false
        }
        return previousHost == nextHost
    }

    private static func host(of urlString: String) -> String? {
        guard let host = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines))?.host,
              !host.isEmpty else { return nil }
        let lowered = host.lowercased()
        return lowered.hasPrefix("www.") ? String(lowered.dropFirst(4)) : lowered
    }
}

// #885 (guard sweep): the add-a-source button's two states.
extension WatchlistEditing {
    static func addButtonTitle(isOpen: Bool) -> String { isOpen ? "Cancel" : "Watch a calendar" }

    // #970. Deliberately "read", not "check": the app already draws that line (#803). The free daily run
    // CHECKS every source (fetch, hash, notice a change) and spends nothing. Reading is what costs, and
    // it is what produces prospects. This button is the expensive half, for one source.
    static let readOneTitle = "Read this one now"

    static let readOneHelp = "Read this source's listings now, without scouting the rest of the list"
}
