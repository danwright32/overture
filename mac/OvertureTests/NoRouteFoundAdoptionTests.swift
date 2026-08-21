import Testing
import Foundation

// #2925: the VERDICT half of the adoption census, over runs handed in rather than read off this Mac.
//
// `NoRouteFoundAdoptionMeasurementTests` reads the real files, and on 2026-08-21 every one of them
// predates the value it is asking about, so the branch that matters cannot be told from the branch that
// does not: a fixture that only ever asks the corpus it happens to have proves nothing about the case it
// exists for (L140). Measured with `scripts/mutate.sh`: deleting the pre-change guard there was reported
// SURVIVED, because with zero post-change runs both paths reach the same answer.
//
// So the decision is a function over runs, and the runs are supplied.
@Suite("What the no_route_found census concludes, per run (#2925)")
struct NoRouteFoundAdoptionTests {
    private func run(_ day: String, contacts: Int, noRouteFound: Int, refused: Int,
                     writtenAt: String) -> NoRouteFoundAdoption.Run {
        NoRouteFoundAdoption.Run(label: day, contacts: contacts, noRouteFound: noRouteFound,
                                 showsRefused: refused,
                                 writtenAt: ISO8601DateFormatter().date(from: writtenAt)!)
    }

    private let shipped = ISO8601DateFormatter().date(from: "2026-08-18T00:58:29Z")!

    // The state on 2026-08-21: real runs, all of them older than the value. Their zero adoptions are not
    // evidence of anything, and saying so is the whole point.
    @Test func runsThatPredateTheValueAreNotEvidenceAboutIt() {
        let runs = [run("older", contacts: 52, noRouteFound: 0, refused: 2, writtenAt: "2026-08-09T23:30:41Z"),
                    run("also older", contacts: 20, noRouteFound: 0, refused: 2, writtenAt: "2026-08-07T14:04:21Z")]

        #expect(NoRouteFoundAdoption.verdict(runs: runs, shippedAt: shipped) == .nothingToJudgeYet)
    }

    // A run written the moment before it shipped still predates it. The boundary is checked because an
    // off-by-one here would quietly turn the answer above into a false accusation.
    @Test func theBoundaryIsTheMomentItShipped() {
        let before = [run("just before", contacts: 10, noRouteFound: 0, refused: 5,
                          writtenAt: "2026-08-18T00:58:28Z")]
        #expect(NoRouteFoundAdoption.verdict(runs: before, shippedAt: shipped) == .nothingToJudgeYet)

        let after = [run("just after", contacts: 10, noRouteFound: 0, refused: 5,
                         writtenAt: "2026-08-18T00:58:29Z")]
        #expect(NoRouteFoundAdoption.verdict(runs: after, shippedAt: shipped) != .nothingToJudgeYet)
    }

    // THE case the whole issue is about: runs since the value shipped that go on naming a route they do
    // not have. The refusal is then firing on the ordinary case, which is how a guard gets switched off.
    @Test func refusingHalfTheContactsSinceItShippedIsTheAlarm() {
        let runs = [run("since", contacts: 10, noRouteFound: 0, refused: 6, writtenAt: "2026-08-20T12:00:00Z")]

        #expect(NoRouteFoundAdoption.verdict(runs: runs, shippedAt: shipped) == .firingOnTheOrdinaryCase)
    }

    // And the healthy shape: runs since it shipped, using the value, with the refusal rare.
    @Test func adoptedAndRarelyRefusedIsTheAnswerItIsWaitingFor() {
        let runs = [run("since", contacts: 40, noRouteFound: 5, refused: 1, writtenAt: "2026-08-20T12:00:00Z")]

        #expect(NoRouteFoundAdoption.verdict(runs: runs, shippedAt: shipped) == .adopted)
    }

    // Post-change runs that never use the value, but do not trip the refusal either. Neither the alarm
    // nor the all-clear: the instruction may simply have had no name-only contact to report, and a run
    // that ignored it looks exactly the same from here (L128). Named rather than folded into either.
    @Test func neverUsedAndNeverRefusedIsItsOwnAnswer() {
        let runs = [run("since", contacts: 40, noRouteFound: 0, refused: 1, writtenAt: "2026-08-20T12:00:00Z")]

        #expect(NoRouteFoundAdoption.verdict(runs: runs, shippedAt: shipped) == .noOccasionToUseIt)
    }

    // A post-change run carrying no contacts at all decides nothing, for the reason above one level down:
    // zero of zero is not a rate.
    @Test func aRunWithNoContactsDecidesNothing() {
        let runs = [run("since", contacts: 0, noRouteFound: 0, refused: 0, writtenAt: "2026-08-20T12:00:00Z")]

        #expect(NoRouteFoundAdoption.verdict(runs: runs, shippedAt: shipped) == .nothingToJudgeYet)
    }
}
