import Foundation

// #1129: a discoverable "Prep these N" button in the Prep stage view, so a first-time user does not
// have to know the Cmd+P shortcut or find the toolbar menu to start a Prep run. The show/hide decision
// and its label are pure so they can be tested (the #863 lesson: logic inside a SwiftUI view is
// untestable).
enum PrepQueueButton {
    // Shown only while the Prep stage is focused, there are kept shows to prep, and no run is already
    // in flight (RootView's canStartPrep gates the actual start too; the button simply should not appear
    // while Prep is running).
    static func shouldShow(stage: StageFocus?, keptToPrep: Int, prepRunning: Bool) -> Bool {
        stage == .prep && keptToPrep > 0 && !prepRunning
    }

    static func label(count: Int) -> String {
        count == 1 ? "Prep this 1 show" : "Prep these \(count) shows"
    }
}
