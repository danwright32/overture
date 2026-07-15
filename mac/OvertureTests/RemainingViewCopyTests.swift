import Testing
import Foundation
@testable import Overture

// #885, the rest of the sweep: the copy in the smaller screens.
//
// The headline here is the do-not-contact refusal. That sentence, the one SourcesView's own header
// comment calls "the one thing in the whole feature that must not be got wrong quietly", was written out
// by hand in three separate view bodies, in two files, in two slightly different wordings. Nothing
// tested any of them.
@MainActor
@Suite("Remaining view copy (#885)")
struct RemainingViewCopyTests {

    // MARK: - The refusal

    // Adding, and pasting a lead, are the same refusal and now say the same thing, once.
    @Test func theRefusalNamesTheOrgAndSaysWhatOvertureWillNotDo() {
        let message = WatchlistEditing.refusedMessage(orgName: "Kaufman")

        #expect(message == "Kaufman asked not to be contacted, so Overture won't watch their calendar.")
    }

    // Resuming a STOPPED source is a different action and keeps its own true sentence: "again" is doing
    // real work there, and would be a lie on a source being added for the first time.
    @Test func resumingARefusedOrgHasItsOwnTrueSentence() {
        let message = WatchlistEditing.resumeRefusedMessage(orgName: "Kaufman")

        #expect(message == "Kaufman asked not to be contacted, so Overture won't watch them again.")
    }

