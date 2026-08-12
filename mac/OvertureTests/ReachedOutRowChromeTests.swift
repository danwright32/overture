import Testing
import Foundation
import SwiftUI

// #2166. Reported by Dan from a live Reached out row, 2026-08-05: the row stacked "Reach out now"
// directly above an Answer button, two things saying one thing. The button's existence already means
// now, because it is only offered when somebody is waiting.
//
// His instruction was specific: drop the label on rows that offer Answer, and carry the urgency on the
// button's own colour, so one control says the whole thing.
//
// These decisions live out here rather than inside the view body, because logic inside a SwiftUI view
// is not testable and this is exactly the kind of rule that gets quietly inverted by an unrelated edit.
@Suite("What the reached-out row's trailing column shows (#2166)")
struct ReachedOutRowChromeTests {

    // The rule Dan asked for.
    @Test func aRowOfferingAnswerDropsTheTimingLabel() {
        #expect(ReachedOutRowChrome.showsTimingLabel(replyOffered: true) == false)
    }

    // And the half that is NOT redundant. On a row with nobody waiting, the timing label is the only
    // thing saying when the next touch is due, and it also renders the future case ("in N days"). The
    // fix is a suppression, never a deletion.
    @Test func aRowWithNobodyWaitingStillSaysWhen() {
        #expect(ReachedOutRowChrome.showsTimingLabel(replyOffered: false))
    }

    // The urgency has to land somewhere, or dropping the label loses the signal rather than moving it.
    @Test func theAnswerControlCarriesTheUrgencyWhenSomethingIsDue() {
        #expect(ReachedOutRowChrome.answerFill(dueNow: true) == OVColor.rust)
        #expect(ReachedOutRowChrome.answerFill(dueNow: false) == OVColor.forest)
    }

    // The accessibility trap #1527 already paid for: the warm fills are light enough in dark mode that
    // white text washes out on them, which is why onRust exists and puts near-black warm ink there
    // instead. A warm fill wearing the white-on-forest label would ship an unreadable control in dark
    // mode and look perfectly fine in light, so it is pinned rather than left to whoever edits next.
    @Test func aWarmFillNeverWearsTheLabelMeantForForest() {
        for dueNow in [true, false] {
            let fill = ReachedOutRowChrome.answerFill(dueNow: dueNow)
            let label = ReachedOutRowChrome.answerLabel(dueNow: dueNow)
            if fill == OVColor.rust {
                #expect(label == OVColor.onRust, "a rust fill must take onRust, never the forest label")
            } else {
                #expect(label == OVColor.onForest)
            }
        }
    }

    // #2169. On a form row the timing slot names the night ("tonight", "3 days ago") rather than
    // repeating the instruction the control beside it already gives, so the urgency has to ride on the
    // control or it is lost. Same move as #2166 made for Answer: the signal follows the thing you press.
    @Test func theStateControlCarriesTheUrgencyOnceTheNightHasCome() {
        #expect(ReachedOutRowChrome.stateControlAccent(isDue: true) == OVColor.rust)
        #expect(ReachedOutRowChrome.stateControlAccent(isDue: false) == nil)
    }

    // Nil rather than a quiet colour, because nil is what the control already treats as "no accent".
    // Handing it inkSoft would tint every state control in the app on a row that is simply not due yet.
    @Test func aRowNotYetDueTintsNothing() {
        #expect(ReachedOutRowChrome.stateControlAccent(isDue: false) == nil)
    }

    // Gold means "Dan can act on this" throughout the app, and #2166's scope note says the urgent colour
    // must not collide with that meaning. Pinned so a later tidy-up cannot reach for gold here.
    @Test func theAnswerControlNeverUsesGold() {
        for dueNow in [true, false] {
            #expect(ReachedOutRowChrome.answerFill(dueNow: dueNow) != OVColor.gold)
            #expect(ReachedOutRowChrome.answerFill(dueNow: dueNow) != OVColor.goldBright)
        }
    }

    // MARK: the show's own date (#2551)

    // Dan, reading a live row on 2026-08-11: "it doesn't give me any indication of when the show is, just
    // when to reach out. Both are needed I think". The date HEADINGS on this stage are reach-out dates
    // (#1233's caption says so), so the show's own date was nowhere on the screen at all, and on the row he
    // was reading the two happened to be the same day with no way to tell.
    @Test func theRowNamesTheNightTheShowIsOn() {
        #expect(ReachedOutRowChrome.showDateLine(performanceDate: "2026-08-11", runEndDate: nil)
                == "Performs Aug 11")
    }

    // A run reads as the window it occupies, through the same helper the queue card uses, so the two
    // surfaces cannot describe one run in two different words (#843).
    @Test func aRunReadsAsItsWindow() {
        #expect(ReachedOutRowChrome.showDateLine(performanceDate: "2026-08-11", runEndDate: "2026-08-14")
                == "Performs Aug 11 to 14")
        #expect(ReachedOutRowChrome.showDateLine(performanceDate: "2026-06-28", runEndDate: "2026-07-02")
                == "Performs Jun 28 to Jul 2")
        // A closing night equal to the opening one is a single night, not a window.
        #expect(ReachedOutRowChrome.showDateLine(performanceDate: "2026-08-11", runEndDate: "2026-08-11")
                == "Performs Aug 11")
    }

    // "Date to be confirmed" is a normal state on a season page, so the row says so rather than inventing a
    // night or going silent (L11). It names the SHOW's date, because the headings above it are reach-out
    // dates and a bare "date to be confirmed" here would read as the wrong one being unknown.
    @Test func anUndatedShowSaysSoRatherThanInventingANight() {
        #expect(ReachedOutRowChrome.showDateLine(performanceDate: nil, runEndDate: nil)
                == "Show date to be confirmed")
        #expect(ReachedOutRowChrome.showDateLine(performanceDate: "", runEndDate: nil)
                == "Show date to be confirmed")
        #expect(ReachedOutRowChrome.showDateLine(performanceDate: "not a date", runEndDate: nil)
                == "Show date to be confirmed")
    }

    // The line has to be able to sit beside the timing slot without the two collapsing into one sentence
    // (#843, and the cold read AGENTS.md demands before the PR). The date line is ABSOLUTE and the timing
    // slot is RELATIVE, and neither may start saying the other's half.
    @Test func theDateLineNeverRepeatsTheTimingSlot() {
        let timingWords = ["Reach out now", "in 1 day", "in 5 days", "tonight", "yesterday",
                           ReachedOutQueue.heldOpenLabel]
        for date in [("2026-08-11", nil as String?), ("2026-08-11", "2026-08-14"), (nil as String?, nil)]
            .map({ ReachedOutRowChrome.showDateLine(performanceDate: $0.0, runEndDate: $0.1) }) {
            for word in timingWords {
                #expect(date != word, "the date line and the timing slot rendered the same sentence")
            }
        }
    }

    // Built is not wired (L3). The row's LEADING column has to actually draw it, or the helper above is a
    // sentence the app never says.
    @Test func theRowActuallyDrawsIt() throws {
        let source = SourceGuardHelper.source("Overture/UI/QueueView.swift")
        let body = try String(SourceGuard.functionBody(named: "reachedOutRow", in: source))
        let leading = try #require(
            SourceGuardHelper.between("VStack(alignment: .leading, spacing: 3) {",
                                      and: "Spacer(minLength: OVSpacing.sm)", in: body))
        #expect(leading.contains("ReachedOutRowChrome.showDateLine"),
                "the reached-out row's leading column does not draw the show's date")
    }
}
