import Testing
import Foundation

// #2399, phase 6 of docs/plans/2026-08-09-one-outcome-vocabulary.md, and the fix for #2401.
//
// The measured defect: `OutcomeStats.tally` counted a loss by reading `Outcome.lostSoft`/`.lostHard`, and
// NOTHING in the app ever wrote either. Every close-out landed on the contact. So the funnel's lost count
// was structurally zero and every closed-out show was filed under "no response", which is a confident
// number rather than a blank, and therefore the worse kind of wrong (L90).
//
// Three groups, not two. Dan: "I don't think we should count scouted but not pitched as 'lost'. I do think
// it's worth counting though."
@Suite("The funnel's three groups (#2399)")
struct ReportingThreeGroupsTests {

    private func sample(_ outcome: ShowOutcome?, pitched: Bool = true, replied: Bool = false,
                        source: OutcomeSource? = nil) -> OutcomeSample {
        OutcomeSample(wasContacted: pitched, outcome: outcome == .booked ? .booked : .noResponse,
                      dimension: "self", outcomeSource: source, showOutcome: outcome,
                      aContactReplied: replied)
    }

    // MARK: the lost count is real now

    // The whole point of the phase. Each of the four ways a pitch ends badly has to reach the lost count,
    // which read zero for as long as it existed.
    @Test func everyPitchedEndingThatIsNotABookingCounts() {
        let t = OutcomeStats.tally([sample(.theySaidNo), sample(.theySaidNotNow),
                                    sample(.neverHeardBack), sample(.turnedThemDown)])
        #expect(t.lost == 4)
        #expect(t.noResponse == 0, "a recorded ending is never 'nothing has happened yet'")
    }

    // And the reasons are kept apart, because "they said no" and "nobody answered" are different facts and
    // the report exists to tell Dan which is happening to him.
    @Test func thelostCountKeepsItsReasons() {
        let t = OutcomeStats.tally([sample(.theySaidNo), sample(.theySaidNo), sample(.neverHeardBack)])
        #expect(t.lostReasons[.theySaidNo] == 2)
        #expect(t.lostReasons[.neverHeardBack] == 1)
        #expect(t.lostReasons[.theySaidNotNow] == nil)
    }

    // MARK: never pitched is its own group

    @Test func aShowNothingWasSentToIsNeverCountedAsLost() {
        let t = OutcomeStats.tally([sample(.dateConflict, pitched: false),
                                    sample(.notAFit, pitched: false),
                                    sample(.hadPaidWork, pitched: false)])
        #expect(t.neverPitched == 3)
        #expect(t.lost == 0)
        #expect(t.contacted == 0, "nothing was sent, so none of these are pitches")
    }

    @Test func theneverPitchedGroupKeepsItsReasons() {
        let t = OutcomeStats.tally([sample(.tooSoon, pitched: false),
                                    sample(.tooSoon, pitched: false),
                                    sample(.pitchingOtherShows, pitched: false)])
        #expect(t.neverPitchedReasons[.tooSoon] == 2)
        #expect(t.neverPitchedReasons[.pitchingOtherShows] == 1)
    }

    // The question Dan wants answerable eventually (#16): how many strong shows does he drop purely for
    // want of a night. It is only answerable if this reason stays its own number.
    @Test func runningOutOfNightsIsItsOwnNumber() {
        let t = OutcomeStats.tally([sample(.pitchingOtherShows, pitched: false),
                                    sample(.dateConflict, pitched: false)])
        #expect(t.neverPitchedReasons[.pitchingOtherShows] == 1)
        #expect(t.neverPitchedReasons[.dateConflict] == 1)
    }

    // MARK: a booking

    @Test func abookingLandsInItsOwnGroupWithItsSource() {
        let t = OutcomeStats.tally([sample(.booked, source: .manual), sample(.booked, source: .auto)])
        #expect(t.booked == 2)
        #expect(t.bookedManual == 1)
        #expect(t.bookedAuto == 1)
        #expect(t.lost == 0)
        #expect(t.neverPitched == 0)
    }

    // MARK: a pitch that has not ended

