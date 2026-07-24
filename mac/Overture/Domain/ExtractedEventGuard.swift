import Foundation

// #799: what an extracted event must carry before it is allowed to become a prospect.
//
// This exists because of what the first real run of the extract path found. Bargemusic's listings page
// names no venue at all: every concert carries a NUMERIC venue id. The run returned the right answer
// ("Brooklyn Bridge Park Boathouse at Pier 5") only because it followed each event's own detail page,
// exactly as the runbook asks. But a runbook is a request, not a guarantee. If a future run skips that
// step, or a site's detail links break, the events still come back looking perfectly well-formed, with
// a venue of "3" or of nothing at all.
//
// That is not cosmetic. The venue drives the classifier AND the pitch itself: Dan's email says "your
// March 10 concert at Carnegie Hall". A prospect with no venue, or with a venue of "3", produces an
// email that names the wrong place, and NOTHING downstream can catch it, because nothing downstream
// knows what the venue was supposed to be. (It is also half the natural key, so a venue-less event
// keys badly and re-keys unpredictably.)
//
// So a venue-less event never becomes a prospect silently. It is rejected WITH A REASON, and the
// reasons are reportable against the source that produced them, which is the actionable fact: "this
// source returned 6 shows and not one of them has a venue" says its detail pages are not being read.
// Six quietly venue-less prospects would just poison the queue.
//
// WHICH PATHS FOLLOW THIS RULE (#987): both, and that is now a decision rather than an accident.
//
//   - The agent path applies it at its BOUNDARY, by construction: `ScoutExtractResults.events(for:)`
//     filters on `isUsable`, so an ingest cannot forget to ask.
//   - The native path (Carnegie's structured feed) applies it in `ScoutService.runNative`, which filters
//     `extractor.extract().events` before `applySweep`.
//
// Until #987 the native path did not apply it at all: it handed the raw feed straight to `applySweep`
// and never touched `ScoutExtractResults`, so the same show got a different verdict depending on which
// door it came through.
//
// LIVE-STORE-CLAIM verified=2026-07-18 measure="sources that had never scouted successfully, and live rows with a missing/placeholder/numeric-id venue, on the day #987 shipped"
// That was invisible because 37 of 38 sources had never successfully scouted and Carnegie always names
// a hall (0 of 132 live rows had a missing, placeholder, or numeric-id venue), so guarding it changed
// nothing on the day it was done (2026-07-16). This is a historical snapshot, not an ongoing guarantee:
// as of 2026-07-18 the store holds 313 rows and 30 of 38 sources have since scouted successfully, still
// with 0 rows missing a venue, so the guard's insurance argument keeps holding even as those counts
// move. It is what lets #979's
// place-aware venue rule (Dan's ruling: a venue-less NYC show is worth chasing, a venue-less Harrogate
// one is not) be written ONCE rather than forked across two paths that already disagreed.
//
// The argument for guarding a structured feed is the same one as for a model's answer, because it is
// about the PROSPECT and not about who typed it: an event with no venue puts the wrong place in Dan's
// email, and nothing downstream can catch it. A feed that stops naming a facility produces exactly that.
//
// A CONSTRAINT on anything that drops an event, and it is not optional: a dropped event is absent from
// the feed the reconcile reads, which is indistinguishable from a show that was CANCELLED (#897/#917).
// Every caller of this guard must hand its reject count to `FeedCheck.rejectedCount`, so #887's
// tolerance gate can forbid that run from concluding anything is gone. Guarding a path without that
// line ships the bug the guard was meant to prevent.
enum ExtractedEventGuard {
    enum Rejection: String, Equatable, Sendable {
        case noTitle
        case noVenue            // absent or blank
        case placeholderVenue   // present, but not a venue: a numeric id, "unknown", "TBD"
        case locationAsVenue    // present, but only restates the location: a city is not a room

