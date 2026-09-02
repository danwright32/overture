import Testing
import Foundation

// #1500: dismissing a whole night at once. Dan's words (2026-07-25): "I need a way to auto dismiss
// everything on one date. Like if I want to mark everything on a single date as 'Too soon', or in this
// case as 'Date conflict'."
//
// The rule and every sentence it says live here rather than in the date header, so what Dan reads before
// burying five shows is testable and shows up in the copy inventory (#915).
@Suite("Dismissing a whole night (#1500)")
struct BulkDismissTests {

    private func show(_ key: String, _ org: String, on date: String, runEnd: String? = nil) -> BulkDismiss.Show {
        BulkDismiss.Show(key: key, groupName: org, performanceDate: date, runEndDate: runEnd)
    }

    // MARK: - What the action would take

    // The unit is what is ON SCREEN in that group. The caller hands over the rows the stage is rendering,
    // so a filter or a search that narrows the night narrows the action with it: no silent "everything on
    // this date, including the rows you cannot see".
    @Test func itTakesEveryRowTheGroupIsShowing() {
        let plan = BulkDismiss.plan(for: [show("a", "The Music Shop", on: "2026-07-24"),
                                          show("b", "Orchestra of St Luke's", on: "2026-07-24")],
                                    on: "2026-07-24")

        #expect(plan.keys == ["a", "b"])
        #expect(plan.count == 2)
    }

    // A group with nothing in it has nothing to offer, so the caller can hide the action rather than
    // present a menu that would dismiss nothing.
    @Test func anEmptyGroupPlansNothing() {
        let plan = BulkDismiss.plan(for: [], on: "2026-07-24")

        #expect(plan.isEmpty)
        #expect(plan.count == 0)
    }

    // A multi-night run appears under EACH of its dates, so dismissing "Jul 24" takes a run that plays on
    // through Jul 31 with it: the row is one prospect, not one night. That is the surprise the confirmation
    // has to name, which is why the plan reports it rather than leaving the view to work it out.
    @Test func itNamesARunThatPlaysPastTheNight() {
        let plan = BulkDismiss.plan(for: [show("a", "The Music Shop", on: "2026-07-24"),
                                          show("b", "Hadestown", on: "2026-07-24", runEnd: "2026-07-31")],
                                    on: "2026-07-24")

        #expect(plan.keys == ["a", "b"])
        #expect(plan.runsPastTheNight == ["Hadestown"])
    }

    // A run whose closing night IS this night takes nothing else with it, so it must not be named: a
    // warning about dates Dan is not losing is noise that makes the real one easier to skip.
    @Test func aRunClosingOnTheNightIsNotNamed() {
        let plan = BulkDismiss.plan(for: [show("b", "Hadestown", on: "2026-07-24", runEnd: "2026-07-24")],
                                    on: "2026-07-24")

        #expect(plan.runsPastTheNight.isEmpty)
    }

    // Dan's second ask (2026-07-26, looking at a Jul 26 group of 12 where 4 were runs): dismiss the shows
    // that exist ONLY on this night, and leave the runs alone. So the plan carries that narrower set too,
    // rather than the view subtracting one list from the other.
    @Test func itSeparatesTheShowsThatOnlyPlayThisNight() {
        let plan = BulkDismiss.plan(for: [show("a", "The Music Shop", on: "2026-07-24"),
                                          show("b", "Hadestown", on: "2026-07-24", runEnd: "2026-07-31"),
                                          show("c", "Paulo Szot", on: "2026-07-24")],
                                    on: "2026-07-24")

        #expect(plan.keys == ["a", "b", "c"])
        #expect(plan.keysOnlyThisNight == ["a", "c"])
    }

    // The choice is only worth offering when both sides of it exist.
    @Test func anightWithNoRunsOffersNoChoice() {
        let plan = BulkDismiss.plan(for: [show("a", "The Music Shop", on: "2026-07-24")], on: "2026-07-24")

        #expect(plan.offersChoice(for: .notAFit) == false)
    }

    // The other empty side: when EVERY show on the night runs past it, "dismiss only the ones that play
    // just tonight" would dismiss nothing, so it must not be offered.
    @Test func anightOfNothingButRunsOffersNoChoice() {
        let plan = BulkDismiss.plan(for: [show("b", "Hadestown", on: "2026-07-24", runEnd: "2026-07-31"),
                                          show("c", "Shifters", on: "2026-07-24", runEnd: "2026-08-02")],
                                    on: "2026-07-24")

        #expect(plan.keysOnlyThisNight.isEmpty)
        #expect(plan.offersChoice(for: .notAFit) == false)
    }

    @Test func amixedNightOffersTheChoice() {
        let plan = BulkDismiss.plan(for: [show("a", "The Music Shop", on: "2026-07-24"),
                                          show("b", "Hadestown", on: "2026-07-24", runEnd: "2026-07-31")],
                                    on: "2026-07-24")

        // #3365: asked of a WHOLE-SHOW reason. A one-night reason offers no choice whatever the night
        // holds, which `BulkDismissOneNightChoiceTests` covers.
        #expect(plan.offersChoice(for: .notAFit))
    }

    // MARK: - What Dan reads before it happens

    // The menu is opened by right-clicking a date, so the menu itself has to say what the action is and
    // how much of the night it covers. A bare list of reasons under a right-click says neither.
    @Test func theMenuNamesTheCountAndTheNight() {
        #expect(BulkDismiss.menuTitle(count: 5, dateLabel: "Jul 24") == "Dismiss all 5 shows on Jul 24")
    }

