import Foundation

// #799 slice 4a: what happens between Dan pasting a link and Dan seeing something to confirm.
//
// The whole reason the intake goes through a CONFIRM step is that a bad parse gets caught by Dan on a
// sheet instead of being written into the live store overnight by an unattended run. So the states
// this can end in ARE the feature, and each has to be honest about what actually happened. An empty
// list is not an answer: it means four different things, and Dan needs to know WHICH.
enum LeadIntake {
    enum Outcome: Equatable {
        // The page read cleanly and here is what is on it. He confirms, edits, or drops.
        case found([ExtractedEvent], note: String?)

        // The page HAS shows and none of them are usable, because none carry a real venue. This is not
        // an empty page: it is a page whose detail pages are not being read (Bargemusic's listings
        // carry numeric venue ids). Saying "no shows" here would hide a real, fixable problem.
        case foundButUnusable([RejectedEvent], note: String?)

        // NOT an error. An org between seasons is a HEALTHY source with nothing on, and the #770 spike
        // found this is the NORMAL state: 5 of its 7 real sites, in July. Calling it a failure would
        // train Dan to distrust a system that is working perfectly.
        case noUpcomingShows(String)

        // The page carries no dated listings at all, so it is probably not the events page. Guessing a
        // URL by convention landed the spike on a 2021 archived concert that answered HTTP 200 and
        // looked entirely healthy.
        case notAnEventsPage(String)

        // We could not read it: a calendar drawn by JavaScript, or a login wall. An INSTAGRAM link is
        // exactly this (a raw fetch returns ~600KB of login page with no caption and no event data),
        // and Dan said he would sometimes paste one. So this says what to paste INSTEAD; it never sits
        // there looking broken and never pretends to have read the page.
        case unreadable(String)

        // The run came back with nothing for the id we queued. Usually means it rebuilt the id instead
        // of echoing it, which is the silent-mismatch the opaque-id rule exists to prevent.
        case nothingCameBack
    }

    // `onlyForOrg` is set when we had to follow a link OFF the org's own site (its page was unreadable)
    // onto somebody else's, and it is the fix for the worst bug this feature has produced.
    //
    // Dan pasted his ensemble's show page. We followed its ticket link to Lincoln Center, whose page
    // carries an "Alice Tully Hall upcoming events" sidebar, and came back with FOUR SHOWS, all real,
    // all at the right hall, and not one of them his ensemble: they belong to the Chamber Music Society
    // and to Lincoln Center Presents. His ensemble's own concert had already happened, so the honest
    // answer was "nothing upcoming for them".
    //
    // A venue page is a page about MANY organizations. The moment we wander onto one, only the org we
    // came for is the lead. (When Dan pastes a venue's calendar DELIBERATELY, there is no constraint and
    // every show counts: he is watching the hall, not one act.)
    static func outcome(from results: ScoutExtractResults, sourceId: String,
                        onlyForOrg: String? = nil) -> Outcome {
        guard let verdict = results.verdict(for: sourceId) else { return .nothingCameBack }

        let all = results.events(for: sourceId)
        let usable = onlyForOrg.map { org in all.filter { belongsTo(org, $0) } } ?? all
        let rejected = results.rejectedEvents(for: sourceId)
        let note = results.results.first { $0.sourceId == sourceId }?.note

        // The page HAD shows, and none of them are the org's. That is not "an empty page" and it is not
        // a failure: it usually means their concert has passed and the hall has moved on. Say exactly
        // that, naming them, rather than handing Dan the hall's other tenants.
        if usable.isEmpty, !all.isEmpty, let org = onlyForOrg {
            return .noUpcomingShows(
                "Nothing upcoming for \(org) on that page. The other shows there belong to the venue's own programme, not to them, so I've left them out."
                + (note.map { " \($0)" } ?? ""))
        }

        if !usable.isEmpty { return .found(usable, note: note) }
        if !rejected.isEmpty { return .foundButUnusable(rejected, note: note) }

        switch verdict {
        case .upcomingListings:
            // It claimed upcoming listings and returned none that survived. Treat as nothing on, rather
            // than inventing a failure: the honest reading is that the page had nothing for us.
            return .noUpcomingShows(noUpcomingMessage)
        case .allPast:
            return .noUpcomingShows(noUpcomingMessage)
        case .noDatedContent:
            return .notAnEventsPage(
                "That page doesn't list any dated events. It may not be their events page: try the link that shows their season or calendar.")
        case .unreadable:
            return .unreadable(unreadableMessage)
        case .notRead:
            // #856: unreachable from here. A lead's page is read by the app itself, in process, and
            // `notRead` is only ever written by the detached scout-extract runner about a source its run
            // died before opening. Handled rather than crashed, because a lead Dan is trying to add is
            // the worst possible place to trap.
            return .unreadable(unreadableMessage)
        }
    }

