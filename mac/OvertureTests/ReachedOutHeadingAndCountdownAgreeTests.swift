import Testing
import Foundation

// #3475: a Reached out row's date HEADING and its COUNTDOWN naming different days.
//
// Reported from a screenshot taken 2026-09-02 at 11:31 EDT: "Omari Banks" sat under a heading reading
// THU Sep 3 with the row beside it reading "in 2 days", which from Sep 2 is Sep 4. "String Theory"
// showed the same one day gap (heading FRI Sep 4, row "in 3 days"). The issue filed it as unconfirmed,
// with the first job being to confirm or dismiss it.
//
// CONFIRMED, and the cause is arithmetic rather than data. Both read the same `next`, and then answer
// "which day" two different ways:
//
//   the heading:   buckets `next` by its EASTERN CALENDAR DAY (`reachOutDateGroups`)
//   the countdown: `ceil(next.timeIntervalSince(now) / 86_400)` (`timingLabel`)
//
// A show due tomorrow at 6:00 PM is 30.5 hours away from 11:31 this morning, and 30.5 hours rounds up
// to "2 days" while the calendar says tomorrow. Both screenshot rows are exactly that: `next` on Sep 3
// at 6:00 PM reads "in 2 days" beside a heading saying Sep 3, and Sep 4 at 6:00 PM reads "in 3 days"
// beside Sep 4. Nothing about the dates is wrong; one of the two readings is not about calendar days
// at all (L16, L118).
//
// The right answer already exists three functions below it in the same file. `formNightLabel` counts
// whole Eastern calendar days through `EasternDate.daysUntil`, and its comment says why: "on the two
// clock-change days a day is 23 or 25 hours long, so raw division is a day out twice a year in the one
// line whose whole job is saying when (L39)". `timingLabel` is the sibling that never got it.
@Suite("A Reached out row's heading and its countdown name one day (#3475)")
struct ReachedOutHeadingAndCountdownAgreeTests {
    private func eastern(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi; c.second = 0
        return EasternDate.calendar.date(from: c)!
    }

    // The two rows from Dan's screenshot, with the clock he took it at.
    @Test func theTwoRowsFromTheScreenshotAgreeWithTheirHeadings() {
        let now = eastern(2026, 9, 2, 11, 31)
        #expect(ReachedOutQueue.timingLabel(next: eastern(2026, 9, 3, 18, 0), now: now) == "in 1 day")
        #expect(ReachedOutQueue.timingLabel(next: eastern(2026, 9, 4, 18, 0), now: now) == "in 2 days")
    }

    // The rule behind them, stated as itself: the countdown is the number of EASTERN CALENDAR DAYS
    // between today and the day the heading shows, whatever hour within that day the work falls on.
    // Asserted across the whole day so it cannot pass on the one hour that happens to divide evenly.
    @Test func theCountdownIsTheSameWhateverHourOfTheDayTheWorkFallsOn() {
        let now = eastern(2026, 9, 2, 11, 31)
        for hour in 0...23 {
            #expect(ReachedOutQueue.timingLabel(next: eastern(2026, 9, 3, hour, 0), now: now) == "in 1 day",
                    "a row due on Sep 3 at \(hour):00 sits under a Sep 3 heading whatever the hour")
        }
    }

    // The old arithmetic was not merely imprecise, it disagreed with the heading for most of the day,
    // which is what made it visible. Fewer than half the hours of a day divide the way it assumed, so a
    // test picking one hour could have passed against the defect (L101).
    @Test func theOldDivisionWouldHaveDisagreedForMostOfThatDay() {
        let now = eastern(2026, 9, 2, 11, 31)
        var wouldHaveDisagreed = 0
        for hour in 0...23 {
            let next = eastern(2026, 9, 3, hour, 0)
            let byDivision = Int((next.timeIntervalSince(now) / 86_400).rounded(.up))
            if byDivision != 1 { wouldHaveDisagreed += 1 }
        }
        #expect(wouldHaveDisagreed > 0, "if none disagreed there was never a defect to fix")
        #expect(wouldHaveDisagreed == 12)
    }

    // Already due is unchanged, and it is asserted here because a change to how the days are counted
    // is exactly the change that could turn "now" into "in 0 days" (L517).
    @Test func workAlreadyDueStillSaysSo() {
        let now = eastern(2026, 9, 2, 11, 31)
        #expect(ReachedOutQueue.timingLabel(next: eastern(2026, 9, 2, 11, 0), now: now) == "Reach out now")
        #expect(ReachedOutQueue.timingLabel(next: now, now: now) == "Reach out now")
        // Later TODAY is neither "now" nor "in 1 day". It sits under a heading reading today, so it has
        // to say today: this is the same defect as the screenshot's, at the near end.
        #expect(ReachedOutQueue.timingLabel(next: eastern(2026, 9, 2, 23, 0), now: now) == "today")
    }

    // And the decision wording still wins where it applies, since that branch is about WHAT is owed
    // rather than when.
    @Test func aRowAwaitingADecisionKeepsItsOwnWords() {
        let now = eastern(2026, 9, 2, 11, 31)
        #expect(ReachedOutQueue.timingLabel(next: eastern(2026, 9, 1, 18, 0), now: now,
                                            awaitingDecision: true) == ReachedOutQueue.decisionLabel)
    }

    // The clock-change day, which is the reason `formNightLabel` was written this way and the reason
    // this one now is. Eastern springs forward on 2027-03-14, so that day is 23 hours long: division
    // by 86,400 reads the day after it as closer than it is.
    @Test func aDayAcrossTheSpringClockChangeIsStillOneDay() {
        let beforeTheChange = eastern(2027, 3, 13, 20, 0)
        #expect(ReachedOutQueue.timingLabel(next: eastern(2027, 3, 14, 20, 0),
                                            now: beforeTheChange) == "in 1 day")
    }
}
