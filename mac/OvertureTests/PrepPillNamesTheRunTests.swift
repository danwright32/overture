import Testing
import Foundation

// #2614: Dan, looking at the masthead while a reachability check was in flight: "why does prep say
// running now when I'm actually running a scout? that's disingenuous".
//
// Measured on the live handoff directory at that moment: `reachability-probe-run.json` written 10:43
// naming 4 shows, `prep-run.log` ending in "reachability check split into 4 chunk(s)", and no scout
// marker at all. A check, not a Prep run.
//
// The cause was one boolean. `AgentInputs.checkRunning` was `PrepQueueService.isRunning`, the presence of
// a beating `prep-running` marker, and THREE kinds of detached run take that marker: a Prep drafting run,
// a per-row re-prep, and a reachability check. Every one of them rendered as "Prep: Running now…" over a
// count belonging to work that had not started (L11: a message may claim only what its check measured).
//
// Dan's decision, 2026-08-13, shown the alternatives: while a check holds the run slot, the pill states
// his real prep backlog AND the reason it cannot start, rather than describing the check. The count and
// the tap stay on the backlog, so the number is still a promise about the rows the tap lands on (#863).
@Suite("The Prep pill says which run is holding the slot (#2614)")
struct PrepPillNamesTheRunTests {
    private let calm = AgentInputs(toTriage: 0, keptToPrep: 0, toReview: 0,
                                   readyToSend: 0, gmailConnected: true, sendErrors: 0, followUpsDue: 0)

    private func prep(_ inputs: AgentInputs) -> AgentStatus {
        AgentRoster.statuses(inputs).first { $0.name == "Prep" }!
    }

    // #2761 REVERSED this. It used to assert "5 ready, held by a check", which was true while a check held
    // the single slot and no Prep run could start. After #3015 a check holds nothing: Dan can start a Prep
    // run while one is going, and the only shows it leaves out are the ones that check is actually on.
    // So the pill shows his real, actionable backlog, and the old sentence would now be a lie about a
    // state that no longer exists.
    @Test func acheckNoLongerHoldsThePrepBacklog() {
        var i = calm; i.keptToPrep = 5; i.runInFlight = .reachabilityCheck

        let s = prep(i)

        #expect(s.detail == "5 ready to prep")
        #expect(!s.detail.contains("held by a check"),
                "the pill still says a check is holding the backlog, which after #3015 it is not")
        #expect(!s.detail.contains("Running now"))
    }

    // A real Prep run is unchanged: it IS drafting, so it still says so.
    @Test func aprepRunStillSaysItIsRunning() {
        var i = calm; i.keptToPrep = 5; i.runInFlight = .prep

        #expect(prep(i).detail == "Running now…")
        #expect(prep(i).state == .working)
    }

    // #2761 REVERSED this too, and for the same reason the wording changed. Gold is reserved for what Dan
    // can act on, which is why a HELD backlog was deliberately not gold. After #3015 he can act on it: the
    // Prep button is live during a check. So gold is now the correct colour, and keeping it grey would
    // hide the one thing he could do.
    @Test func abacklogDuringACheckIsSomethingHeCanActOn() {
        var i = calm; i.keptToPrep = 5; i.runInFlight = .reachabilityCheck

        #expect(prep(i).state == .needsAttention,
                "a backlog he can now start a run on must read as actionable")
    }

    // The count and the tap stay on the backlog, which is the whole reason this wording was chosen over
    // naming the check: the pill keeps pointing at Dan's work (#863).
    @Test func thecountAndTheTapStayOnTheBacklog() {
        var i = calm; i.keptToPrep = 5; i.runInFlight = .reachabilityCheck

        #expect(prep(i).count == 5)
        #expect(prep(i).focus == .prep)
    }

    // Failure path: a check running over a queue with nothing kept must not state a backlog of zero.
    // "0 ready, held by a check" is a promise about no rows at all, and the tap would land on an empty
    // list (#863). It falls through to what is actually true of the stage.
    @Test func acheckWithNothingKeptDoesNotInventABacklog() {
        var i = calm; i.runInFlight = .reachabilityCheck

        #expect(!prep(i).detail.contains("held by a check"))
        #expect(prep(i).detail == "Nothing waiting")
        #expect(prep(i).count == 0)
    }

    // And with nothing kept but shows held by a date clash, the clash still speaks: it is the one of the
    // two Dan can clear, so it must not be hidden behind a run that will end by itself.
    @Test func adateClashStillSpeaksWhenNothingIsKept() {
        var i = calm; i.prepBlocked = 2; i.runInFlight = .reachabilityCheck

        #expect(prep(i).detail == "2 shows held by a date clash")
        #expect(prep(i).state == .needsAttention)
    }

    // Nothing running at all: untouched.
    @Test func anidleQueueIsUnchanged() {
        var i = calm; i.keptToPrep = 5

        #expect(prep(i).detail == "5 ready to prep")
        #expect(prep(i).state == .needsAttention)
    }

    // The state space has no impossible corner in it any more. Two independent booleans could say a
    // probe was running while Prep was not, which is a state the app cannot be in: a probe holds the same
    // single slot, so it is by definition also "running".
    @Test func thereIsOneValueSayingWhatHoldsTheSlot() {
        #expect(calm.runInFlight == nil)
        // #2761: only a PREP run now changes what this pill says. A check no longer holds the prep
        // backlog, so it reads exactly as it does with nothing running, which is the point.
        var running = calm; running.keptToPrep = 5; running.runInFlight = .prep
        #expect(prep(running).state == .working, "a live prep did not read as a run in flight")

        var checking = calm; checking.keptToPrep = 5; checking.runInFlight = .reachabilityCheck
        var idle = calm; idle.keptToPrep = 5
        #expect(prep(checking).detail == prep(idle).detail,
                "a check still changes what the Prep pill says, so something still treats it as holding the slot")
        #expect(prep(checking).state == prep(idle).state)
    }
}

