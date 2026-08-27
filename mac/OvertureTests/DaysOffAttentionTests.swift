import Testing
import Foundation

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

    // #1456 helpers: a fixed clock and today, an isolated defaults suite (so the snooze never leaks between
    // tests or reads Dan's real one), and a calendar that DOES have an upcoming shoot (so the stalled-feed
    // reason is the one under test, not the no-shoots one).
    private let today = "2026-11-01"
    private let now = Date(timeIntervalSince1970: 1_762_000_000)
    private func scratchDefaults() -> UserDefaults {
        UserDefaults(suiteName: "days-off-attention-\(UUID().uuidString)")!
    }
    private func calendarWithUpcomingShoot() -> BlockedCalendar {
        BlockedCalendar.build(bookings: [booking("2026-11-14")], exportedBlockedDates: [], daysOff: [])
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

    // #1430 (second pass, Dan 2026-07-24): the toolbar says the same thing in both states, and the
    // difference is carried by the icon's colour alone. He asked for no words unless something is wrong,
    // and settled on keeping a quiet mark once it was clear this is the ONLY thing in the app watching for
    // a dry Downbeat pipe: the export's own health check asks whether the FILE is recent and parses, so a
    // fresh export containing zero upcoming bookings reports perfectly healthy. That is the #901 trap
    // exactly. The mark stays so the blind spot is visible at a glance; the sentence moves to the hover and
    // the sheet, which is where there is room to say it properly.
    @Test func theToolbarSaysTheSameThingInBothStates() {
        #expect(DaysOffAttention.badgeTitle(.none) == "Days off")
        #expect(DaysOffAttention.badgeTitle(.noUpcomingShoots) == "Days off")
        #expect(DaysOffAttention.badgeTitle(.feedStalled) == "Days off")   // #1456: the stalled feed too
    }

    // The words are gone from the toolbar, so nothing there may describe his schedule back to him. This is
    // what stops the "(no shoots)" reading ("you have no work") from creeping back in a later edit.
    @Test func theToolbarNeverDescribesHisScheduleBackToHim() {
        let title = DaysOffAttention.badgeTitle(.noUpcomingShoots)
        #expect(!title.lowercased().contains("shoot"), "the toolbar must not talk about his shoots at all")
        #expect(!title.contains("("), "no parenthetical: the explanation lives in the hover and the sheet")
    }

    // #1745: the words are PRINTED beside the icon while Overture is blind to his schedule, and hidden
    // again the moment it is not. The two assertions #1430 left here were the exact reverse of this pair
    // (that the item must never print a static title, and that it must be drawn in `OVColor.inkSoft`) and
    // they are DELETED rather than adjusted: they were the guard defending the behaviour this reverses
    // (L252). What #1430 actually asked for, the plain two words and no gold, is asserted below and in
    // `theToolbarNeverDescribesHisScheduleBackToHim`, and neither is being reversed.
    @Test func theWordsComeUpOnlyWhileSomethingNeedsHim() {
        #expect(DaysOffAttention.showsTitle(.noUpcomingShoots))
        #expect(DaysOffAttention.showsTitle(.feedStalled))
        #expect(DaysOffAttention.showsTitle(.none) == false,
                "a mark that is always up is not a mark; the resting state leaves its name to the hover")
    }

    // Scoped to the FUNCTION's balanced-brace body, not to a fixed number of characters after an anchor.
    // Both of these were first written as `.prefix(600)` from `DaysOffAttention.badgeTitle` and both went
    // red on their own explaining comment rather than on the code: a window measured in characters stops
    // containing the thing it checks the moment anything is written above it (L518). `bodyOfFunction` has
    // no such number in it.
    @Test func theToolbarItemAsksForTheWordsThroughThatRule() throws {
        let rootView = SourceGuardHelper.source("Overture/App/RootView.swift")
        let item = try #require(SourceGuardHelper.bodyOfFunction(named: "daysOffButton", in: rootView))
        #expect(item.contains("showsTitle: DaysOffAttention.showsTitle(reason)"),
                "the view must ask the rule, so the rule above is what actually ships")
    }

    // The half that makes the defect structurally unable to return: there is no longer an ink to get
    // wrong, because the ink does not change at all. #1745's whole cause was that the attention state's
    // ink (`OVColor.inkSoft`, dark mode (0.702, 0.722, 0.667)) is DIMMER than the resting `Color.primary`,
    // so the state meaning "Overture cannot keep clear of your bookings" rendered less visibly than the
    // state meaning everything is fine.
    @Test func theInkIsTheSameWhetherOrNotSomethingNeedsHim() throws {
        // The path has to be right or SourceGuardHelper returns "" and a !contains guard passes on an empty
        // string, which is the shape of a test that can never fail. The #require below is what catches that:
        // `bodyOfFunction` answers nil rather than "" when it cannot find the function at all.
        let rootView = SourceGuardHelper.source("Overture/App/RootView.swift")
        let item = try #require(SourceGuardHelper.bodyOfFunction(named: "daysOffButton", in: rootView))
        #expect(item.contains(".foregroundStyle(Color.primary)"),
                "one ink, stated unconditionally, for both states")
        #expect(!item.contains("OVColor.inkSoft"),
                "the dimmer-than-resting ink is what #1745 was, and it must not come back")
        #expect(!item.contains("OVColor.gold"),
                "gold is for what is wrong, and nothing here is wrong (#1430 stands)")
    }

    // It names the CONSEQUENCE, not just the fact, because the consequence is the part he can act on: he
    // has to block those days by hand, or Overture will keep pitching him for nights he is working.
    @Test func theHelpSaysWhatOvertureCannotProtectHimFrom() {
        let help = DaysOffAttention.help(.noUpcomingShoots)
        #expect(help.contains("no upcoming shoots"))     // #925: upcoming, not "ever seen a booking"
        #expect(help.contains("Downbeat"))
        #expect(help.contains("Block those days here"))   // what he can DO about it
    }

    @Test func theHelpIsOrdinaryWhenTheDataIsThere() {
        #expect(DaysOffAttention.help(.none) == "The days Overture won't pitch you for: your booked shoots, and the days you block.")
    }

    // MARK: - #1456: the stalled-feed reason

    // The precedence: no upcoming shoots is the more fundamental "Overture is blind" state and wins; the
    // stalled-feed nudge only speaks when there ARE upcoming shoots to have gone stale on. The snooze
    // silences the whole mark.
    @Test func reasonPrefersNoShootsThenStalledThenNone() {
        let defaults = scratchDefaults()
        let withShoot = calendarWithUpcomingShoot()
        let noShoot = BlockedCalendar.empty

        #expect(DaysOffAttention.reason(noShoot, feedStalled: true, today: today, now: now, defaults: defaults) == .noUpcomingShoots)
        #expect(DaysOffAttention.reason(withShoot, feedStalled: true, today: today, now: now, defaults: defaults) == .feedStalled)
        #expect(DaysOffAttention.reason(withShoot, feedStalled: false, today: today, now: now, defaults: defaults) == .none)
    }

    @Test func snoozeSilencesTheStalledFeedToo() {
        let defaults = scratchDefaults()
        DaysOffAttention.snooze(now: now, into: defaults)
        #expect(DaysOffAttention.reason(calendarWithUpcomingShoot(), feedStalled: true,
                                        today: today, now: now, defaults: defaults) == .none)
    }

    // The stalled-feed help names the fact and the action; the sheet sentence adds the reassurance the
    // toolbar has no room for, because a broken export and a quiet booking spell look identical.
    @Test func theStalledFeedCopyNudgesWithoutAccusing() {
        let help = DaysOffAttention.help(.feedStalled)
        #expect(help.contains("last four weeks"))
        #expect(help.contains("Downbeat"))
        #expect(DaysOffAttention.feedStalledExplanation.contains("nothing is wrong"))
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
