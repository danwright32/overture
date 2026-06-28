import Testing
import AppKit
@testable import Overture

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
}
