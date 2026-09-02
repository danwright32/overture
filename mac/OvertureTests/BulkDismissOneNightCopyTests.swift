import Testing
import Foundation

// #3365. Dan, 2026-08-30, on a screenshot of the Sep 18 sheet: "I don't think this is true anymore?
// Dismissing them doesn't take their later date?"
//
// He was right, and both sentences were false. #2691 made four dismiss reasons statements about ONE NIGHT:
// `ProspectMutations.dismissAll` calls `dropNight` for those, so a run loses that night and comes back
// under its next one. Nothing leaves the queue and no later night is taken. The AFTER-the-fact
// acknowledgements were updated by #2691 and #2997; the BEFORE-the-fact sheet still described the old
// behaviour, because `confirmMessage` received the reason and used it only for the "filed as" clause.
@Suite("The bulk dismiss sheet describes what a one-night reason really does (#3365)")
struct BulkDismissOneNightCopyTests {
    // The exact sheet Dan screenshotted: three shows on Sep 18, all three of them runs that play on.
    private let runs = ["Tiffany in Spandex the Musical", "Louis Katz: Conflicted", "Lost in Del Valle"]

    // THE DEFECT, both halves of it. Under a one-night reason the runs keep their later nights, and the
    // shows that play on do not leave the queue at all.
    @Test func aOneNightReasonOnRunsOnlySaysNoneOfThemLeaves() {
        let message = BulkDismiss.confirmMessage(count: 3, reason: .dateConflict, runs: runs,
                                                 dateLabel: "Sep 18")
        #expect(message == """
        They all lose Sep 18, filed as Date conflict, and turn up again under their next night.
        """)
    }

    // The MIXED night, which is the one an all-or-nothing sentence gets wrong in the other direction: the
    // runs come back, and the shows that played only Sep 18 really do leave. Both halves are said, because
    // a sentence true of the runs alone leaves him guessing about the rest.
    @Test func aMixedNightSaysWhatHappensToBothKinds() {
        let message = BulkDismiss.confirmMessage(count: 5, reason: .dateConflict, runs: runs,
                                                 dateLabel: "Sep 18")
        #expect(message == """
        They lose Sep 18, filed as Date conflict. Tiffany in Spandex the Musical, Louis Katz: Conflicted \
        and Lost in Del Valle play on past Sep 18 and turn up again under their next night; the rest \
        leave your queue.
        """)
    }

    // A whole-show reason is UNCHANGED. It is what the old sentence was written for, and it is still true
    // of `Not a fit`, `Don't want to shoot this`, `Duplicate` and `No way to reach them`.
    @Test func aWholeShowReasonStillSaysTheyLeaveTheQueue() {
        let message = BulkDismiss.confirmMessage(count: 3, reason: .notAFit, runs: runs, dateLabel: "Sep 18")
        #expect(message == """
        They all leave your queue, filed as Not a fit. Tiffany in Spandex the Musical, Louis Katz: \
        Conflicted and Lost in Del Valle run past Sep 18, so dismissing them takes their later nights too.
        """)
    }

    // One show, one night reason, and it is not a run: it really does leave, so say so.
    @Test func aShowThatPlaysOnlyThisNightLeavesUnderEitherKindOfReason() {
        #expect(BulkDismiss.confirmMessage(count: 1, reason: .dateConflict, runs: [], dateLabel: "Sep 18")
                == "It leaves your queue, filed as Date conflict.")
        #expect(BulkDismiss.confirmMessage(count: 1, reason: .notAFit, runs: [], dateLabel: "Sep 18")
                == "It leaves your queue, filed as Not a fit.")
    }

    // Several shows, none of them a run: every one leaves whatever the reason, because there is no later
    // night for any of them to come back on.
    @Test func severalShowsThatAllPlayOnlyThisNightAllLeave() {
        #expect(BulkDismiss.confirmMessage(count: 3, reason: .dateConflict, runs: [], dateLabel: "Sep 18")
                == "They all leave your queue, filed as Date conflict.")
    }

    // One run among them, so the singular note is the one that has to be right too.
    @Test func oneRunAmongThemReadsInTheSingular() {
        #expect(BulkDismiss.confirmMessage(count: 2, reason: .tooSoon, runs: ["Lost in Del Valle"],
                                           dateLabel: "Sep 18")
                == """
                They lose Sep 18, filed as Too soon. Lost in Del Valle plays on past Sep 18 and turns up \
                again under its next night; the other one leaves your queue.
                """)
    }

    // Every one-night reason gets the one-night wording, derived from `RunNightDrop.aboutOneNight` rather
    // than from a list here, so a fifth reason joining that set cannot keep the wrong sentence (L96).
    @Test func everyOneNightReasonGetsTheOneNightWording() {
        for reason in RunNightDrop.aboutOneNight {
            let message = BulkDismiss.confirmMessage(count: 2, reason: reason, runs: ["A Run"],
                                                     dateLabel: "Sep 18")
            #expect(message.contains("turns up again under its next night"),
                    "\(reason) is a one-night reason but its sheet still describes a whole-run dismissal")
            #expect(!message.contains("leave your queue"),
                    "\(reason) is a one-night reason but its sheet says the shows leave the queue")
        }
    }

    // ...and every whole-show reason keeps the old one, so the rule above cannot be satisfied by giving
    // every reason the new sentence.
    @Test func everyWholeShowReasonKeepsTheOldWording() {
        for reason in RunNightDrop.aboutTheShow {
            let message = BulkDismiss.confirmMessage(count: 2, reason: reason, runs: ["A Run"],
                                                     dateLabel: "Sep 18")
            #expect(message.contains("takes its later nights too"),
                    "\(reason) takes the whole show but its sheet no longer says so")
        }
    }
}

// Dan's call, 2026-09-02 (this session, in chat): under a one-night reason the second button goes.
//
// It exists to let him clear a night without costing a run its later nights. Under a one-night reason no
// later night is at stake, so the two buttons differ only in whether the runs lose THIS night, and having
// just said he cannot shoot anything on it, offering to leave some of them holding it invites a choice
// that contradicts the reason he gave.
@Suite("A one-night reason offers one way forward (#3365)")
struct BulkDismissOneNightChoiceTests {
    private func show(_ key: String, runsPast: Bool) -> BulkDismiss.Show {
        BulkDismiss.Show(key: key, groupName: key, performanceDate: "2026-09-18",
                         runEndDate: runsPast ? "2026-09-25" : nil)
    }

    @Test func aOneNightReasonOffersNoChoiceEvenWithBothKindsOfShowOnTheNight() {
        let plan = BulkDismiss.plan(for: [show("run", runsPast: true), show("single", runsPast: false)],
                                    on: "2026-09-18")
        #expect(plan.offersChoice(for: .dateConflict) == false)
    }

    // The whole-show reasons keep it, which is what it was built for.
    @Test func aWholeShowReasonStillOffersTheNarrowerWayOut() {
        let plan = BulkDismiss.plan(for: [show("run", runsPast: true), show("single", runsPast: false)],
                                    on: "2026-09-18")
        #expect(plan.offersChoice(for: .notAFit))
    }

    // The two conditions that made it pointless before are unchanged: with no runs both buttons do the
    // same thing, and with nothing but runs the narrower one dismisses nothing at all.
    @Test func theOldReasonsToWithholdTheChoiceStillHold() {
        let allRuns = BulkDismiss.plan(for: [show("a", runsPast: true), show("b", runsPast: true)],
                                       on: "2026-09-18")
        let noRuns = BulkDismiss.plan(for: [show("a", runsPast: false), show("b", runsPast: false)],
                                      on: "2026-09-18")
        #expect(allRuns.offersChoice(for: .notAFit) == false)
        #expect(noRuns.offersChoice(for: .notAFit) == false)
    }
}

// The rule had TWO copies: `BulkDismiss.Plan.offersChoice` and a restatement inside QueueView's own
// snapshot of the plan. They agreed until the rule gained a condition, which is exactly when two copies
// stop agreeing (#863), and the sheet's sentence and the buttons under it are what would have disagreed.
@Suite("There is one rule about whether the night offers a choice (#3365)")
struct BulkDismissChoiceIsOneRuleTests {
    @Test func theViewAsksBulkDismissRatherThanRestatingIt() {
        let view = SourceGuardHelper.source("Overture/UI/QueueView.swift")
        #expect(view.contains("BulkDismiss.offersChoice(reason: reason"))
        // The old shape, restated inline. Its absence is the guard.
        #expect(!view.contains("!runs.isEmpty && !keysOnlyThisNight.isEmpty"))
    }
}
