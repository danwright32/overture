import Foundation
import Observation
import SwiftData

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

    // #899: whether there is a store to add a lead INTO.
    //
    // The command lives on the window SCENE, but the sheet it opens is presented from inside RootView,
    // and RootView only exists when the store opened. In the degraded state (another copy holds the
    // single-writer lock, the open failed, or the #663 foreign-database guard tripped) the app shows
    // StoreUnavailableView instead. So the menu item was still there, still enabled, still fired, set the
    // flag, and NOTHING HAPPENED. No sheet, no error, no explanation.
    //
    // A command that is visibly enabled and silently does nothing cannot be told apart from a broken
    // keyboard, a hung app, or Dan's own mistake, and this app's whole discipline is that a failure must
    // be NAMED rather than silently empty. An action he cannot take must not look available.
    // Takes the STORE, not a boolean saying whether there is one. A caller cannot then get the answer
    // wrong, and one nearly did: with a `storeIsAvailable: Bool` the app could pass `true` unconditionally
    // and every test still passed, because the rule and the wiring are two separate claims and only the
    // rule was being checked (the #887 lesson). There is nothing here left to fabricate.
    private let storeIsAvailable: Bool

    // No no-argument init, deliberately. One existed for a moment and it was the whole hole reopening:
    // it quietly made a store of its own, so the app could construct a presenter that CLAIMED a store it
    // did not have, and every test still passed. The store must be handed in, so there is no way to
    // express "I have a store" without actually having one.
    init(store: ModelContainer?) {
        self.storeIsAvailable = store != nil
    }

    // What the menu item is enabled by. Decided here and not in the scene, so it is a test rather than a
    // condition buried in a SwiftUI body where nothing can reach it (#863/#885).
    var canAddLead: Bool { storeIsAvailable }

    // Idempotent on purpose: two entry points ask for the same sheet, and a toggle would let the second
    // one CLOSE the sheet the first just opened.
    func request() {
        // Behind the greyed-out menu item, not instead of it: the flag must never be set when there is no
        // sheet to show it, whatever calls this.
        guard canAddLead else { return }
        QueueWriteTrace.note(QueueWriteTrace.addLead)
        isPresented = true
    }
}