    // One show is not "all 5 shows", and "all 1 show" is not English.
    @Test func theMenuReadsNaturallyForASingleShow() {
        #expect(BulkDismiss.menuTitle(count: 1, dateLabel: "Jul 24") == "Dismiss the show on Jul 24")
    }

    // The count again, on the confirm itself: this is the last thing Dan sees before several shows leave
    // the queue at once, and the issue's requirement is that it states exactly how many.
    @Test func theConfirmAsksAboutTheCountAndTheNight() {
        #expect(BulkDismiss.confirmTitle(count: 5, dateLabel: "Jul 24") == "Dismiss all 5 shows on Jul 24?")
        #expect(BulkDismiss.confirmTitle(count: 1, dateLabel: "Jul 24") == "Dismiss the show on Jul 24?")
    }

    // The reason is chosen, never assumed, so the confirm names the one that is about to be written to
    // every row. Bulk dismissal is exactly where a wrong reason gets applied to many shows at once.
    @Test func theConfirmNamesTheReasonEveryRowWillCarry() {
        let message = BulkDismiss.confirmMessage(count: 5, reason: .tooSoon, runs: [], dateLabel: "Jul 24")

        #expect(message.contains("Too soon"))
        #expect(!message.contains("runs past"))
    }

    // The run warning, in the words of the show Dan is about to lose later dates for.
    //
    // #3365: asked of a WHOLE-SHOW reason. Under `.dateConflict`, which is what this used to pass, the
    // sentence was simply false: that reason drops the night and the run comes back under its next one.
    @Test func theConfirmSaysWhichRunLosesItsLaterNights() {
        let message = BulkDismiss.confirmMessage(count: 2, reason: .notAFit,
                                                 runs: ["Hadestown"], dateLabel: "Jul 24")

        #expect(message.contains("Hadestown runs past Jul 24, so dismissing it takes its later nights too."))
    }

    // Two runs read as a list, with the verb agreeing, rather than the same sentence stamped twice.
    @Test func twoRunsAreNamedInOneSentence() {
        let message = BulkDismiss.confirmMessage(count: 3, reason: .notAFit,
                                                 runs: ["Hadestown", "The Music Shop"], dateLabel: "Jul 24")

        #expect(message.contains(
            "Hadestown and The Music Shop run past Jul 24, so dismissing them takes their later nights too."))
    }

    // The button says what it does to what: a bare "OK" on a destructive batch is exactly the control
    // Dan would click without reading the title above it.
    @Test func theProceedButtonAgreesWithTheCount() {
        #expect(BulkDismiss.confirmProceed(count: 5, offeringChoice: false) == "Dismiss them")
        #expect(BulkDismiss.confirmProceed(count: 1, offeringChoice: false) == "Dismiss it")
    }

    // With a second button beside it, "Dismiss them" is ambiguous about which them. Both buttons name
    // their own number, so the pair reads as a choice rather than as one button and an escape hatch.
    @Test func withAChoiceOnOfferBothButtonsNameTheirCount() {
        #expect(BulkDismiss.confirmProceed(count: 12, offeringChoice: true) == "Dismiss all 12")
        #expect(BulkDismiss.confirmProceedOnlyThisNight(count: 8) == "Dismiss only the 8")
    }

    @Test func theNarrowerButtonReadsNaturallyForOneShow() {
        #expect(BulkDismiss.confirmProceedOnlyThisNight(count: 1) == "Dismiss only that one")
    }

    // With two ways forward, the message must not pre-commit to one of them. "They all leave your queue"
    // above a button that deliberately leaves the runs behind describes an outcome Dan is still choosing.
    //
    // #3365: asked of a WHOLE-SHOW reason. A one-night reason no longer offers a choice at all (Dan,
    // 2026-09-02), so `offeringChoice: true` beside `.tooSoon` is a state the app cannot reach.
    @Test func withAChoiceOnOfferTheMessageDoesNotPreCommit() {
        let message = BulkDismiss.confirmMessage(count: 12, reason: .notAFit, runs: ["Shifters"],
                                                 dateLabel: "Jul 26", offeringChoice: true)

        #expect(message.hasPrefix("Filed as Not a fit either way."))
        #expect(!message.contains("They all leave"))
        #expect(message.contains("Shifters runs past Jul 26"))
    }

    // A night of nothing BUT runs has no choice to offer, so it still says plainly what will happen.
    // #3365: under a whole-show reason, which is the one that still takes the run.
    @Test func withNoChoiceTheMessageStillStatesTheOutcome() {
        let message = BulkDismiss.confirmMessage(count: 3, reason: .notAFit, runs: ["Shifters"],
                                                 dateLabel: "Jul 26", offeringChoice: false)

        #expect(message.hasPrefix("They all leave your queue, filed as Not a fit."))
    }

    // MARK: - What one Cmd+Z will offer to reverse

    // The Edit menu title for the batch entry. It names the night rather than one show's org, because a
    // press that brings five shows back must not read as a press that brings one back.
    @Test func theUndoLabelNamesTheNightNotOneShow() {
        #expect(BulkDismiss.undoLabel(count: 5, dateLabel: "Jul 24") == "5 shows on Jul 24")
        #expect(BulkDismiss.undoLabel(count: 1, dateLabel: "Jul 24") == "1 show on Jul 24")
    }
}