    static let noUpcomingMessage =
        "No upcoming shows on that page. That's normal off-season: the organization may not have announced its next season yet."

    // Honest about WHOSE fault it is, and useful about what to do next.
    //
    // The first version said "paste the org's own site instead", which is what Dan HAD pasted: his
    // ensemble's site draws its calendar with JavaScript, so the shows are not in the bytes we fetch.
    // Telling him to try the thing he just tried is worse than useless; it implies he did something
    // wrong. He did not. We are the blind ones, and the message should say so and point somewhere that
    // can actually work: the venue's own page, or the ticket link, which is usually on the very page we
    // could not read. (#806 is the real fix: render the page first, the way a browser does.)
    static let unreadableMessage =
        "I can't read that page: the site builds its calendar with JavaScript, so the shows aren't in what I download. Nothing's wrong with your link. Try the venue's page for the show, or a ticket link (Eventbrite and the like) if there is one."

    // A DIFFERENT cause needs a different message. Instagram and Facebook do not draw their content
    // with JavaScript so much as hide it behind a login: a raw fetch returns ~600KB of sign-in page.
    // Telling Dan his ensemble's site "builds its calendar with JavaScript" when he pasted an Instagram
    // link would be confidently wrong, which is the exact failure this whole session has been about.
    static let loginWalledMessage =
        "I can't read that: it's behind a login, so I only get the sign-in page. Paste the org's own site or the venue's event page instead."

    // Hosts we already know we cannot read, so we say so IMMEDIATELY rather than spending a fetch and a
    // Claude run to rediscover a login wall. Verified, not assumed: a raw fetch of a public Instagram
    // post returns roughly 600KB of login-wall HTML, with no Open Graph tags, no caption, and no event
    // content of any kind.
    private static let unreadableHosts = ["instagram.com", "facebook.com", "x.com", "twitter.com"]

    // Does this show belong to the org we came for? Uses the same confident-name-match bar the scout's
    // own repeat-client matching uses: a merely similar name is never authoritative enough to act on.
    // A venue lists a show either under the act's name in the TITLE ("Second Ending Ensemble: Mahler 1")
    // or as the presenter, so both are checked.
    // The characters a venue puts between the act and the programme. Built from scalars rather than a
    // literal because the repo's style guard forbids a dash character in source strings, and it is
    // right to: every previous one has been prose, not punctuation for a parser.
    private static let titleSeparators: CharacterSet = {
        var set = CharacterSet(charactersIn: ":|")
        set.insert(charactersIn: "-")                       // hyphen
        set.insert(Unicode.Scalar(0x2013)!)                 // en dash
        set.insert(Unicode.Scalar(0x2014)!)                 // em dash
        return set
    }()

    private static func belongsTo(_ org: String, _ event: ExtractedEvent) -> Bool {
        if GroupNameMatch.isConfident(org, event.title) { return true }
        if let presenter = event.presenter, GroupNameMatch.isConfident(org, presenter) { return true }
        // A venue often prefixes the act: "Second Ending Ensemble: Mahler 1 Titan". A confident match on
        // the whole title can fail there, so the title's leading segment gets its own look.
        let lead = event.title.components(separatedBy: titleSeparators).first?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return !lead.isEmpty && GroupNameMatch.isConfident(org, lead)
    }

    static func knownUnreadableHost(_ url: URL) -> String? {
        guard var host = url.host?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return unreadableHosts.first { host == $0 || host.hasSuffix(".\($0)") }
    }
}
