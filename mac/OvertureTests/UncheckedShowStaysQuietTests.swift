import Testing
import Foundation

// #1859: a show nobody has looked at does not get to be called hard to reach.
//
// Dan, on the post-merge check of #1856 (2026-07-31), asked what an untriaged show with no producer
// named says about reaching it, and expected: nothing, until a check runs. "The card stays silent on
// reachability while it is untouched, and only speaks once a check has actually looked for a contact."
//
// The premise the flag rested on has moved. A blank presenter used to mean there was nothing to email,
// full stop. Since #1856 a check on one of those shows pursues the ACT, so the show is not a dead end at
// all: it is one nothing has looked at yet, and there are 93 of them. Saying "hard to reach" there is
// LESSONS L11, a message claiming what no check measured.
//
// What still speaks is what was actually MEASURED. A social-only listing is a verified dead end (a raw
// fetch of one returns a login wall, and lead intake refuses them outright), so it keeps saying so.
@Suite("A show nobody has checked says nothing about reaching it (#1859)")
struct UncheckedShowStaysQuietTests {

    // The 93. No organiser named, an ordinary listing, no check on file: the card says nothing at all
    // about reachability rather than a verdict nothing reached.
    @Test func aShowWithNoOrganiserNamedSaysNothingBeforeACheck() {
        #expect(Reachability.badge(result: nil, presenter: nil,
                                   sourceListingURL: "https://thegreenroom42.venuetix.com/show/1") == .none)
        // A presenter that is only whitespace is not a presenter, and takes the same silence.
        #expect(Reachability.badge(result: nil, presenter: "   ",
                                   sourceListingURL: "https://example.org/events/1") == .none)
    }

    // A show with nothing in hand at all, not even a listing, is still just unlooked-at.
    @Test func aShowWithNoListingEitherIsStillOnlyUnchecked() {
        #expect(Reachability.badge(result: nil, presenter: nil,
                                   sourceListingURL: nil) == .none)
    }

    // THE FAILURE DIRECTION, and the reason this is a narrowing rather than a removal: a social-only
    // listing is a dead end Overture actually measured, so it keeps warning, whoever is or is not named.
    @Test func aSocialOnlyListingStillWarns() {
        #expect(Reachability.badge(result: nil, presenter: nil,
                                   sourceListingURL: "https://www.instagram.com/p/abc123/") == .hardToReach)
        #expect(Reachability.badge(result: nil, presenter: "Aurora Strings",
                                   sourceListingURL: "https://facebook.com/events/123") == .hardToReach)
    }

    // And a paid answer still outranks everything: silence before a check never overwrites what a check
    // came back with, in either direction.
    @Test func aCheckedShowStillReportsWhatTheCheckFound() {
        #expect(Reachability.badge(result: .emailFound, presenter: nil,
                                   sourceListingURL: "https://example.org/events/1") == .emailFound)
        #expect(Reachability.badge(result: .noEmailFound, presenter: nil,
                                   sourceListingURL: "https://example.org/events/1") == .noEmailFound)
    }

    // The signal underneath is unchanged and still honest: there IS nothing in hand to email on one of
    // these shows. What changed is only whether that is worth saying to Dan before anything has looked.
    @Test func theUnderlyingSignalStillReadsTheShowTheSameWay() {
        #expect(Reachability.assess(presenter: nil, sourceListingURL: "https://example.org/events/1") == .hardToReach)
    }
}