        // #1032: whether this rejection is about a VENUE (the detail page was never read, so the show
        // came back with no usable place) or a TITLE (the row had no name at all, which no detail page
        // would fix). The Sources note's "no venue on their own detail page" sentence is true only of the
        // venue family, so the two are counted apart rather than lumped into one number the note then
        // mislabels. An exhaustive switch, so a new rejection reason cannot be added without deciding
        // which family it belongs to.
        var isAboutVenue: Bool {
            switch self {
            case .noTitle:                                            return false
            case .noVenue, .placeholderVenue, .locationAsVenue:       return true
            }
        }
    }

    // Things a model says when it could not find the venue. Accepting any of them as a venue would put
    // it in an email.
    private static let nonAnswers: Set<String> = [
        "unknown", "n/a", "na", "null", "nil", "none", "tbd", "tba", "tbc", "-", "--", "?"
    ]

    // #1214: promote a specific NAMED outdoor space from `location` into an empty `venue`. The model
    // sometimes nulls the venue for an outdoor concert and leaves the place only in `location` (the 3a
    // runbook rule says a named outdoor space IS the venue, but a prompt is a request, not a guarantee).
    // When the venue is blank AND the location names an outdoor place (park/plaza/pier/...), that
    // location IS the venue, so carry it across rather than dropping a real, pitchable show. A bare city
    // never carries an outdoor marker word, so this can never promote "Baltimore, Maryland" into the
    // venue: the #995 city-in-the-venue bug stays fixed. Idempotent, and the single point of promotion,
    // so every consumer of `rejection` (the Sources counts, the #887 cancellation gate, `isUsable`) and
    // the events that flow on to become prospects all agree on the placed venue.
    static func placed(_ event: ExtractedEvent) -> ExtractedEvent {
        let venue = (event.venue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard venue.isEmpty else { return event }
        let location = (event.location ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !location.isEmpty, namesAnOutdoorPlace(location) else { return event }
        var promoted = event
        promoted.venue = location
        return promoted
    }

    // #1278: registration/signup-form hosts that must never stand in for a show's listing link. DCINY's
    // /opportunities/ recruiting rows link to a getfeedback.com "apply to sing" form; `sourceUrl` is the
    // link Dan clicks to look a concert up, so a form sends him to join the choir, not to the show he is
    // deciding whether to photograph. Runbook rule 3c already forbids recording one, but a prompt is a
    // request, not a guarantee, so the boundary drains a form link to nil (keep the real, pitchable show,
    // drop only the bad link). This is "fail loud, not silent" from the link's side of the guard.
    private static let registrationFormHosts: Set<String> = [
        "getfeedback.com", "forms.gle", "forms.google.com", "forms.office.com", "forms.microsoft.com",
        "surveymonkey.com", "typeform.com", "jotform.com", "wufoo.com", "cognitoforms.com", "formstack.com"
    ]

    // A signup-form listing link, replaced with something Dan can open. Idempotent, and the single point of
    // stripping, so `events(for:)` and any other consumer agree on which links are dropped.
    //
    // #1291: when a stripped form is the row's only link, fall back to the LISTINGS PAGE the row was read
    // from (runbook rule 3c), not nil, so the kept show still has a link Dan can click to look it up. The
    // "concert page if the row names one" half of 3c is the run's own job (the concert URL is not separately
    // available at this seam); this recovers the other half. The fallback must itself be a real, non-form
    // URL, or a form is only ever replaced by another dead end.
    static func sanitizedSourceURL(_ event: ExtractedEvent, listingsURL: String? = nil) -> ExtractedEvent {
        guard let raw = event.sourceUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              isRegistrationForm(raw)
        else { return event }
        var cleaned = event
        if let fallback = listingsURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           !fallback.isEmpty, !isRegistrationForm(fallback) {
            cleaned.sourceUrl = fallback
        } else {
            cleaned.sourceUrl = nil
        }
        return cleaned
    }

    private static func isRegistrationForm(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString), let host = url.host?.lowercased() else { return false }
        // Match the host itself or any subdomain of it ("dciny.getfeedback.com" -> "getfeedback.com").
        if registrationFormHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return true }
        // Google Docs is a form only on its /forms path; a plain docs.google.com link is never a concert
        // listing either, but scope the match to the form path to stay narrow and predictable.
        if host == "docs.google.com" || host.hasSuffix(".docs.google.com") {
            return url.path.lowercased().hasPrefix("/forms")
        }
        return false
    }

