import Testing
import Foundation
@testable import Overture

// #1145 Layer 1: the free, always-on reachability heuristic read at Review, before keep/dismiss. It uses
// only signals already in hand post-scout (presenter, source listing URL, and a website URL if Prep has
// set one), never a new fetch. It flags the known-dead cases so Dan never dismisses a reachable show in
// favour of a doubly-weak long shot. Pure and exhaustively pinned so a green suite can't hide a heuristic
// that never fires ("a rule is only as real as its detection").
@Suite("Reachability heuristic (#1145)")
struct ReachabilityTests {
    // A social-only source (Instagram/Facebook/X) is a verified dead end: a raw fetch returns a login
    // wall, and lead intake already refuses these. So it reads as hard to reach even with a presenter.
    @Test func aSocialOnlySourceIsHardToReach() {
        #expect(Reachability.assess(presenter: "Aurora Strings",
                                    sourceListingURL: "https://www.instagram.com/aurorastrings/",
                                    websiteURL: nil) == .hardToReach)
        #expect(Reachability.assess(presenter: "Aurora Strings",
                                    sourceListingURL: "https://facebook.com/events/123",
                                    websiteURL: nil) == .hardToReach)
    }

    // No presenting org identified, just a venue and a show title: there is no target to email.
    @Test func aShowWithNoPresenterIsHardToReach() {
        #expect(Reachability.assess(presenter: nil,
                                    sourceListingURL: "https://carnegiehall.org/calendar/x",
                                    websiteURL: nil) == .hardToReach)
        #expect(Reachability.assess(presenter: "   ",
                                    sourceListingURL: "https://carnegiehall.org/calendar/x",
                                    websiteURL: nil) == .hardToReach)
    }

    // A confirmed real (non-social) website, which Prep may have set, is positive evidence: likely reachable.
    @Test func aRealWebsiteIsLikelyReachable() {
        #expect(Reachability.assess(presenter: "Aurora Strings",
                                    sourceListingURL: "https://www.instagram.com/aurorastrings/",
                                    websiteURL: "https://aurorastrings.org") == .likelyReachable)
        #expect(Reachability.assess(presenter: nil,
                                    sourceListingURL: nil,
                                    websiteURL: "https://aurorastrings.org/contact") == .likelyReachable)
    }

    // The common Review case: a named presenter reached via a normal listing, but no confirmed website yet.
    // Overture cannot cheaply prove reachability here, so it stays silent rather than over-promising.
    @Test func aNamedPresenterOnANormalListingIsUnclear() {
        #expect(Reachability.assess(presenter: "Aurora Strings",
                                    sourceListingURL: "https://carnegiehall.org/calendar/x",
                                    websiteURL: nil) == .unclear)
    }

    // A website URL that is itself social does not count as positive evidence; it falls through to the
    // social-only dead-end rule.
    @Test func aSocialWebsiteDoesNotCountAsReachable() {
        #expect(Reachability.assess(presenter: "Aurora Strings",
                                    sourceListingURL: "https://www.instagram.com/aurorastrings/",
                                    websiteURL: "https://www.facebook.com/aurorastrings") == .hardToReach)
    }
}
