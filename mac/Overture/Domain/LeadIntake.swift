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

    static func outcome(from results: ScoutExtractResults, sourceId: String) -> Outcome {
        guard let verdict = results.verdict(for: sourceId) else { return .nothingCameBack }

        let usable = results.events(for: sourceId)
        let rejected = results.rejectedEvents(for: sourceId)
        let note = results.results.first { $0.sourceId == sourceId }?.note

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

    static func knownUnreadableHost(_ url: URL) -> String? {
        guard var host = url.host?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return unreadableHosts.first { host == $0 || host.hasSuffix(".\($0)") }
    }
}
