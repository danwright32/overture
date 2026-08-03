import Testing
import AppKit

// #334: a resident menu-bar app (LSUIElement) shows no Dock running dot, so it reads as "not
// running". The fix gives it a normal Dock tile while its main window is open, and drops back to
// menu-bar-only when the window closes. This is the pure decision behind that toggle.
@Suite("Dock presence follows the main window")
struct DockPresenceTests {
    @Test func showsInDockWhileMainWindowOpen() {
        #expect(DockPresence.policy(mainWindowVisible: true) == .regular)
    }

    @Test func menuBarOnlyWhenMainWindowClosed() {
        #expect(DockPresence.policy(mainWindowVisible: false) == .accessory)
    }

    // Dan, 2026-07-13: "I just tried to cmd+l to track a new lead in the live version of the app and
    // nothing worked."
    //
    // It was not the shortcut. Verified against the running Release app: `File > Add a Lead...` was
    // present, enabled, and carried a Command-only "L" key equivalent. Choosing it from the MENU opened
    // the sheet; pressing the key did nothing. The difference between those two is ACTIVATION.
    //
    // An LSUIElement app is an accessory: it owns no menu bar, so no keyboard shortcut of its own can
    // fire. Promoting it to `.regular` gives it one, but macOS does NOT make it the active app as a side
    // effect. So its window came up looking perfectly focused while the menu bar and the keystrokes still
    // belonged to whatever app was in front before, and every shortcut fell on the floor. Clicking any
    // menu forced the app active, which is why it then "started working" and looked like a flake.
    //
    // So: becoming a regular app means ACTIVATING. Anything else ships a window that looks ready for
    // typing and silently is not, which is indistinguishable from a broken keyboard.
    @Test func becomingARegularAppMeansActivatingIt() {
        #expect(DockPresence.shouldActivate(from: .accessory, to: .regular))
    }

    // ...and nothing else does. Dropping back to the menu bar must never yank focus (Dan closed the
    // window to get on with something else), and re-asserting a policy the app already has would let a
    // background reconcile steal his keyboard mid-sentence.
    @Test func nothingElseStealsFocus() {
        #expect(!DockPresence.shouldActivate(from: .regular, to: .accessory))
        #expect(!DockPresence.shouldActivate(from: .regular, to: .regular))
        #expect(!DockPresence.shouldActivate(from: .accessory, to: .accessory))
    }

    // THE WIRE, not just the rule. `shouldActivate` returning the right answer is worth nothing if
    // nobody calls it, and a guard whose wiring went untested has already silently rotted in this repo
    // once (#887). So the actual sequence is asserted: opening the window promotes the app AND activates
    // it, in that order.
    @Test func openingTheWindowBothPromotesTheAppAndActivatesIt() {
        var policies: [NSApplication.ActivationPolicy] = []
        var activated = 0

        DockPresence.apply(mainWindowVisible: true, current: .accessory,
                           setPolicy: { policies.append($0) }, activate: { activated += 1 })

        #expect(policies == [.regular])
        #expect(activated == 1)      // without this, the window looks ready and no keystroke reaches it
    }

    // Closing it drops back to the menu bar and must NOT grab focus: Dan closed the window to go and do
    // something else, and an app that yanks his keyboard on the way out is worse than no Dock cue at all.
    @Test func closingTheWindowNeverGrabsFocus() {
        var policies: [NSApplication.ActivationPolicy] = []
        var activated = 0

        DockPresence.apply(mainWindowVisible: false, current: .regular,
                           setPolicy: { policies.append($0) }, activate: { activated += 1 })

        #expect(policies == [.accessory])
        #expect(activated == 0)
    }

    // A reconcile firing in the background, or any other recount while nothing changed, must touch
    // nothing at all. Re-asserting the policy the app already holds would let a scheduled job steal his
    // keyboard mid-sentence.
    @Test func aRecountThatChangesNothingTouchesNothing() {
        var policies: [NSApplication.ActivationPolicy] = []
        var activated = 0

        DockPresence.apply(mainWindowVisible: true, current: .regular,
                           setPolicy: { policies.append($0) }, activate: { activated += 1 })

        #expect(policies.isEmpty)
        #expect(activated == 0)
    }
}
