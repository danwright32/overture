import Testing
@testable import Overture

// #799: "Add a lead" has to be reachable by keyboard, and a SwiftUI Button inside a TOOLBAR MENU
// cannot do that. Its `.keyboardShortcut` renders in the menu (it drew "⌘L" perfectly) and never
// registers with the system, so the key does nothing at all. Verified the hard way: Dan pressed it.
//
// A real menu-bar command DOES register, so the command moves to the menu bar and both entry points
// (the menu bar and the existing toolbar item) drive this one presenter. The presenter exists so that
// wiring is a unit test rather than a thing we hope about: a keyboard shortcut is exactly the sort of
// plumbing that silently rots, and this session is the proof.
@MainActor
@Suite("Add-a-lead presenter (#799)")
struct AddLeadPresenterTests {
    @Test func theSheetIsClosedUntilSomethingAsksForIt() {
        #expect(!AddLeadPresenter().isPresented)
    }

    @Test func aRequestOpensTheSheet() {
        let presenter = AddLeadPresenter()
        presenter.request()
        #expect(presenter.isPresented)
    }

    // Both entry points (the menu-bar command and the toolbar item) drive the same presenter, so asking
    // twice is idempotent rather than a second sheet or a toggle that CLOSES the one already open.
    @Test func askingTwiceLeavesItOpenRatherThanTogglingItShut() {
        let presenter = AddLeadPresenter()
        presenter.request()
        presenter.request()
        #expect(presenter.isPresented)
    }

    @Test func dismissingClosesIt() {
        let presenter = AddLeadPresenter()
        presenter.request()
        presenter.isPresented = false
        #expect(!presenter.isPresented)
    }
}
