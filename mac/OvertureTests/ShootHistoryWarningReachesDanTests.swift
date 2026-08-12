import Testing
import Foundation

// #1900: the shoot history verdict reaches Dan.
//
// `ShootHistory.loadWithHealth` has always distinguished missing, unreadable and stale, and
// `ShootHistory.warningText` has always written the sentence for each. Nothing displayed any of them:
// `VenueShootHistory.current()` took the shoots out of that tuple and dropped the health on the floor,
// so the check ran on every prep queue build and reached nobody. A guard that fires into nothing is
// indistinguishable from no guard (L3, L46).
//
// What it costs while it is silent is invisible by construction. `overture-shoot-history.json` is
// refreshed by a MANUAL export Dan has to remember to redo, so an old file simply under-reports the
// rooms he has worked, and a pitch that should say he has shot this room before says nothing instead.
// A stale count and an accurate one look identical on screen.
//
// The three states are asserted APART, not as "a warning appeared", because they call for different
// things from Dan: run the import for the first time, re-run it because the file is broken, or
// re-export the calendar because it has aged out (L11).
@Suite("The shoot history warning reaches Dan (#1900)")
struct ShootHistoryWarningReachesDanTests {

    private func texts(_ health: ShootHistory.Health?) -> [String] {
        AppNotices.current(omniFocusFailing: false, shootHistory: health, status: StatusLine())
            .map(\.text)
    }

    // No import has ever been run, so the whole feature is doing nothing.
    @Test func aMissingHistoryIsSaidOutLoud() {
        let notices = AppNotices.current(omniFocusFailing: false, shootHistory: .missing,
                                         status: StatusLine())
        #expect(notices.map(\.text) == [ShootHistory.warningText(for: .missing)])
        #expect(notices.map(\.tone) == [.warning])
    }

    // Present but broken. A different fault with a different remedy, so it must not arrive in the
    // same words as the one above.
    @Test func anUnreadableHistoryIsSaidOutLoud() {
        let notices = AppNotices.current(omniFocusFailing: false, shootHistory: .unreadable,
                                         status: StatusLine())
        #expect(notices.map(\.text) == [ShootHistory.warningText(for: .unreadable)])
        #expect(notices.map(\.tone) == [.warning])
    }

    // Readable and old. The line states the age, because "old" is what Dan has to judge against his
    // own season, and 121 days and 400 days are not the same news.
    @Test func aStaleHistoryNamesItsAge() {
        let notices = AppNotices.current(omniFocusFailing: false, shootHistory: .stale(ageDays: 214),
                                         status: StatusLine())
        #expect(notices.count == 1)
        #expect(notices.first?.text.contains("214") == true)
        #expect(notices.first?.tone == .warning)
    }

    // The point of the issue: "we could not read it" and "it is old" call for different actions, so
    // they may never collapse into one sentence.
    @Test func theThreeStatesDoNotShareOneSentence() {
        let said = Set([texts(.missing), texts(.unreadable), texts(.stale(ageDays: 214))].flatMap { $0 })
        #expect(said.count == 3)
    }

    // A healthy file adds no row at all, so the masthead never grows a standing line of reassurance.
    @Test func aHealthyHistorySaysNothing() {
        #expect(texts(.ok).isEmpty)
    }

    // Nothing has looked yet. Silence, not a verdict: a claim made before a measurement is exactly
    // the shape of message that teaches Dan to ignore this surface (L11).
    @Test func nothingIsClaimedBeforeAnythingHasLooked() {
        #expect(texts(nil).isEmpty)
    }

    // Overture cannot export Dan's calendar for him, but it CAN read the file again, so the line that
    // reports the fault carries the one remedy the app owns (L80). Without it the warning would stand
    // until the next launch even after he had fixed it.
    @Test func theWarningCarriesTheOneRemedyTheAppOwns() {
        let notices = AppNotices.current(omniFocusFailing: false, shootHistory: .stale(ageDays: 214),
                                         status: StatusLine())
        #expect(notices.first?.action == .recheckShootHistory)
        #expect(notices.first?.action?.title.isEmpty == false)
    }

    // It sits beside the app's other standing faults rather than replacing them: a sync failure and a
    // stale history are independent, and a surface that shows one instead of the other is how a
    // message gets silently erased (L53).
    @Test func itNeverHidesTheAppsOtherStandingFaults() {
        var status = StatusLine()
        status.set("Prep finished")
        let notices = AppNotices.current(omniFocusFailing: true, shootHistory: .missing, status: status)
        #expect(notices.count == 3)
        #expect(notices.contains { $0.text == ShootHistory.warningText(for: .missing) })
        #expect(notices.contains { $0.text == AppNotices.omniFocusFailing.text })
        #expect(notices.contains { $0.text == "Prep finished" })
    }

    // L3: built is not wired. Every assertion above would pass on a masthead nobody ever handed a
    // verdict to, which is precisely the defect this issue exists for: the check already ran and its
    // answer was thrown away one call up. So the wiring itself is asserted, in the file that owns it.
    @Test func rootViewActuallyHandsTheVerdictToTheMasthead() {
        let source = SourceGuardHelper.source("Overture/App/RootView.swift")
        #expect(source.contains("shootHistory: shootHistoryHealth"))
        #expect(source.contains("ShootHistory.loadWithHealth"))
        #expect(source.contains("case .recheckShootHistory"))
    }
}
