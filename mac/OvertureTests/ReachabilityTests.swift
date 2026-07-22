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

    // #1308 Layer 2 Phase 2: once a probe has run, the badge shows the FIRM answer (email found / not
    // found) instead of the free heuristic. Before a probe, it falls back to the heuristic (only the hard
    // cases surface; a named presenter with no proven site stays silent, over-promising nothing).
    @Test func aProbedShowShowsTheFirmResult() {
        #expect(Reachability.badge(probed: true, hasSendableEmail: true,
                                   presenter: nil, sourceListingURL: "https://instagram.com/x",
                                   websiteURL: nil) == .emailFound)
        #expect(Reachability.badge(probed: true, hasSendableEmail: false,
                                   presenter: "Aurora Strings", sourceListingURL: "https://carnegiehall.org/x",
                                   websiteURL: nil) == .noEmailFound)
    }

    // #1324: a probe can find only a WEAK contact (a venue front desk or a press inbox). That address is
    // real but held back by the venue/press guard, so it is not sendable-pending. Reporting "No email
    // found" is misleading (an email exists); the badge says "Weak contact only" instead. A sendable
    // contact still wins, and a probe that found nothing at all still says "No email found".
    @Test func aProbedShowWithOnlyAWeakContactSaysWeakContactOnly() {
        #expect(Reachability.badge(probed: true, hasSendableEmail: false, hasWeakContactEmail: true,
                                   presenter: "Aurora Strings", sourceListingURL: nil,
                                   websiteURL: nil) == .weakContactOnly)
        #expect(Reachability.badge(probed: true, hasSendableEmail: true, hasWeakContactEmail: true,
                                   presenter: "Aurora Strings", sourceListingURL: nil,
                                   websiteURL: nil) == .emailFound)   // a sendable contact wins
        #expect(Reachability.badge(probed: true, hasSendableEmail: false, hasWeakContactEmail: false,
                                   presenter: "Aurora Strings", sourceListingURL: nil,
                                   websiteURL: nil) == .noEmailFound)  // nothing at all
    }

    // #1325: a probe result is trusted only for a window (reachabilityProbedAt within probeFreshness).
    // Past it the org may have moved, so the firm answer (found OR not found) becomes a distinct "worth
    // re-checking" badge rather than a stale firm claim that could mislead a keep/dismiss.
    @Test func aStaleProbeResultRevertsToAWorthRecheckingBadge() {
        #expect(Reachability.badge(probed: true, hasSendableEmail: true, probeIsStale: true,
                                   presenter: "Aurora Strings", sourceListingURL: nil,
                                   websiteURL: nil) == .staleProbe)
        #expect(Reachability.badge(probed: true, hasSendableEmail: false, probeIsStale: true,
                                   presenter: "Aurora Strings", sourceListingURL: nil,
                                   websiteURL: nil) == .staleProbe)   // a stale "not found" is re-check too
        #expect(Reachability.badge(probed: true, hasSendableEmail: true, probeIsStale: false,
                                   presenter: "Aurora Strings", sourceListingURL: nil,
                                   websiteURL: nil) == .emailFound)   // fresh: still the firm result
    }

    @Test func probeStalenessRespectsTheFreshnessWindow() {
        let probedAt = Date(timeIntervalSince1970: 1_000_000)
        #expect(Reachability.probeIsStale(probedAt: nil, now: probedAt) == false)   // never probed
        #expect(Reachability.probeIsStale(probedAt: probedAt,
                                          now: probedAt.addingTimeInterval(Reachability.probeFreshness - 1)) == false)
        #expect(Reachability.probeIsStale(probedAt: probedAt,
                                          now: probedAt.addingTimeInterval(Reachability.probeFreshness + 1)) == true)
    }

    @Test func anUnprobedShowFallsBackToTheHeuristic() {
        #expect(Reachability.badge(probed: false, hasSendableEmail: false,
                                   presenter: "Aurora Strings", sourceListingURL: "https://instagram.com/x",
                                   websiteURL: nil) == .hardToReach)
        #expect(Reachability.badge(probed: false, hasSendableEmail: false,
                                   presenter: "Aurora Strings", sourceListingURL: "https://carnegiehall.org/x",
                                   websiteURL: nil) == Reachability.Badge.none)   // named presenter, no proof: silent
    }
}
