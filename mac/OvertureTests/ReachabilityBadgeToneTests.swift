import Testing
import Foundation
@testable import Overture

// Dan's call, 2026-07-28, looking at the real cards: the badges' visual loudness was the exact inverse
// of how much he would act on them. "Contact form only" was the loudest thing on the row, "No email
// found" next, and "Email found", the one he can act on immediately, was the quietest.
//
// The cause is structural rather than a bad colour pick: forest green on Overture's dark forest
// background has almost no contrast, so `.confirmed` is inherently the faintest tone in the app. The
// best news therefore looked like the least important news.
//
// So the tone now tracks ACTIONABILITY, which is also what Dan's standing rule already said about gold
// ("reserved for what he can act on"):
//   an address he can write to now          -> gold, loudest
//   nothing found, so he can dismiss it now -> rust, still prominent (deciding to drop it is acting)
//   only a form, or only a front desk       -> muted, quietest (a way through that costs him 15 minutes)
//
// Lives here, not in the view's switch, so the decision is testable at all (a SwiftUI body is not).
@Suite("Reachability badge tone follows actionability (#1601 walk)")
struct ReachabilityBadgeToneTests {
    @Test func anAddressHeCanWriteToIsTheLoudest() {
        #expect(Reachability.tone(for: .emailFound) == .pending)   // gold
    }

    @Test func nothingFoundStaysProminentBecauseDismissingIsAlsoActing() {
        #expect(Reachability.tone(for: .noEmailFound) == .warning) // rust
    }

    // The two that used to be gold and should not be: a form and a front desk are both real, but both
    // are the last thing he would pick up.
    @Test func aFormOnlyIsTheQuietest() {
        #expect(Reachability.tone(for: .contactFormOnly) == .neutral)
    }

    @Test func aWeakContactIsTheQuietestToo() {
        #expect(Reachability.tone(for: .weakContactOnly) == .neutral)
    }

    // Unchanged: both are advisory, neither is a finding.
    @Test func theAdvisoryBadgesStayCalm() {
        #expect(Reachability.tone(for: .hardToReach) == .neutral)
        #expect(Reachability.tone(for: .staleProbe) == .neutral)
    }

    // The whole point of the change, asserted as the ordering rather than as three separate colours, so
    // it fails if a future edit quietly reintroduces the inversion.
    @Test func loudnessRunsFromActNowDownToActLast() {
        let rank: [OVPillTone: Int] = [.pending: 3, .warning: 2, .confirmed: 1, .neutral: 0]
        let act = rank[Reachability.tone(for: .emailFound)]!
        let dismiss = rank[Reachability.tone(for: .noEmailFound)]!
        let later = rank[Reachability.tone(for: .contactFormOnly)]!
        #expect(act > dismiss)
        #expect(dismiss > later)
    }
}
