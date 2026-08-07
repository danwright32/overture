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

    // Gold means "Dan can act on this" throughout the app, and #2166's scope note says the urgent colour
    // must not collide with that meaning. Pinned so a later tidy-up cannot reach for gold here.
    @Test func theAnswerControlNeverUsesGold() {
        for dueNow in [true, false] {
            #expect(ReachedOutRowChrome.answerFill(dueNow: dueNow) != OVColor.gold)
            #expect(ReachedOutRowChrome.answerFill(dueNow: dueNow) != OVColor.goldBright)
        }
    }
}
