import Testing
import Foundation
@testable import Overture

// #1795: "Hard to reach" was being said for two different reasons, and only one of them had been
// measured. A listing that is a social page only is a VERIFIED dead end: a raw fetch returns a login
// wall. A show with no presenting org is not a dead end at all, it is a show nothing has looked at yet,
// and saying "hard to reach" there claims a conclusion no check reached (L11).
//
// LIVE-STORE-CLAIM verified=2026-07-30 measure="open rows with no presenter and no contact check on file, split by why the presenter is missing, and by venue"
// Measured 2026-07-30: 93 open rows carried the badge with no contact check on file. 78 of them are rows
// where Overture itself removed a presenter that was only the room's own name; the other 15 came from
// pages that named nobody. They are almost entirely rental rooms booking a different act every night:
// The Green Room 42 (63), SoHo Playhouse (7), Jalopy Theatre (7), Roulette Intermedium (6), Under St
// Marks (5). Those listings name the room and name the ACT, and never say who is producing.
//
// So the new wording applies only where Overture KNOWS why the organiser is missing, which is the
// measured `presenterWasTheRoom` flag. Dan's words, 2026-07-30: "It should try the act directly."
// The 15 whose pages named nobody are left alone: nothing establishes that their title is an act, and a
// badge telling him to write to a show title he cannot place would be the same overclaim in a new coat.
//
// Aiming the paid contact check itself at the act is a separate and larger change (#1856), because the
// performer route is gated on a confident producer for good reason and these rows have none.
@Suite("Try the act directly, where the room was the only name (#1795)")
struct ActDirectlyBadgeTests {
    // The 78. Overture removed the room's own name, so the act is the only party still billed.
    @Test func aShowWhoseOnlyNamedPartyIsTheActSaysToTryTheAct() {
        let badge = Reachability.badge(result: nil, presenter: nil,
                                       sourceListingURL: "https://thegreenroom42.venuetix.com/show/1",
                                       websiteURL: nil, presenterWasTheRoom: true)
        #expect(badge == .tryTheActDirectly)
    }

    // THE FAILURE DIRECTION that matters most: a verified dead end must keep saying so. A social-only
    // listing is measured, not guessed, and it outranks the room flag, because there is genuinely no way
    // through whoever is billed.
    @Test func aSocialOnlyListingStillReadsHardToReach() {
        let badge = Reachability.badge(result: nil, presenter: nil,
                                       sourceListingURL: "https://www.instagram.com/p/abc123/",
                                       websiteURL: nil, presenterWasTheRoom: true)
        #expect(badge == .hardToReach)
    }

    // The other 15. Nothing says their title is an act, so they keep the existing wording rather than
    // being told to write to a name Overture cannot vouch for.
    @Test func aPageThatNamedNobodyKeepsTheExistingWording() {
        let badge = Reachability.badge(result: nil, presenter: nil,
                                       sourceListingURL: "https://example.org/events/1",
                                       websiteURL: nil, presenterWasTheRoom: false)
        #expect(badge == .hardToReach)
    }

    // A show with a real presenter is untouched, whatever the flag says.
    @Test func aShowWithARealPresenterIsUnaffected() {
        let badge = Reachability.badge(result: nil, presenter: "The Golden Hour Series",
                                       sourceListingURL: "https://example.org/events/1",
                                       websiteURL: nil, presenterWasTheRoom: false)
        #expect(badge != .tryTheActDirectly)
        #expect(badge != .hardToReach)
    }

    // A paid answer always outranks the free heuristic, so a checked show never falls back to advice.
    @Test func aCheckedShowKeepsItsPaidAnswer() {
        let badge = Reachability.badge(result: .emailFound, presenter: nil,
                                       sourceListingURL: "https://thegreenroom42.venuetix.com/show/1",
                                       websiteURL: nil, presenterWasTheRoom: true)
        #expect(badge == .emailFound)
    }

    // The badge is advice, not an alarm, so it must not shout louder than the answers Dan can act on.
    // #1145's rule: the loudness of a badge tracks how much he would act on it.
    @Test func theAdviceIsAsQuietAsTheOtherUnresolvedStates() {
        #expect(Reachability.tone(for: .tryTheActDirectly)
                == Reachability.tone(for: .hardToReach))
    }

    // The sentence Dan reads, pinned here so a reword shows up in the copy inventory diff as words
    // rather than as a line of Swift.
    @Test func theWordingSaysWhatToDoAndClaimsNothingItHasNotChecked() {
        #expect(ReachabilityCopy.tryTheActDirectlyBadge == "Try the act directly")
    }
}