    static func rejection(for rawEvent: ExtractedEvent) -> Rejection? {
        // #1214: judge the PLACED event, so a rescued outdoor show is not counted as venueless anywhere.
        let event = placed(rawEvent)
        // #1087: drop for a missing NAME, not for a missing title STRING. A genuine performance can come
        // back with an empty `title` but a real `presenter` (the act itself) and venue: a touring artist
        // page lists dates under one performer and names no per-show title at all. That show has a
        // perfectly good name (its presenter, then its venue), and dropping it is the same silent loss
        // the venue guard exists to prevent, from the other side. So `.noTitle` fires only when there is
        // genuinely nothing to name it with. See `displayName` for the precedence.
        guard displayName(for: event) != nil else { return .noTitle }

        let venue = (event.venue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !venue.isEmpty else { return .noVenue }

        // The Bargemusic shape: the listings page's venue field is a numeric id ("3"), which is not a
        // venue and reads as one.
        if venue.allSatisfy({ $0.isNumber }) { return .placeholderVenue }
        if nonAnswers.contains(venue.lowercased()) { return .placeholderVenue }
        if restatesLocation(venue: venue, location: event.location) { return .locationAsVenue }
        return nil
    }

    // #1087: the name this show will carry, and the SINGLE authority on it, so the guard's `.noTitle`
    // decision and the name ProspectAssembler stamps into `groupName` can never disagree. Precedence is
    // title, then presenter, then venue: the show's own title if it has one, else the act (the "who",
    // which is what the pitch is about and what Dan reads first), else the room (the "where"), each
    // trimmed. `groupName` is half the natural key (Prospect.makeNaturalKey pairs it with the date and
    // venue), so a derived name keys the same way a real title would. Returns nil only when title,
    // presenter, and venue are all empty or blank, which is exactly the row `.noTitle` now rejects: a
    // show with no name and no way to derive one.
    //
    // A caveat this deliberately accepts: if a later scout returns the SAME show WITH a title, its
    // groupName shifts from the presenter to the title and its natural key moves, the same re-key a title
    // edit already causes. ScoutService's existing re-key guards (source listing + date, shared member
    // URL) absorb that; this does not introduce a new class of drift, it reuses the one already handled.
    static func displayName(for event: ExtractedEvent) -> String? {
        for candidate in [event.title, event.presenter ?? "", event.venue ?? ""] {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    // #995: a venue that only says what the location already said is not a venue, it is the location
    // wearing a venue's clothes. This is the one shape of "no venue published" the guard can actually
    // SEE, because it never gets to look at the page.
    //
    // The comparison is deliberately narrow: equality, or the venue matching one whole comma-separated
    // piece of the location ("Baltimore" against "Baltimore, Maryland"). It is NOT a substring test in
    // the other direction, and that asymmetry is the whole point. A real venue routinely contains its
    // own city ("Brooklyn Bridge Park Boathouse at Pier 5, Brooklyn, NY" against "Brooklyn, NY"), so a
    // loose "one contains the other" rule would reject the exact answer the runbook holds up as correct.
    //
    // LIVE-STORE-CLAIM verified=2026-07-18 measure="restatesLocation firing against a one-time snapshot of fabricated-plus-real live-store rows, at the time this guard was written"
    // Measured against the live store before it was written (2026-07-16): fires on 4 of 4 fabricated
    // rows, and cannot fire on the other 128, which carry no location at all. That 4/128/132 split is a
    // one-time development snapshot, not a rerunnable assertion (the 4 fabricated rows do not persist in
    // the store), so it is not expected to still add up against today's larger store. A tempting
    // alternative ("the venue has a comma") was rejected on the same data: it would eat Bargemusic's real
    // answer.
    //
    // #1057: a SPECIFIC, NAMED outdoor performance space (a park, plaza, pier) is a real venue, and the
    // 3a runbook rule to copy `location` verbatim means it routinely repeats that same name ("Sakura
    // Park, W 122nd St & Riverside Dr" as both `venue` and `location`), which would otherwise trip this
    // exact check. `namesAnOutdoorPlace` is the escape hatch: a bare city/state/country name never
    // carries a place-type word, so it can't falsely rescue the #995 fabricated rows this guard exists
    // to catch.
    private static func restatesLocation(venue: String, location: String?) -> Bool {
        let venueKey = normalized(venue)
        guard !venueKey.isEmpty,
              let location, case let locationKey = normalized(location), !locationKey.isEmpty
        else { return false }
        guard !namesAnOutdoorPlace(venue) else { return false }

        if venueKey == locationKey { return true }
        return locationKey.split(separator: ",")
            .map { normalized(String($0)) }
            .contains(venueKey)
    }

    // A bare city/state/country name never carries one of these; a specific named outdoor performance
    // space routinely does ("Sakura Park", "Greeley Square", "Bryant Park", "Pier 5").
    private static let outdoorPlaceMarkers: Set<String> = [
        "park", "plaza", "square", "pier", "green", "common", "commons", "garden", "gardens",
        "esplanade", "promenade", "amphitheater", "amphitheatre", "bandshell", "waterfront",
        "boardwalk", "courtyard", "terrace"
    ]

    private static func namesAnOutdoorPlace(_ venue: String) -> Bool {
        let words = venue.lowercased().split(whereSeparator: { !$0.isLetter })
        return words.contains { outdoorPlaceMarkers.contains(String($0)) }
    }

    private static func normalized(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func isUsable(_ event: ExtractedEvent) -> Bool { rejection(for: event) == nil }

    // #1032: a run's rejected events, split by family (venue vs title), so the Sources note can name a
    // titleless drop correctly instead of calling it "no venue". Usable events contribute nothing. Both
    // ingest doors (the agent extract run and the native Carnegie sweep) count through this one function,
    // so they can never disagree on which drops were about a venue.
    //
    // #1472: and split again, by whether the missing venue is a READING FAILURE or the SOURCE'S OWN blank
    // field. `venueGapsAreStructural` is the caller's path saying which it is (SourceKind.venueGapsAreStructural
    // is the one place that is decided): a native feed parses structured rows and never hops to a per-event
    // detail page, so a blank venue there is data entry, not a page Overture could not open. Defaulted to
    // false, the suspicious reading, so a caller that does not know cannot accidentally excuse a broken
    // scraper.
    //
    // A structural gap is exempted ONLY when the row carries its own listing link, and that condition is
    // load-bearing rather than defensive. The exemption's whole safety argument is that the row can be handed
    // to the reconcile as still listed (`structuralGapURLs` -> FeedCheck -> SourceReport.seenSourceURLs), so a
    // stored show whose row went blank between runs cannot be struck for it. A row with no link cannot be
    // handed over, so it keeps counting against readability. That is every VenueTix and OvationTix row.
    static func rejectionCounts(for events: [ExtractedEvent],
                                venueGapsAreStructural: Bool = false) -> RejectionCounts {
        var venue = 0, title = 0, structural = 0
        var structuralURLs = Set<String>()
        var structuralDates = Set<String>()
        var dropped: [DroppedShow] = []
        for event in events {
            guard let reason = rejection(for: event) else { continue }
            // #1471: who each dropped row WAS, so the Sources sheet can name it instead of reporting a bare
            // count Dan then has to go and decode out of the raw results file. Named by the same rule the
            // show would have carried into the queue (`displayName`: its title, else the act, else the room),
            // so the sheet calls it what a prospect would have been called. Every family, because Dan's next
            // move is the same either way: open the source's page and look at that row.
            dropped.append(DroppedShow(name: displayName(for: placed(event)), date: event.performanceDate))
            guard reason.isAboutVenue else { title += 1; continue }
            // #1469: the OTHER way this can be the source's own gap rather than a failed read. On the native
            // path the whole path answers it (there is no detail page to fail); on the agent path only the run
            // can, because it is the one thing that saw the page, so it says so per row.
            let publisherGap = venueGapsAreStructural || event.venueNotPublished == true
            let link = (event.sourceUrl ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let date = (event.performanceDate ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard publisherGap, !link.isEmpty || !date.isEmpty else { venue += 1; continue }
            structural += 1
            // #1469: the link where there is one, and ONLY otherwise the date. A listing URL identifies one
            // show; a date identifies every show that source has that night. Recording both would shelter a
            // genuinely cancelled sibling that happens to share the night with a blank row, for nothing: the
            // link already holds the show the blank row is about. So the weaker key is used only where it is
            // the sole identity the row has, which is Smoke Ring's placeholder ("Info coming soon", no title,
            // no venue, no link, but a night).
            if !link.isEmpty {
                structuralURLs.insert(link)
            } else {
                structuralDates.insert(date)
            }
        }
        return RejectionCounts(venueRelated: venue, titleRelated: title,
                               structuralGapCount: structural, structuralGapURLs: structuralURLs,
                               structuralGapDates: structuralDates, droppedShows: dropped)
    }
}

// #1032: a run's dropped shows, split into the family the Sources note's "no venue on their own detail
// page" sentence is about (the three venue reasons) and the one it is not (a titleless row).
//
// #1472: and split once more, because "we could not read this show's page" and "the source published no
// venue for this show" are opposite facts that were being added together. `unreadTotal` is what the #887
// cancellation-tolerance gate measures: the drops that suggest this run does not know what else it missed.
// `structuralGapCount` is the rest, disclosed on the row but costing the source nothing, with
// `structuralGapURLs` carrying those rows into the reconcile as still listed so no stored show can be
// struck for a row that was present all along.
//
// It was ONE number (`total`) and that name is deliberately gone rather than redefined: every call site had
// to be re-read and told which of the two questions it was asking.
struct RejectionCounts: Equatable, Sendable {
    var venueRelated: Int
    var titleRelated: Int
    var structuralGapCount: Int = 0
    var structuralGapURLs: Set<String> = []
    // #1469: the nights those rows fall on, for the ones that carry no link of their own. A placeholder row
    // ("Info coming soon") routinely has no title, no venue and no link, and its date is the only identity
    // left to hold a stored show by. Scoped to the source that published it when the reconcile reads it: a
    // date is nothing like as specific as a URL, and unioned across sources one venue's placeholder would
    // shelter every other venue's show that night.
    var structuralGapDates: Set<String> = []
    // #1471: who the dropped rows were, in the order the source listed them, so the Sources sheet can name
    // the first couple. Deliberately NOT a rendered sentence: how a show is written for Dan is decided once,
    // in SourceReadability, and a guard that started producing copy would be the second place it lives.
    var droppedShows: [DroppedShow] = []
    // The #887 count. A dropped event is absent from the feed the reconcile reads, so a run that could not
    // read part of what it looked at may still add and update but may not conclude anything is gone.
    var unreadTotal: Int { venueRelated + titleRelated }
    // Everything this run threw away, for a caller that wants to report the whole picture.
    var droppedTotal: Int { unreadTotal + structuralGapCount }
}

// #1471: one dropped row, as much of its identity as the source published. Both may be absent (a row with
// no name and no date), which is why the label is optional at the other end rather than rendered as a bare
// "on" or an empty quote.
struct DroppedShow: Equatable, Sendable {
    var name: String?
    var date: String?
}

// One rejected event, kept so it can be reported against its source rather than vanishing.
struct RejectedEvent: Equatable, Sendable {
    var title: String
    var reason: ExtractedEventGuard.Rejection
}
