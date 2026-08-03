import Testing
import Foundation

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

    // Dan's call, 2026-07-28, arrived at over two rounds of looking at the real cards.
    //
    // First it was gold, the same as a verified find, and he said an address he would want to CHECK
    // before writing must not be painted as his most actionable row. So it went to rust. Looking at THAT,
    // his verdict: "unverified email looks like no email. too similar." Rust made it distinct from a
    // verified find and indistinguishable from a failure, which is worse.
    //
    // The palette had no free slot between the two, because forest, nominally the fourth tone, is
    // unusable on this background (it is what made "Email found" the faintest badge in the first place).
    // So this state gets its own dim gold: found-something stays in the gold family, found-nothing stays
    // rust, and the three read as three weights. He chose it from a rendered comparison of the options.
    @Test func anUnverifiedFindHasItsOwnTone() {
        #expect(Reachability.tone(for: .emailFound, onlyUnverified: true) == .tentative)
        #expect(Reachability.tone(for: .emailFound, onlyUnverified: false) == .pending)
    }

    // The requirement stated as what Dan actually asked for, rather than as an invented prominence
    // ranking: these three states must all LOOK different. A found-but-doubtful address must not read as
    // a verified one, and it must not read as nothing found.
    @Test func theThreeContactOutcomesAreAllVisuallyDistinct() {
        let verified = Reachability.tone(for: .emailFound)
        let unverified = Reachability.tone(for: .emailFound, onlyUnverified: true)
        let nothing = Reachability.tone(for: .noEmailFound)
        #expect(verified != unverified, "a doubtful address must not look like a solid one")
        #expect(unverified != nothing, "Dan, 2026-07-28: unverified email looks like no email, too similar")
        #expect(verified != nothing)
    }

    // A verified find is still the loudest thing on the row, and a form is still the quietest.
    @Test func aVerifiedFindIsLoudestAndAFormIsQuietest() {
        #expect(Reachability.tone(for: .emailFound) == .pending)
        #expect(Reachability.tone(for: .contactFormOnly) == .neutral)
    }

    // `onlyUnverified` describes the ADDRESSES a check found, so it can only ever change the
    // email-found badge. Every other state must ignore it rather than quietly changing colour.
    @Test func theOtherBadgesIgnoreTheUnverifiedFlag() {
        for badge in [Reachability.Badge.noEmailFound, .contactFormOnly, .weakContactOnly,
                      .hardToReach, .staleProbe] {
            #expect(Reachability.tone(for: badge, onlyUnverified: true)
                    == Reachability.tone(for: badge))
        }
    }
}
