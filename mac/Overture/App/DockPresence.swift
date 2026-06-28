import AppKit

// #334: the Dock running cue for the resident menu-bar app. While the main window is open the app
// presents as a normal Dock application (.regular, so macOS draws the running dot); when the window
// is closed it drops back to the menu-bar-only LSUIElement presence (.accessory). Pure so the
// mapping is testable; the AppDelegate owns when to call it.
enum DockPresence {
    static func policy(mainWindowVisible: Bool) -> NSApplication.ActivationPolicy {
        mainWindowVisible ? .regular : .accessory
    }
}
