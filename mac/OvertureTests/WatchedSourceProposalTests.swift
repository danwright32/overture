import Testing
import Foundation
import SwiftData

// #768 / #802: what Overture proposes to keep watching after Dan hands it a lead.
//
// The test this suite exists for is `anOrgThatAskedDanToStopIsNeverProposedAgain`. Everything else here
// is convenience; that one is the thing that cannot be taken back. A lead is exactly the route by which
// it would happen: Dan pastes a show he found interesting, having forgotten it is the org that wrote to
// him last spring asking to be left alone, and a helpful watchlist quietly puts them back on the list
// and starts surfacing their shows to pitch again.
@Suite("What Overture proposes to keep watching (#768, #802)")
struct WatchedSourceProposalTests {
    private func source(_ id: String, url: String, active: Bool = true,
                        reason: SourceInactiveReason? = nil) -> WatchedSource {
        let s = WatchedSource(sourceId: id, orgName: id, listingsURL: url, kind: .html)
        s.isActive = active
        s.inactiveReason = reason
        return s
    }

    private func event(_ presenter: String) -> ExtractedEvent {
        ExtractedEvent(title: presenter, presenter: presenter, venue: "Merkin Hall",
                       performanceDate: "2099-09-19", sourceUrl: "https://x.example/1")
    }

    private func verdict(_ pageURL: String = "https://bargemusic.org/events",
                         _ pv: PageVerdict = .upcomingListings,
                         events: [ExtractedEvent] = [],
                         existing: [WatchedSource] = []) -> WatchedSourceProposal.Verdict {
        WatchedSourceProposal.verdict(pageURL: pageURL, verdict: pv, events: events, existing: existing)
    }

    // THE test. An org that asked Dan to stop is never proposed again, by any route.
    @Test func anOrgThatAskedDanToStopIsNeverProposedAgain() {
        let refused = source("refused", url: "https://bargemusic.org/calendar",
                             active: false, reason: .orgRefusal)

        let v = verdict("https://bargemusic.org/events", events: [event("Bargemusic")], existing: [refused])

        #expect(v == .refused(orgName: "refused"))
        // And emphatically not a proposal, by any spelling of the URL.
        if case .propose = v { Issue.record("a refused org must never be proposed for watching") }
    }

    // A source Dan removed because the site was dead is NOT a refusal, and offering it again is fine: he
    // may decide the site is worth another try. That is his call to reverse; an org's refusal is not.
    @Test func aSourceDanRemovedHimselfMayBeProposedAgain() {
        let dead = source("dead", url: "https://bargemusic.org/calendar",
                          active: false, reason: .removedByDan)

        let v = verdict("https://bargemusic.org/events", events: [event("Bargemusic")], existing: [dead])

        #expect(v == .propose(orgName: "Bargemusic", listingsURL: "https://bargemusic.org/events"))
    }

    // MARK: - Not watching the same calendar twice

    // Matched on HOST, because an org publishes /events, /calendar and /concerts and links between them.
    // Three rows for one organization would fetch, hash and READ the same calendar three times a run.
    @Test func aCalendarAlreadyWatchedIsNotProposedUnderAnotherOfItsURLs() {
        let watched = source("barge", url: "https://bargemusic.org/calendar")

        let v = verdict("https://bargemusic.org/events", events: [event("Bargemusic")], existing: [watched])

        #expect(v == .alreadyWatching(orgName: "barge"))
    }

    @Test func wwwIsNotADifferentOrganization() {
        let watched = source("barge", url: "https://www.bargemusic.org/calendar")
        let v = verdict("https://bargemusic.org/events", existing: [watched])
        #expect(v == .alreadyWatching(orgName: "barge"))
    }

    @Test func aDifferentOrgIsStillProposed() {
        let watched = source("barge", url: "https://bargemusic.org/calendar")
        let v = verdict("https://merkin.example/events", events: [event("Merkin")], existing: [watched])
        #expect(v == .propose(orgName: "Merkin", listingsURL: "https://merkin.example/events"))
    }

    // MARK: - What is worth watching at all

    // A page we could not read is not a calendar we can watch. Adding it would mean a source that reports
    // as failing every single run, forever, with nothing Dan can do about it.
    @Test func aPageWeCannotReadIsNotWorthWatching() {
        #expect(verdict("https://x.example/e", .unreadable) == .nothingToWatch)
        #expect(verdict("https://x.example/e", .noDatedContent) == .nothingToWatch)
    }

    // A season that has FINISHED is exactly the calendar that will have an autumn on it. Watching it is
    // the whole point: pitch once and forget is the behavior this feature exists to replace.
    @Test func aFinishedSeasonIsPreciselyWhatIsWorthWatching() {
        let v = verdict("https://bargemusic.org/events", .allPast, events: [event("Bargemusic")])
        #expect(v == .propose(orgName: "Bargemusic", listingsURL: "https://bargemusic.org/events"))
    }

    // #1012: a page the run only read PART of is still a real calendar (we saw genuine content), unlike
    // a page we could not read at all. It is exactly the kind of thing worth watching.
    @Test func aPartiallyReadPageIsStillWorthWatching() {
        let v = verdict("https://bargemusic.org/events", .incompleteExtraction, events: [event("Bargemusic")])
        #expect(v == .propose(orgName: "Bargemusic", listingsURL: "https://bargemusic.org/events"))
    }

    @Test func nonsenseIsNotProposed() {
        #expect(verdict("not a url") == .nothingToWatch)
    }

    // MARK: - The name we suggest

    // The presenter most of the shows name, because a calendar's shows are the best evidence of whose
    // calendar it is. A guess, shown in an editable field, never written silently.
    @Test func theProposedNameIsWhoeverMostOfTheShowsAreBy() {
        let v = verdict(events: [event("Bargemusic"), event("Bargemusic"), event("Guest Ensemble")])
        #expect(v == .propose(orgName: "Bargemusic", listingsURL: "https://bargemusic.org/events"))
    }

    // Stable across runs: a tie must not resolve differently just because a dictionary hashed
    // differently, or the same page would propose a different name every time Dan opened the sheet.
    @Test func aTieResolvesTheSameWayEveryTime() {
        let names = (0..<12).map { _ in
            WatchedSourceProposal.orgName(from: [event("Alpha"), event("Beta")], host: "x.example")
        }
        #expect(Set(names).count == 1)
    }

    // A page whose shows name nobody falls back to the site itself, rather than to an empty name that
    // would render as a blank row in the Sources sheet.
    @Test func aPageWithNoPresentersFallsBackToTheSite() {
        let v = verdict("https://bargemusic.org/events", events: [])
        #expect(v == .propose(orgName: "bargemusic.org", listingsURL: "https://bargemusic.org/events"))
    }
}
