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

    // A confirmed real (non-social) website, which Prep may have set, is positive evidence, but only
    // ALONGSIDE a presenter on a non-social listing (#1335): here a named presenter on a normal listing.
    @Test func aRealWebsiteWithAPresenterIsLikelyReachable() {
        #expect(Reachability.assess(presenter: "Aurora Strings",
                                    sourceListingURL: "https://carnegiehall.org/calendar/x",
                                    websiteURL: "https://aurorastrings.org") == .likelyReachable)
        #expect(Reachability.assess(presenter: "Aurora Strings",
                                    sourceListingURL: nil,
                                    websiteURL: "https://aurorastrings.org/contact") == .likelyReachable)
    }

    // #1335: a website is positive evidence only alongside a presenter and must never SWALLOW the
    // social-only / no-presenter dead ends. A venue-ish (no presenter) or social listing that happens to
    // carry a real website still warns, rather than being silently marked reachable off the site alone.
    @Test func aWebsiteNeverSwallowsTheDeadEnds() {
        // No presenting org (venue-ish), even with a real website: nothing to email, still hard to reach.
        #expect(Reachability.assess(presenter: nil,
                                    sourceListingURL: nil,
                                    websiteURL: "https://aurorastrings.org/contact") == .hardToReach)
        // Social-only listing, even with a real website: still a verified dead end.
        #expect(Reachability.assess(presenter: "Aurora Strings",
                                    sourceListingURL: "https://www.instagram.com/aurorastrings/",
                                    websiteURL: "https://aurorastrings.org") == .hardToReach)
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

    // #1596 Phase 3 rewrites what used to be three tests here (aProbedShowShowsTheFirmResult,
    // aProbedShowWithOnlyAWeakContactSaysWeakContactOnly, aStaleProbeResultRevertsToAWorthRecheckingBadge).
    // They passed the badge the row's LIVE recipient state and asked it to classify. It now reads the
    // stored conclusion instead, so classification happens once, where the venue and press guards have
    // actually run, rather than on every render where they have not. The cases they covered are asserted
    // against the new signature further down.

    @Test func probeStalenessRespectsTheFreshnessWindow() {
        let probedAt = Date(timeIntervalSince1970: 1_000_000)
        #expect(Reachability.probeIsStale(probedAt: nil, now: probedAt) == false)   // never probed
        #expect(Reachability.probeIsStale(probedAt: probedAt,
                                          now: probedAt.addingTimeInterval(Reachability.probeFreshness - 1)) == false)
        #expect(Reachability.probeIsStale(probedAt: probedAt,
                                          now: probedAt.addingTimeInterval(Reachability.probeFreshness + 1)) == true)
    }

    @Test func anUnprobedShowFallsBackToTheHeuristic() {
        #expect(Reachability.badge(result: nil,
                                   presenter: "Aurora Strings", sourceListingURL: "https://instagram.com/x",
                                   websiteURL: nil) == .hardToReach)
        #expect(Reachability.badge(result: nil,
                                   presenter: "Aurora Strings", sourceListingURL: "https://carnegiehall.org/x",
                                   websiteURL: nil) == Reachability.Badge.none)   // named presenter, no proof: silent
    }

    // #1596 (milestone 32 Phase 3): the badge reads the STORED result of a check, not a live derivation
    // from the row's recipients. Deriving it every time a row draws was wrong three ways: it costs a
    // main-thread fault on a long list (#1121), it silently changes when Dan edits a contact by hand, and
    // it cannot tell "we checked and found nobody" from "we never checked".
    @Test("a stored result decides the badge")
    func storedResultDecidesTheBadge() {
        #expect(Reachability.badge(result: .emailFound, presenter: "Some Org",
                                   sourceListingURL: nil, websiteURL: nil) == .emailFound)
        #expect(Reachability.badge(result: .weakContactOnly, presenter: "Some Org",
                                   sourceListingURL: nil, websiteURL: nil) == .weakContactOnly)
        #expect(Reachability.badge(result: .noEmailFound, presenter: "Some Org",
                                   sourceListingURL: nil, websiteURL: nil) == .noEmailFound)
    }

    // No stored result means no check has ever run, so the row falls back to the free heuristic. This is
    // the distinction the old derivation could not make: a show with no recipients looked identical
    // whether it had been checked and come back empty or never been looked at.
    @Test("no stored result falls back to the free heuristic")
    func noStoredResultFallsBackToTheHeuristic() {
        #expect(Reachability.badge(result: nil, presenter: "Some Org",
                                   sourceListingURL: nil, websiteURL: nil) == .none)
        // #1859: no organiser named is no longer a verdict, only an unlooked-at show, so it stays silent
        // like every other state the heuristic cannot speak to.
        #expect(Reachability.badge(result: nil, presenter: nil,
                                   sourceListingURL: nil, websiteURL: nil) == .none)
    }

    @Test("a stale result overrides every stored answer")
    func staleOverridesTheStoredAnswer() {
        for stored in [Reachability.ProbeResult.emailFound, .weakContactOnly, .noEmailFound] {
            #expect(Reachability.badge(result: stored, probeIsStale: true, presenter: "Some Org",
                                       sourceListingURL: nil, websiteURL: nil) == .staleProbe)
        }
    }
}
