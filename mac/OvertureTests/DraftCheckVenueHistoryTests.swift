import Testing
import Foundation

// #1887: a draft may say Dan knows a room, and may never say how many times he has shot it.
//
// The app sends the drafter a BAND and no count, so any number in this shape was invented. That is
// a fabricated fact about Dan's own history told to somebody who works at that venue, which is why
// this blocks rather than warns. A band token alone was not enough: the band-to-English mapping is
// still a rule living only in the prompt, and L27 says such a rule needs a deterministic check at
// the boundary.
@Suite("Draft check: venue history count")
struct DraftCheckVenueHistoryTests {

    private func flags(_ body: String) -> Bool {
        DraftCheck.findings(in: body).contains(.venueHistoryCount)
    }

    @Test func itBlocksRatherThanWarns() {
        #expect(DraftIssue.venueHistoryCount.isBlocking)
    }

    @Test func aNumberOfShowsAtTheVenueIsCaught() {
        #expect(flags("I've photographed three shows at The Green Room 42."))
        #expect(flags("I have shot five concerts there."))
        #expect(flags("I've covered a dozen performances in that room."))
        #expect(flags("I've shot 12 shows there."))
    }

    // A count written as a word rather than a digit is the same claim.
    @Test func acountWrittenAsAWordIsCaught() {
        #expect(flags("I've shot there twice."))
        #expect(flags("I've photographed a couple of shows there."))
    }

    // A vague many is still a claim about how many, and the bands exist so the email does not make
    // one.
    @Test func avagueCountIsStillACount() {
        #expect(flags("I've photographed numerous shows at that venue."))
        #expect(flags("I have shot several concerts there."))
    }

    // THE SANCTIONED WORDING. These are exactly the three sentences the runbook asks for, and every
    // one of them must pass or the feature blocks its own output.
    @Test func theBandWordingItselfIsFine() {
        #expect(!flags("I've photographed at The Green Room 42 before, so I know the room."))
        #expect(!flags("I've photographed a few shows there."))
        #expect(!flags("I shoot there regularly."))
    }

    // THE CREDENTIAL. "close to ten years" is a number attached to YEARS, not to a countable
    // occasion, and it is required by the runbook on a Carnegie show. A checker that blocked this
    // would block nearly every draft the app produces.
    @Test func theCarnegieTenureCredentialIsNotACount() {
        #expect(!flags("I've been photographing at Carnegie Hall for close to ten years."))
        #expect(!flags("I've photographed at Carnegie Hall for nearly 10 years."))
    }

    // AN OFFER ABOUT THE SHOW BEING PITCHED. A multi-night run is real (PrepQueueItem.runEndDate),
    // and a draft offering to cover all of its nights must not read as a history claim.
    @Test func anOfferToCoverSeveralNightsIsNotAHistoryClaim() {
        #expect(!flags("I'd be glad to cover all three performances."))
        #expect(!flags("I'll be photographing your two nights in August."))
        #expect(!flags("Happy to shoot both shows if that helps."))
    }

    // A count about something other than shooting is not this rule's business.
    @Test func anUnrelatedNumberIsLeftAlone() {
        #expect(!flags("The run is three nights long."))
        #expect(!flags("My rate is $250 an hour plus tax, with a one-hour minimum."))
    }

    @Test func anEmptyBodyIsNotACount() {
        #expect(!flags(""))
    }
}
