import AppKit

// #334: the Dock running cue for the resident menu-bar app. While the main window is open the app
// presents as a normal Dock application (.regular, so macOS draws the running dot); when the window
// is closed it drops back to the menu-bar-only LSUIElement presence (.accessory). Pure so the
// mapping is testable; the AppDelegate owns when to call it.
enum DockPresence {
    // #2115: work being due keeps the icon alive too. Dan asked for a Dock badge, and with the window
    // closed this app has no Dock icon at all, so the badge would be invisible in exactly the situation
    // it exists for. The icon appearing IS part of the signal, not a side effect of drawing on it.
    static func policy(mainWindowVisible: Bool, dueCount: Int = 0) -> NSApplication.ActivationPolicy {
        (mainWindowVisible || dueCount > 0) ? .regular : .accessory
    }

    // Whether taking this policy also means ACTIVATING the app, which is the whole of the Cmd+L bug Dan
    // hit on 2026-07-13 ("nothing worked").
    //
    // An LSUIElement app is an accessory and owns NO MENU BAR, so none of its keyboard shortcuts can
    // fire. Promoting it to `.regular` gives it one, but macOS does not make it the active app as a side
    // effect of the promotion. The window therefore comes up looking completely ready, while the menu bar
    // and every keystroke still belong to whatever app was in front before. Cmd+L fell on the floor.
    // Clicking any menu forced the app active, which is why the same key then worked and the whole thing
    // read as a flake rather than a bug.
    //
    // A window that looks ready for typing and silently is not cannot be told apart from a broken
    // keyboard, so it is a defect and not a rough edge.
    //
    // Only the promotion activates. Dropping back to the menu bar must never yank focus (Dan closed the
    // window precisely to get on with something else), and re-asserting a policy the app already holds
    // must not either, or a background reconcile could steal his keyboard mid-sentence.
    static func shouldActivate(from current: NSApplication.ActivationPolicy,
                               to next: NSApplication.ActivationPolicy) -> Bool {
        current != .regular && next == .regular
    }

    // The whole transition, with the app injected, so the WIRE is a unit test and not a hope.
    //
    // `shouldActivate` being right is worth nothing if nobody calls it, and a guard whose wiring is
    // untested is a guard that has already silently rotted once here. So the sequence itself (set the
    // policy, and then activate when we have just become a regular app) lives where it can be asserted,
    // and the AppDelegate only supplies the real NSApp.
    // #2115: only a WINDOW brings the app forward. The icon can now also appear because work fell due,
    // and that promotion must never activate: Dan closed the window to get on with something else, and an
    // overdue reply arriving is not permission to take his keyboard mid-sentence. The icon appears, the
    // badge lands on it, and he comes back when he chooses.
    static func apply(mainWindowVisible: Bool, dueCount: Int = 0,
                      current: NSApplication.ActivationPolicy,
                      setPolicy: (NSApplication.ActivationPolicy) -> Void,
                      activate: () -> Void) {
        let next = policy(mainWindowVisible: mainWindowVisible, dueCount: dueCount)
        guard current != next else { return }
        setPolicy(next)
        if mainWindowVisible, shouldActivate(from: current, to: next) { activate() }
    }
}
