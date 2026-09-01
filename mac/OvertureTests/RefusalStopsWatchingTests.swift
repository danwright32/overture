import Testing
import Foundation
import SwiftData

// #769 + #802: an org that asks Dan to stop must also come OFF the watchlist.
//
// Until now the refusal only stopped the emails, which was enough when nothing re-checked an org on its
// own. The moment a standing watchlist exists, it stops being enough: their calendar would be fetched
// and read every single run, forever, and their shows would keep arriving in Dan's queue to be looked
// at. Nothing would send, but he would be reading about people who asked him to go away, which is not
// what "we'll leave you alone" means.
//
// The hard part is WHICH source comes off, and getting it backwards would be its own bad failure.
@Suite("A refusal takes the org off the watchlist too (#769, #802)")
struct RefusalStopsWatchingTests {
    private func prospect(_ groupName: String, sourceIds: [String] = []) -> Prospect {
        let p = Prospect(naturalKey: groupName, groupName: groupName, discipline: "music",
                         venue: "Zankel Hall", performanceDate: "2099-09-19",
                         sourceListingURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 5, tier: "mid", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil)
        p.sourceIds = sourceIds
        return p
    }

    private func source(_ id: String, orgName: String) -> WatchedSource {
        WatchedSource(sourceId: id, orgName: orgName,
                      listingsURL: "https://\(id).example/events", kind: .html)
    }

    // THE test, and the one that would be easy to get backwards.
    //
    // A Brooklyn choir performing at Symphony Space asks Dan to stop. Symphony Space's calendar is what
    // surfaced them. Deactivating the source that SURFACED them would blind Dan to Symphony Space's
    // entire calendar because one act on it refused him: that is his own "watch a venue, but pitch the
    // presenter" rule, applied to refusals. So the match is on the source's OWN NAME, never on which
    // source produced the prospect.
    @Test func theVenueThatSurfacedThemKeepsBeingWatched() {
        let choir = prospect("Brooklyn Youth Chorus", sourceIds: ["symphony-space"])
        let venue = source("symphony-space", orgName: "Symphony Space")

        OrgDoNotContact.mark(orgOf: choir, in: [choir], sources: [venue])

        #expect(venue.isActive, "a venue must not be dropped because one act on its calendar refused")
        #expect(venue.inactiveReason == nil)
        #expect(choir.orgDoNotContact)   // the refusal itself still lands
    }

    // And their OWN calendar does come off.
    @Test func theirOwnCalendarComesOffTheWatchlist() {
        let choir = prospect("Brooklyn Youth Chorus", sourceIds: ["symphony-space"])
        let theirs = source("brooklyn-youth-chorus", orgName: "Brooklyn Youth Chorus")

        OrgDoNotContact.mark(orgOf: choir, in: [choir], sources: [theirs])

        #expect(theirs.isActive == false)
        #expect(theirs.inactiveReason == .orgRefusal)
        // NOT "failing". There is nothing wrong with them; they simply asked to be left alone, and the
        // Sources sheet must never present that as a broken scraper.
        #expect(theirs.health != .failing)
    }

    // The bar is the same confident name match the suppression itself uses. A merely similar name is
    // never authoritative enough to act on, in either direction.
    @Test func aMerelySimilarNameIsNotEnoughToDropACalendar() {
        let choir = prospect("Brooklyn Youth Chorus")
        let other = source("manhattan-girls-chorus", orgName: "Manhattan Girls Chorus")

        OrgDoNotContact.mark(orgOf: choir, in: [choir], sources: [other])

        #expect(other.isActive)
    }

    // MARK: - Releasing a refusal

    // A mis-click must not be permanent: releasing the refusal puts their calendar back.
    @Test func releasingTheRefusalResumesWatchingTheirCalendar() {
        let choir = prospect("Brooklyn Youth Chorus")
        let theirs = source("brooklyn-youth-chorus", orgName: "Brooklyn Youth Chorus")

        OrgDoNotContact.mark(orgOf: choir, in: [choir], sources: [theirs])
        OrgDoNotContact.unmark(orgOf: choir, in: [choir], sources: [theirs])

        #expect(theirs.isActive)
        #expect(theirs.inactiveReason == nil)
    }

    // But a source Dan deliberately removed as DEAD is not resurrected by releasing a refusal. Those are
    // different decisions and only one of them is being reversed.
    @Test func releasingARefusalNeverResurrectsASourceDanRemovedHimself() {
        let choir = prospect("Brooklyn Youth Chorus")
        let dead = source("brooklyn-youth-chorus", orgName: "Brooklyn Youth Chorus")
        dead.isActive = false
        dead.inactiveReason = .removedByDan

        OrgDoNotContact.unmark(orgOf: choir, in: [choir], sources: [dead])

        #expect(dead.isActive == false)
        #expect(dead.inactiveReason == .removedByDan)
    }
}
