import Testing
import Foundation

// #2169. Dan, reading the Alex Syiek row cold on 2026-08-05: "why does it say 'no contact' and 'sent
// through their form'. Also, it says 1 day. what happens in 1 days?"
//
// Both questions are the row failing to describe a contact-form pitch, and they are separate faults.
//
// PART 1. The contact slot said "no contact" while the line beneath said a pitch went through their
// form. Not merely confusing: untrue, and disproved by data on the very same record, which holds the
// form URL it was sent to (L11). The slot names WHERE the pitch went, so the two lines agree.
//
// PART 2. "in 1 day" borrowed the wording from email rows, where it genuinely means a nudge is coming.
// On a form row nothing will ever be sent and Overture cannot see a reply, so it promised something that
// could not happen.
//
// Dan's rule, 2026-08-06: "it should put it as due as if it's due for a follow up but then just tell me
// it's due to set a state. The due date should actually just be the date of the event since I won't send
// a follow up if it's a form." So the clock is the NIGHT, which is also the moment the question becomes
// answerable: before it he has nothing to report, and after it he knows.
//
// The timing slot then names the night, and the state control beside it says the action, because "Say
// what happened" next to a control reading "Set a state" is one instruction printed twice (#2168, #843).
@Suite("A form row says where it went and when the night is (#2169)")
struct FormRowSaysWhatItMeansTests {

    // MARK: part 1, where the pitch went

    @Test func theContactSlotNamesTheSiteItWasSentTo() {
        #expect(FormOutreachCopy.routeLine(formURL: "https://www.alexsyiek.com/contact") == "alexsyiek.com")
        #expect(FormOutreachCopy.routeLine(formURL: "https://jerrickcavagnaro.com/appointments")
                == "jerrickcavagnaro.com")
        #expect(FormOutreachCopy.routeLine(formURL: "https://www.reevecarney.com/booking")
                == "reevecarney.com")
    }

    // The failure path. A record with no usable route gets nothing rather than a plausible-looking
    // fragment, so the caller has to decide what to say instead of being handed a wrong answer.
    @Test func anUnusableFormURLNamesNothing() {
        #expect(FormOutreachCopy.routeLine(formURL: nil) == nil)
        #expect(FormOutreachCopy.routeLine(formURL: "") == nil)
        #expect(FormOutreachCopy.routeLine(formURL: "not a url at all") == nil)
    }

    // MARK: part 2, when the night is

    private let today = "2026-08-06"

    @Test func theNightItselfReadsAsTonight() {
        #expect(ReachedOutQueue.formNightLabel(eventDay: "2026-08-06", today: today) == "tonight")
    }

    @Test func aNightStillAheadCountsDownToIt() {
        #expect(ReachedOutQueue.formNightLabel(eventDay: "2026-08-07", today: today) == "in 1 day")
        #expect(ReachedOutQueue.formNightLabel(eventDay: "2026-08-10", today: today) == "in 4 days")
    }

    // The live case that started this. Alex Syiek's night was 3 August and Dan was reading the row on
    // the 6th, so the row has to say the night has gone rather than count down to a send.
    @Test func aNightThatHasGoneSaysHowLongAgo() {
        #expect(ReachedOutQueue.formNightLabel(eventDay: "2026-08-05", today: today) == "yesterday")
        #expect(ReachedOutQueue.formNightLabel(eventDay: "2026-08-03", today: today) == "3 days ago")
    }

    // Counted in whole Eastern calendar days through the one shared helper, never by dividing an
    // interval by 24 hours. On the two clock-change days a day is 23 or 25 hours long, so raw division
    // puts the label a day out twice a year, in the one line whose whole job is saying when (L39).
    @Test func theCountIsCalendarDaysAcrossAClockChange() {
        // 1 November 2026 is the Sunday the clocks go back in New York, so 31 Oct to 1 Nov is a
        // 25-hour day and 1 Nov to 2 Nov is 24.
        #expect(ReachedOutQueue.formNightLabel(eventDay: "2026-11-01", today: "2026-10-31") == "in 1 day")
        #expect(ReachedOutQueue.formNightLabel(eventDay: "2026-11-02", today: "2026-11-01") == "in 1 day")
        #expect(ReachedOutQueue.formNightLabel(eventDay: "2026-10-31", today: "2026-11-01") == "yesterday")
    }

    // An undated show must still say something rather than render a gap, and must never invent a night.
    @Test func aShowWithNoDateSaysSoRatherThanGuessing() {
        #expect(ReachedOutQueue.formNightLabel(eventDay: nil, today: today) == "date unknown")
        #expect(ReachedOutQueue.formNightLabel(eventDay: "not a date", today: today) == "date unknown")
    }

    // MARK: the clock itself

    @Test func theFormClockIsTheNightNotSixDaysAfterThePitch() throws {
        let night = try #require(EasternDate.date(from: "2026-08-07"))
        #expect(ReachedOutQueue.formDecisionDate(eventDay: "2026-08-07") == night)
    }

    // Due from the night itself, not the morning after: Dan knows by the evening whether he shot it,
    // and a row that waits until tomorrow to ask is a row he has already stopped thinking about.
    @Test func theRowIsDueOnTheNight() throws {
        let night = try #require(ReachedOutQueue.formDecisionDate(eventDay: "2026-08-06"))
        let duringThatDay = try #require(EasternDate.date(from: "2026-08-06"))
            .addingTimeInterval(20 * 3_600)
        #expect(ReachedOutQueue.isDueNow(next: night, now: duringThatDay))
    }

    // A show with no date has no night to wait for. It must NOT fall out of the queue, because a record
    // that matches no view is gone from the product while still in the data (L45), so the caller keeps
    // its old pitched-plus-gap clock rather than getting nil here.
    @Test func anUndatedShowHasNoNightClock() {
        #expect(ReachedOutQueue.formDecisionDate(eventDay: nil) == nil)
        #expect(ReachedOutQueue.formDecisionDate(eventDay: "") == nil)
    }
}
