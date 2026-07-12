import Foundation
import Observation

// #799: whether the Add-a-lead sheet is open, owned in one place because TWO things open it (the
// menu-bar command and the toolbar item) and they must not fight.
//
// It exists because of a real failure: the sheet was first reachable only from a Button inside a
// TOOLBAR MENU, and a `.keyboardShortcut` there renders in the menu (it drew "⌘L" perfectly) but never
// registers with the system. The key did nothing at all, in the built app, with a real key press.
//
// A menu-bar command DOES register. So the command lives in the menu bar now, and this presenter is
// what both entry points drive, which also makes that wiring a unit test rather than something we hope
// about. A keyboard shortcut is exactly the sort of plumbing that rots silently, and this one already
// did once.
@MainActor
@Observable
final class AddLeadPresenter {
    var isPresented = false

    // Idempotent on purpose: two entry points ask for the same sheet, and a toggle would let the second
    // one CLOSE the sheet the first just opened.
    func request() {
        isPresented = true
    }
}
