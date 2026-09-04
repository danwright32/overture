import Testing
import Foundation

// #3422: when a reply triage task is DUE.
//
// It used to be a fixed 6:00 PM Eastern on the Eastern day the reply arrived, so the arrival time was
// discarded and every reply arriving after 6:00 PM produced a task that was already overdue the
// moment it was created. Measured 2026-08-31 from Dan's own OmniFocus: a task created at 10:12 PM
// showing a due of 6:00 PM in red, seven hours past, on work nobody could have done because the task
// did not exist yet. Evening is when he is away from his desk reading OmniFocus rather than the app,
// which is the whole reason #271 put the task there.
//
// Every fixture here pins BOTH the arrival and the expected due as literals, so real time cannot walk
// an arrival into a different band and leave the test asserting about a case nobody chose (L130).
@Suite("Reply triage due (#3422)")
struct ReplyTriageDueTests {
    private func eastern(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi; c.second = 0
        return EasternDate.calendar.date(from: c)!
    }

    // Dan's own example, from the OmniFocus screenshot in the issue.
    @Test func theTenTwelvePmReplyFromTheIssueBecomesNineTheNextMorning() {
        let due = ReplyTriageDue.due(replyArrivedAt: eastern(2026, 8, 31, 22, 12))
        #expect(due == eastern(2026, 9, 1, 9, 0))
    }

    // The three bands. 7:00 AM exactly takes the four hour band and 11:00 PM exactly takes the twelve
    // hour one: both boundaries were decided rather than measured (#3422), so they are pinned here
    // where a change to either is visible rather than left to be inferred from a comparison operator.
    @Test func aDaytimeReplyIsDueFourHoursLater() {
        #expect(ReplyTriageDue.due(replyArrivedAt: eastern(2026, 8, 31, 14, 0)) == eastern(2026, 8, 31, 18, 0))
    }

    @Test func sevenInTheMorningExactlyTakesTheFourHourBand() {
        #expect(ReplyTriageDue.due(replyArrivedAt: eastern(2026, 8, 31, 7, 0)) == eastern(2026, 8, 31, 11, 0))
    }

    @Test func aReplyBeforeSevenAmIsDueNineHoursLater() {
        #expect(ReplyTriageDue.due(replyArrivedAt: eastern(2026, 8, 31, 6, 59)) == eastern(2026, 8, 31, 16, 0))
    }

    @Test func elevenAtNightExactlyTakesTheTwelveHourBand() {
        #expect(ReplyTriageDue.due(replyArrivedAt: eastern(2026, 8, 31, 23, 0)) == eastern(2026, 9, 1, 11, 0))
    }

    // Rounding to the nearest hour, with the half hour going up. Stated as a pair either side of the
    // boundary, because a rule about a boundary that only tests one side of it says nothing about
    // where the boundary is.
    @Test func twentyNineMinutesPastRoundsDownAndThirtyRoundsUp() {
        #expect(ReplyTriageDue.due(replyArrivedAt: eastern(2026, 8, 31, 13, 29)) == eastern(2026, 8, 31, 17, 0))
        #expect(ReplyTriageDue.due(replyArrivedAt: eastern(2026, 8, 31, 13, 30)) == eastern(2026, 8, 31, 18, 0))
    }

    // The step #3422 names so it is not met as a surprise: 7:29 PM is due the same evening, 7:30 PM
    // rounds up past midnight and is therefore pushed to the morning floor.
    @Test func theEveningStepFallsExactlyWhereTheIssueSaysItDoes() {
        #expect(ReplyTriageDue.due(replyArrivedAt: eastern(2026, 8, 31, 19, 29)) == eastern(2026, 8, 31, 23, 0))
        #expect(ReplyTriageDue.due(replyArrivedAt: eastern(2026, 8, 31, 19, 30)) == eastern(2026, 9, 1, 9, 0))
    }

    // The morning floor. Without it the four hour band ran to 11:00 PM, so every reply after roughly
    // 7:00 PM was due overnight, which is a deadline nobody is awake for.
    @Test func aDeadlineLandingOvernightMovesToNineThatMorning() {
        #expect(ReplyTriageDue.due(replyArrivedAt: eastern(2026, 8, 31, 21, 0)) == eastern(2026, 9, 1, 9, 0))
        // Midnight arrives in the before-seven band and lands on 9:00 AM by arithmetic alone, which is
        // what the floor was made to mirror.
        #expect(ReplyTriageDue.due(replyArrivedAt: eastern(2026, 8, 31, 0, 0)) == eastern(2026, 8, 31, 9, 0))
    }

    // Seven exactly is NOT overnight: the floor covers midnight up to 7:00 AM, and a rule stated as a
    // range has to say which end is closed or the boundary is whatever the operator happened to be.
    @Test func sevenAmIsNotItselfOvernightAndIsLeftWhereItLands() {
        // 10:00 PM plus nine... no: 10:00 PM is the four hour band, giving 2:00 AM, which the floor
        // moves. An arrival whose result IS 7:00 AM comes from the before-seven band.
        #expect(ReplyTriageDue.due(replyArrivedAt: eastern(2026, 8, 31, 22, 0)) == eastern(2026, 9, 1, 9, 0))
        #expect(ReplyTriageDue.due(replyArrivedAt: eastern(2026, 8, 31, 5, 0)) == eastern(2026, 8, 31, 14, 0))
    }

    // #3422's own second blocker: the task must never be hidden past its own deadline, or the same
    // defect survives in a narrower window and looks exactly the same to Dan.
    @Test func theTaskIsNeverHiddenPastItsOwnDeadline() {
        for hour in 0...23 {
            for minute in [0, 12, 29, 30, 45] {
                let due = ReplyTriageDue.due(replyArrivedAt: eastern(2026, 8, 31, hour, minute))
                #expect(ReplyTriageDue.surfacesAt(due: due) <= due,
                        "a reply at \(hour):\(minute) surfaced after it was already due")
            }
        }
    }

    // And it still surfaces at the ordinary hour where that is in time, rather than every task
    // arriving the moment it is created: the defer is what keeps OmniFocus quiet until a task matters.
    @Test func anAfternoonDeadlineStillSurfacesAtTheOrdinaryMorningHour() {
        let due = ReplyTriageDue.due(replyArrivedAt: eastern(2026, 8, 31, 14, 0))   // 6:00 PM
        #expect(ReplyTriageDue.surfacesAt(due: due) == eastern(2026, 8, 31, 11, 0))
    }
}
