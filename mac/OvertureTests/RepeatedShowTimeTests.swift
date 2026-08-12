import Testing
import Foundation

// #2376. A queue card for a show whose venue sells two separate ticketed performances at the SAME
// listed curtain time read its start time twice: "7:00 PM and 7:00 PM".
//
// Measured on real live feed bytes, fetched read only on 2026-08-09: La MaMa's OvationTix feed
// (ci.ovationtix.com/42) lists `Tawasol` on 2026-09-05 as performanceIds 11851048 and 11851049, both
// at `2026-09-05 19:00`. Two genuinely distinct ticketed performances, one stated time. Of 115 parsed
// nights, 8 carry two or more start times, and exactly 1 of those 8 is this duplicate shape; the other
// 7 are real double bills such as a 5:00 PM and a 9:15 PM, which are correct and must keep both.
//
// It never changes which shows surface, who gets pitched, or what any outbound email says. It is
// wording, and it reads as a glitch rather than as information.
//
// Fixed at the shared render boundary rather than in the one adapter that can produce it today:
// `OvationTixCalendar` is the only reader that builds a multi-entry `startTimes` list, but any future
// adapter that lists a day's performances would inherit the same defect (L30). `VenueTixCalendar`
// emits exactly one time per row and cannot.
@Suite("A repeated show time is said once (#2376)")
struct RepeatedShowTimeTests {
    // #2376: two separately ticketed performances at the SAME listed curtain time read as "7:00 PM and
    // 7:00 PM". Measured on real La MaMa OvationTix bytes on 2026-08-09: `Tawasol` on 2026-09-05 lists
    // performanceIds 11851048 and 11851049, both at `2026-09-05 19:00`, and 1 of the 8 multi-time nights
    // in that feed is this shape.
    //
    // De-duplicated HERE, where the times become a sentence, rather than in the one adapter that can
    // produce it today, so every present and future producer of a times list is covered at once (L30).
    @Test func twoPerformancesAtOneTimeSayThatTimeOnce() {
        #expect(ClockTime.listLabel(["19:00", "19:00"]) == "7:00 PM")
        #expect(ClockTime.listLabel(["19:00", "19:00", "19:00"]) == "7:00 PM")
    }

    // The bug is repetition, not plurality: a genuine double bill must keep both of its distinct times,
    // and the de-duplication must not reorder what is left. Feed order is what the card shows.
    @Test func aRealDoubleBillKeepsBothTimesInFeedOrder() {
        #expect(ClockTime.listLabel(["21:15", "17:00"]) == "9:15 PM and 5:00 PM")
        #expect(ClockTime.listLabel(["17:00", "21:15", "17:00"]) == "5:00 PM and 9:15 PM")
    }

    // The de-duplication happens on the RENDERED label rather than on the raw string. Today the parser
    // accepts exactly one spelling ("HH:mm"), so the two are equivalent and this cannot be demonstrated
    // by a fixture; it is written that way so a parser that later accepts a second spelling of one time
    // does not put that time on the card twice.
    @Test func unreadableEntriesStillDropOutRatherThanDeduplicatingToNothing() {
        #expect(ClockTime.listLabel(["19:00", "7pm", "19:00"]) == "7:00 PM")
        #expect(ClockTime.listLabel(["7pm", "7pm"]) == nil)
    }
}
