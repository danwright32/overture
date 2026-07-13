import SwiftData
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
    private func memoryStore() -> ModelContainer {
        try! ModelContainer(for: Prospect.self,
                            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    @Test func theSheetIsClosedUntilSomethingAsksForIt() {
        #expect(!AddLeadPresenter(store: memoryStore()).isPresented)
    }

    @Test func aRequestOpensTheSheet() {
        let presenter = AddLeadPresenter(store: memoryStore())
        presenter.request()
        #expect(presenter.isPresented)
    }

    // Both entry points (the menu-bar command and the toolbar item) drive the same presenter, so asking
    // twice is idempotent rather than a second sheet or a toggle that CLOSES the one already open.
    @Test func askingTwiceLeavesItOpenRatherThanTogglingItShut() {
        let presenter = AddLeadPresenter(store: memoryStore())
        presenter.request()
        presenter.request()
        #expect(presenter.isPresented)
    }

    @Test func dismissingClosesIt() {
        let presenter = AddLeadPresenter(store: memoryStore())
        presenter.request()
        presenter.isPresented = false
        #expect(!presenter.isPresented)
    }

    // #899: the command can fire into NOTHING.
    //
    // It lives on the window SCENE, but the sheet it opens is presented from inside RootView, and
    // RootView only exists when the store opened. In the degraded state (another copy holds the
    // single-writer lock, the open failed, or the #663 foreign-database guard tripped) the app shows
    // StoreUnavailableView instead, so the menu item is still there, still enabled, still fires, sets
    // the flag, and nothing happens at all. No sheet, no error, no explanation.
    //
    // Found while diagnosing Dan's "cmd+l did nothing" (a different cause, healthy store), and it is the
    // worse of the two: a command that is visibly enabled and silently does nothing cannot be told apart
    // from a broken keyboard, a hung app, or his own mistake. An action he cannot take must not look
    // available.
    @Test func withNoStoreThereIsNoLeadToAddAndTheCommandSaysSo() {
        #expect(!AddLeadPresenter(store: nil).canAddLead)
        #expect(AddLeadPresenter(store: memoryStore()).canAddLead)
    }

    // Belt and braces behind the greyed-out menu item: the flag can never be set when there is no sheet
    // to show it, whatever calls request(). A presenter whose isPresented is true with nothing presenting
    // it is a bug waiting for a second entry point to find it.
    @Test func withNoStoreARequestCannotOpenASheetThatDoesNotExist() {
        let presenter = AddLeadPresenter(store: nil)
        presenter.request()
        #expect(!presenter.isPresented)
    }

    // The normal case stays exactly as it was: a store, a command, a sheet.
    @Test func withAStoreItOpensAsBefore() {
        let presenter = AddLeadPresenter(store: memoryStore())
        presenter.request()
        #expect(presenter.isPresented)
    }
}