// #2614: the other surfaces that named the wrong run off the same boolean. The toolbar label
// (`prepToolbarLabel`) already got this right by reading `isProbeRunning`, and is the reference the rest
// follow rather than a second implementation.
@Suite("Every surface names the run that is actually going (#2614)")
struct EverySurfaceNamesTheRunTests {

    // The worst of the five: the sentence written specifically to answer "why can't I?", read from
    // inside the open menu where the toolbar's own correct label is not in view. During a check it said
    // "A prep run is already going", which is simply false.
    @Test func therefusalNamesTheRunThatIsActuallyHoldingTheSlot() {
        let duringACheck = PrepStartGate.reason(keptToPrep: 3, ownSlotRunInFlight: .reachabilityCheck)
        let duringAPrep = PrepStartGate.reason(keptToPrep: 3, ownSlotRunInFlight: .prep)

        #expect(duringACheck == "A reachability check is already going")
        #expect(duringAPrep == "A prep run is already going")
        #expect(duringACheck != duringAPrep)
    }

    // The other two branches are untouched: nothing running and nothing kept still says what to do about
    // it, and a run in flight is still named first when both are true.
    @Test func thegateStillRefusesForTheOtherReasons() {
        #expect(PrepStartGate.refusal(keptToPrep: 0, ownSlotRunInFlight: nil) == .nothingKept)
        #expect(PrepStartGate.refusal(keptToPrep: 0, ownSlotRunInFlight: .reachabilityCheck)
                == .runInFlight(.reachabilityCheck))
        #expect(PrepStartGate.refusal(keptToPrep: 3, ownSlotRunInFlight: nil) == nil)
        #expect(PrepStartGate.canStart(keptToPrep: 3, ownSlotRunInFlight: nil))
        #expect(!PrepStartGate.canStart(keptToPrep: 3, ownSlotRunInFlight: .reachabilityCheck))
    }

    // The stop control said "Cancel prep" while a check was running. It stops the right thing (one lock,
    // one runner, one cancel sentinel), so this was a naming defect, but it is the only stop control on
    // screen and it named the wrong run.
    @Test func thecancelItemNamesTheRunItWouldStop() {
        #expect(RunKind.prep.cancelLabel == "Cancel prep")
        #expect(RunKind.reachabilityCheck.cancelLabel == "Cancel reachability check")
    }

    // One vocabulary for what the run IS, so a sixth phrasing cannot appear beside the five that exist.
    @Test func thereIsOneNameForEachKindOfRun() {
        #expect(RunKind.prep.runNoun == "prep run")
        #expect(RunKind.reachabilityCheck.runNoun == "reachability check")
        for kind: RunKind in [.prep, .reachabilityCheck] {
            #expect(PrepStartGate.Refusal.runInFlight(kind).reason.contains(kind.runNoun))
            #expect(kind.cancelLabel.hasPrefix("Cancel"))
        }
    }
}
