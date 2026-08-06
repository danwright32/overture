import Testing
import Foundation
import AppKit

// #2115. Dan, 2026-08-05: he wants a badge for any responses due today, counting everything due today or
// earlier ("if it's overdue it should be counted"), on three surfaces: a count on the Dock icon, a count
// beside the menu bar glyph, and the Dock icon staying present while the count is above zero even with
// the main window closed.
//
// Overture is menu-bar-only with the window closed, so without the third part the first one has nothing
// to draw on: the badge would exist and be invisible exactly when Dan is not already looking at the app,
// which is the only time it has a job to do.
@Suite("The count of work due today (#2115)")
struct DueBadgeTests {

    // MARK: what the badge says

    // Nothing due is NOT a zero. A badge reading 0 is a red dot claiming work, and the whole point of the
    // thing is that its presence means something.
    @Test func nothingDueShowsNoBadgeAtAll() {
        #expect(DueBadge.label(count: 0) == nil)
    }

    @Test func aCountIsShownAsItself() {
        #expect(DueBadge.label(count: 1) == "1")
        #expect(DueBadge.label(count: 12) == "12")
    }

    // A negative count is a bug upstream, and painting it on the Dock would publish that bug. Treated as
    // nothing rather than rendered, since "-1 due" is a sentence about the app, not about Dan's work.
    @Test func animpossibleCountShowsNothingRatherThanNonsense() {
        #expect(DueBadge.label(count: -3) == nil)
    }

    // The Dock badge is a small circle. A four-digit number renders as an unreadable smear, so it caps,
    // and the cap is stated as "more than 99" rather than a wrong number.
    @Test func aVeryLargeCountCapsInsteadOfSmearing() {
        #expect(DueBadge.label(count: 99) == "99")
        #expect(DueBadge.label(count: 100) == "99+")
        #expect(DueBadge.label(count: 4_000) == "99+")
    }

    // MARK: the menu bar

    // The glyph is always there; the count rides beside it only when there is one, so the menu bar does
    // not carry a permanent "0" in Dan's status bar.
    @Test func theMenuBarShowsTheCountOnlyWhenThereIsOne() {
        #expect(DueBadge.menuBarTitle(count: 0) == "")
        #expect(DueBadge.menuBarTitle(count: 3) == "3")
        #expect(DueBadge.menuBarTitle(count: 250) == "99+")
    }

    // Both surfaces say the same number, always. Two independently computed labels for one count is how
    // the pills and the toolbar came to disagree in #2114.
    @Test func theDockAndTheMenuBarNeverStateDifferentNumbers() {
        for n in [0, 1, 7, 99, 100, 1_000] {
            let dock = DueBadge.label(count: n)
            let menu = DueBadge.menuBarTitle(count: n)
            #expect(dock ?? "" == menu, "dock \(dock ?? "nil") vs menu bar \(menu) for \(n)")
        }
    }

    // MARK: carrying the count to the surfaces that draw it

    private func scratchDefaults() -> UserDefaults {
        let suite = "due-badge-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    @Test func aPublishedCountIsWhatTheSurfacesRead() {
        let d = scratchDefaults()
        DueBadge.publish(4, into: d)
        #expect(DueBadge.current(from: d) == 4)
        #expect(DueBadge.label(count: DueBadge.current(from: d)) == "4")
    }

    // Never read before it has been written, which is every launch until the first tick lands. Zero is
    // the safe reading: no badge, rather than a badge claiming work nobody has counted.
    @Test func aCountNobodyHasPublishedYetReadsAsNothingDue() {
        #expect(DueBadge.current(from: scratchDefaults()) == 0)
        #expect(DueBadge.label(count: DueBadge.current(from: scratchDefaults())) == nil)
    }

    // A negative can never be stored, so a bug upstream cannot reach the Dock through this door either.
    @Test func animpossibleCountCannotBeStored() {
        let d = scratchDefaults()
        DueBadge.publish(-5, into: d)
        #expect(DueBadge.current(from: d) == 0)
    }

    // A glyph with a number beside it is not a sentence, so the item says what it is and what the number
    // means. It still identifies itself when there is nothing due, rather than announcing nothing.
    @Test func theMenuBarItemSaysWhatItIsForVoiceOver() {
        #expect(DueBadge.menuBarAccessibilityLabel(count: 0) == "Overture")
        #expect(DueBadge.menuBarAccessibilityLabel(count: 1).contains("1 thing due"))
        #expect(DueBadge.menuBarAccessibilityLabel(count: 4).contains("4 things due"))
    }

    // MARK: the Dock icon staying present

    // Dan's third requirement. With the window closed the app is menu-bar-only and has no Dock icon at
    // all, so a badge would have nowhere to appear. Work being due keeps the icon alive.
    @Test func workDueKeepsTheDockIconAliveWithTheWindowClosed() {
        #expect(DockPresence.policy(mainWindowVisible: false, dueCount: 2) == .regular)
    }

    // And with nothing due it goes back to being out of the way, which is what he closed the window for.
    @Test func nothingDueWithTheWindowClosedGoesBackToTheMenuBarOnly() {
        #expect(DockPresence.policy(mainWindowVisible: false, dueCount: 0) == .accessory)
    }

    // An open window still shows in the Dock whatever the count, so the running cue #334 added does not
    // depend on having work.
    @Test func anOpenWindowAlwaysShowsInTheDock() {
        #expect(DockPresence.policy(mainWindowVisible: true, dueCount: 0) == .regular)
        #expect(DockPresence.policy(mainWindowVisible: true, dueCount: 5) == .regular)
    }

    // The promotion must not steal focus. Dan closed the window to get on with something else, and an
    // overdue reply appearing is not permission to take his keyboard mid-sentence. The icon appears; the
    // app stays in the background.
    @Test func workBecomingDueNeverStealsFocus() {
        var activated = false
        var policy = NSApplication.ActivationPolicy.accessory
        DockPresence.apply(mainWindowVisible: false, dueCount: 3, current: policy,
                           setPolicy: { policy = $0 }, activate: { activated = true })
        #expect(policy == .regular, "the icon has to appear, or the badge has nothing to sit on")
        #expect(!activated, "appearing in the Dock must never yank focus from what he is doing")
    }

    // Opening the window DOES activate, which is the Cmd+L bug #334 fixed and must stay fixed.
    @Test func openingTheWindowStillActivates() {
        var activated = false
        var policy = NSApplication.ActivationPolicy.accessory
        DockPresence.apply(mainWindowVisible: true, dueCount: 0, current: policy,
                           setPolicy: { policy = $0 }, activate: { activated = true })
        #expect(policy == .regular)
        #expect(activated)
    }

    // Re-asserting the same state does nothing at all, so a background recount cannot churn the Dock.
    @Test func aRecountThatChangesNothingTouchesNothing() {
        var calls = 0
        DockPresence.apply(mainWindowVisible: false, dueCount: 4, current: .regular,
                           setPolicy: { _ in calls += 1 }, activate: { calls += 1 })
        #expect(calls == 0)
    }
}