    // An open pitch is not an outcome. It has to stay out of all three groups, or the report would count
    // every live pitch as closed on the day it is read.
    @Test func anOpenPitchIsInNoneOfTheThreeGroups() {
        let t = OutcomeStats.tally([sample(nil), sample(nil, replied: true)])
        #expect(t.contacted == 2)
        #expect(t.booked == 0)
        #expect(t.lost == 0)
        #expect(t.neverPitched == 0)
        #expect(t.noResponse == 1)
        #expect(t.replied == 1, "somebody wrote back, which is not the same as silence")
    }

    // MARK: nothing is dropped in silence

    // `wentBy` and `tooFar` are Overture's own and belong in no reported group, but they must be COUNTED
    // somewhere rather than vanishing, or the groups would silently fail to add up to the shows that ended
    // and nobody reading the report could tell.
    @Test func overturesOwnEndingsAreCountedApartRatherThanDropped() {
        let t = OutcomeStats.tally([sample(.wentBy, pitched: false), sample(.tooFar, pitched: false)])
        #expect(t.overturesOwn == 2)
        #expect(t.neverPitched == 0)
        #expect(t.lost == 0)
        #expect(t.booked == 0)
    }

    // The arithmetic the three groups promise: every ended show lands in exactly one bucket, and the
    // buckets add up to the endings that were recorded. A group that quietly failed to account for a value
    // is the defect this whole phase exists to remove.
    @Test func everyEndedShowLandsInExactlyOneBucket() {
        let ended = ShowOutcome.allCases.map { sample($0, pitched: !ShowOutcome.neverPitched.contains($0)) }
        let t = OutcomeStats.tally(ended)
        #expect(t.booked + t.lost + t.neverPitched + t.overturesOwn == ShowOutcome.allCases.count)
    }
}

// The other half of #2401: what the SCOUT learns. Overture could learn that an org booked Dan and could
// never learn that one turned him down, so they came back next season ranked as if nothing had happened.
@Suite("What a refusal teaches the next scout (#2399)")
struct RefusalTeachesTheScoutTests {

    private func show(_ outcome: ShowOutcome?, org: String = "Some Org", sent: Bool = true) -> Prospect {
        let p = Prospect(naturalKey: "\(org)|k", groupName: org, discipline: "music", venue: "V",
                         performanceDate: "2026-11-18", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .contacted)
        if sent { p.sentAt = Date() }
        p.showOutcome = outcome
        return p
    }

    private func status(_ p: Prospect) -> String? {
        LocalHistory.records(from: [p]).first?.status
    }

    // The fix. A refusal now reaches the history, so the same org next season is not ranked as a stranger.
    @Test func arefusalIsRecordedAgainstTheOrg() {
        #expect(status(show(.theySaidNo)) == "lost_hard")
    }

    @Test func asoftNoLeavesTheDoorOpenInTheHistoryToo() {
        #expect(status(show(.theySaidNotNow)) == "lost_soft")
    }

    // A silence is not a refusal, and this is the rule that says so where it matters: nobody turned Dan
    // down, so the org must not be ranked lower for never having written back.
    @Test func asilenceDoesNotTeachTheScoutARefusal() {
        let s = status(show(.neverHeardBack))
        #expect(s != "lost_hard")
        #expect(s != "lost_soft")
        #expect(s == "contacted", "a pitch went out, and that is all that happened")
    }

    // DAN turned them down. Recording that against the org would say they refused him, which is the
    // opposite of what happened, and it would then rank an org lower for a decision he made about one show.
    @Test func danTurningThemDownIsNotRecordedAsTheirRefusal() {
        let s = status(show(.turnedThemDown))
        #expect(s != "lost_hard")
        #expect(s != "lost_soft")
    }

    @Test func abookingIsStillTheStrongestSignal() {
        #expect(status(show(.booked)) == "booked")
    }

    // `wentBy` is a fact about the calendar, not a judgement, so it must teach the scout nothing at all.
    @Test func ashowThatWentByTeachesNothing() {
        #expect(status(show(.wentBy, sent: false)) == nil)
    }
}
