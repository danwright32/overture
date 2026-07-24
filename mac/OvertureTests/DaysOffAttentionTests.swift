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
        #expect(DaysOffAttention.badgeTitle(needsALook: true) == "Days off (no shoots from Downbeat)")
    }

    // #1430. Dan read the old badge as an alarm: gold, and "(no shoots)". Both halves said the wrong thing.
    // Having no days off, and having no shoots, are not problems, and the state this marks is neither: it
    // means Overture has been handed nothing to keep clear of. So the words name WHERE the gap is (nothing
    // arrived from Downbeat) rather than describing his schedule.
    @Test func theBadgeDoesNotCallAnEmptyScheduleAProblem() {
        let title = DaysOffAttention.badgeTitle(needsALook: true)
        #expect(title.contains("Downbeat"), "it must point at the missing hand-off, not at his diary")
        #expect(!title.contains("(no shoots)"), "bare 'no shoots' reads as 'you have no work'")
    }

    // And it must not wear the app's attention colour. Gold is reserved for something that is WRONG (a
    // failing source, three items along the same toolbar); this is a limit on what Overture can promise,
    // which is worth saying quietly and exactly once.
    @Test func theBadgeIsNotDrawnInTheAttentionColour() throws {
        // The path has to be right or SourceGuardHelper returns "" and a !contains guard passes on an empty
        // string, which is the shape of a test that can never fail. The #require below is what catches that.
        let rootView = SourceGuardHelper.source("Overture/App/RootView.swift")
        let range = try #require(rootView.range(of: "DaysOffAttention.badgeTitle"))
        let item = rootView[range.lowerBound...].prefix(400)
        #expect(!item.contains("OVColor.gold"), "gold is for what is wrong, and nothing here is wrong")
        #expect(item.contains("OVColor.inkSoft"), "quiet secondary ink, not an alarm")
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