    @Test func theOtherWatchlistOutcomesEachSayWhatToDoNext() {
        #expect(WatchlistEditing.alreadyWatchingMessage(orgName: "Kaufman")
                    == "Already watching Kaufman's calendar.")
        #expect(WatchlistEditing.invalidURLMessage == "That doesn't look like a web address.")
        #expect(WatchlistEditing.needsNameMessage
                    == "Give the organization a name so you can recognize it here.")
    }

    // MARK: - Sources

    @Test func aSourceNeverCheckedSaysSoRatherThanShowingABlank() {
        #expect(SourceReadState.lastCheckedLine(at: nil, now: Date()) == "Never checked")
    }

    @Test func aCheckedSourceReadsAsRelativeTime() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let line = SourceReadState.lastCheckedLine(at: now.addingTimeInterval(-7_200), now: now)

        #expect(line.hasPrefix("Checked "))
        #expect(line != "Checked ")
    }

    // MARK: - Outcome patterns
    //
    // These are statistical claims Dan is invited to act on, and the suppression rule (hide the
    // percentage when the sample is too small to mean anything) was a ternary in a view body.

    @Test func aLowSampleHidesThePercentageBecauseItWouldMislead() {
        let tally = OutcomeTally(contacted: 2, replied: 1, booked: 1, bookedAuto: 0, bookedManual: 1)

        let line = OutcomePatterns.bookedLine(tally)

        #expect(line == "1 booked of 2")   // no rate: two shows cannot tell you a booking rate
    }

    @Test func aRealSampleShowsTheRate() {
        let tally = OutcomeTally(contacted: 20, replied: 5, booked: 5, bookedAuto: 2, bookedManual: 3)

        let line = OutcomePatterns.bookedLine(tally)

        #expect(line == "5 booked of 20 · 25%")
    }

    // "Replied" means replied PLUS booked: somebody who booked certainly replied. That rule was a bare
    // bit of arithmetic in the view, and it is the difference between an honest response rate and one
    // that undercounts every success.
    @Test func repliedIncludesTheOnesWhoWentOnToBook() {
        let tally = OutcomeTally(contacted: 20, replied: 3, booked: 2, bookedAuto: 1, bookedManual: 1)

        #expect(OutcomePatterns.repliedLine(tally) == "5 replied · 25%")
    }

    // MARK: - Live runs

    // #472: a run past its timeout that is still genuinely alive must never say "looks stuck". The
    // stalled sentence was the one label in LiveRunLabel that was not in RunProgress, an asymmetry with
    // nothing holding it in place.
    @Test func aStalledRunSaysSoAndCarriesItsElapsedTime() {
        #expect(RunProgress.stalledLabel("Scouting", elapsed: "3:20") == "Scouting looks stuck (3:20)")
    }

    // MARK: - Add a lead

    // #843: one line, and it no longer restates itself ("to the queue" then "waiting … with everything
    // else"). The novel part ("ranked", interleaved) is folded in.
    @Test func theAddedNoteCountsWhatLanded() {
        #expect(LeadIntakeModel.addedNote(count: 1) == "Added 1 show, ranked into your queue with everything else.")
        #expect(LeadIntakeModel.addedNote(count: 4) == "Added 4 shows, ranked into your queue with everything else.")
    }

    // #843: with nothing added there is nothing to be "ranked and waiting", so the zero case says what
    // actually happened rather than describing shows that are not there.
    @Test func theAddedNoteDoesNotDescribeShowsThatAreNotThere() {
        let note = LeadIntakeModel.addedNote(count: 0)
        #expect(note == "No new shows landed in the queue from that page.")
        #expect(!note.contains("ranked"))
    }

    @Test func anAlreadyWatchedOrgIsToldWhyNothingMoreIsNeeded() {
        let note = LeadIntakeModel.alreadyWatchingNote(orgName: "Kaufman")

        #expect(note == "Already watching Kaufman's calendar, so their shows turn up on their own.")
    }

    // MARK: - Empty states
    //
    // "No data at all" and "your filter hid it" are different problems with different fixes, and telling
    // them apart is the entire job of this copy. It was decided by ternaries in two view bodies.

    @Test func anEmptyQueueAndAFilteredOneAreDifferentSentences() {
        let empty = EmptyState.queue(hasAnyItems: false)
        let filtered = EmptyState.queue(hasAnyItems: true)

        #expect(empty.title == "Nothing scouted yet")
        #expect(filtered.title == "Nothing matches this filter")
        #expect(empty.detail != filtered.detail)
    }

    // The Archive's own pair. #843: its empty title used to be the Queue's exact words ("Nothing scouted
    // yet"), which is wrong here, since nothing is ever scouted into an archive. It now says what is
    // actually true, and no longer collides with the Queue's title.
    @Test func anEmptyArchiveAndAFilteredOneAreDifferentSentences() {
        #expect(EmptyState.archive(hasAnyItems: false).title == "Nothing tracked yet")
        #expect(EmptyState.archive(hasAnyItems: true).title == "Nothing matches this filter")
        #expect(EmptyState.archive(hasAnyItems: false).detail
                    == "Shows land here once Overture has tracked at least one.")
    }

    // #843: the Queue and the Archive no longer share an empty title. The Queue's stays "Nothing scouted
    // yet" (correct: a scout is what fills it); the Archive's is its own sentence.
    @Test func theQueueAndArchiveNoLongerShareAnEmptyTitle() {
        #expect(EmptyState.queue(hasAnyItems: false).title != EmptyState.archive(hasAnyItems: false).title)
    }

    // MARK: - Reminder settings

    @Test func theDayStepperAgreesWithItsNumber() {
        #expect(Plural.count(1, "day") == "1 day")
        #expect(Plural.count(7, "day") == "7 days")
    }

    // MARK: - Onboarding
    //
    // Each failure branch is REMEDIATION: it tells Dan where to go and what to click. Copy that is only
    // ever seen when something went wrong is copy nobody exercises, which is exactly why it needs a test.

    @Test func aDeniedPermissionSaysWhereToFixIt() {
        #expect(OnboardingState.notificationsStatus(granted: true) == "Notifications allowed.")
        #expect(OnboardingState.notificationsStatus(granted: false)
                    .contains("Enable Overture in System Settings"))
        #expect(OnboardingState.omniFocusStatus(granted: true) == "OmniFocus permission granted.")
        #expect(OnboardingState.omniFocusStatus(granted: false).contains("Still not granted"))
    }

    @Test func aFailedGmailConnectCarriesTheRealReason() {
        let line = OnboardingState.gmailConnectFailed(reason: "network offline")

        #expect(line == "Couldn't connect Gmail: network offline")
    }
}
