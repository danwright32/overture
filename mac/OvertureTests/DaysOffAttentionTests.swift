import Testing
import Foundation
@testable import Overture

// #901 part 3: the trap that produced the issue.
//
// Dan reasonably believed Overture knew his booked shoots. It did not, and nothing told him. Downbeat's
// export has always carried `bookings: []`, its own CONTRACT.md says so ("shoots that predate the app are
// not in the database as bookings"), and DownbeatExport.health only asks whether the file exists, decodes,
// and is under 30 days old, so an export with ZERO bookings reports .ok.
//
// A conflict guard that is protecting nothing must not look identical to one that is working.
@Suite("Days off attention (#901)")
struct DaysOffAttentionTests {

    private func booking(_ date: String) -> OvertureBooking {
        OvertureBooking(id: "b1", clientId: "c1", clientDisplayName: "A Client", shootName: "A Shoot",
                        startDate: date, endDate: date, venueId: nil, venueName: "V")
    }

    // MARK: - When Overture is protecting nothing, it says so

    @Test func noBookedShootDataNeedsALook() {
        let cal = BlockedCalendar.build(bookings: [], exportedBlockedDates: [], daysOff: [])
        #expect(DaysOffAttention.needsALook(cal) == true)
    }

    @Test func aSingleBookedShootIsEnoughToStopSayingIt() {
        let cal = BlockedCalendar.build(bookings: [booking("2026-11-14")], exportedBlockedDates: [], daysOff: [])
        #expect(DaysOffAttention.needsALook(cal) == false)
    }

    // The days Dan blocks himself are NOT booked-shoot data, and must not silence the warning: they are
    // vacations, and they say nothing about the shoots he has taken.
    @Test func dansOwnDaysOffDoNotSilenceIt() {
        let cal = BlockedCalendar.build(bookings: [], exportedBlockedDates: [],
                                        daysOff: [DayOffRange(startDate: "2026-11-14", endDate: "2026-11-22", note: nil)])
        #expect(DaysOffAttention.needsALook(cal) == true)
    }

    // MARK: - What Dan reads

    @Test func theToolbarNamesTheGapRatherThanJustGlowing() {
        #expect(DaysOffAttention.badgeTitle(needsALook: false) == "Days off")
        #expect(DaysOffAttention.badgeTitle(needsALook: true) == "Days off (no shoots)")
    }

    // It names the CONSEQUENCE, not just the fact, because the consequence is the part he can act on: he
    // has to block those days by hand, or Overture will keep pitching him for nights he is working.
    @Test func theHelpSaysWhatOvertureCannotProtectHimFrom() {
        let help = DaysOffAttention.help(needsALook: true)
        #expect(help.contains("no upcoming shoots"))     // #925: upcoming, not "ever seen a booking"
        #expect(help.contains("Downbeat"))
        #expect(help.contains("Block those days here"))   // what he can DO about it
    }

    @Test func theHelpIsOrdinaryWhenTheDataIsThere() {
        #expect(DaysOffAttention.help(needsALook: false) == "The days Overture won't pitch you for: your booked shoots, and the days you block.")
    }

    // The sentence inside the sheet, where the promise is actually made. It has to explain WHY the list is
    // empty, or an empty list reads as "you have no shoots booked", which is a different and false claim.
    //
    // Dan uses Downbeat for everything (2026-07-14), so it must NOT hedge about shoots booked outside
    // Downbeat: to him that is noise about a case that never happens. It says only what is true and useful.
    @Test func theSheetExplainsWhyTheListIsEmptyWithoutHedgingAboutOutsideDownbeat() {
        let text = DaysOffAttention.noBookedShootsExplanation
        #expect(text.contains("Downbeat"))
        #expect(!text.lowercased().contains("outside"))   // no "booked outside it" hedge
    }
}
