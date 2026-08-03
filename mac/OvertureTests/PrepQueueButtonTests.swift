import Testing

// #1129: a discoverable "Prep these N" button, shown in the Prep stage view so a first-time user does
// not have to find the Cmd+P shortcut or the toolbar menu to start a Prep run. The show/hide decision
// is a pure helper (not decided inside the SwiftUI view) so it can be tested.
@Suite("Prep stage button (#1129)")
struct PrepQueueButtonTests {
    // Shown only while the Prep stage is focused and there are kept shows to prep.
    @Test func shownOnlyOnThePrepStageWithKeptShows() {
        #expect(PrepQueueButton.shouldShow(stage: .prep, keptToPrep: 3, prepRunning: false))
        #expect(!PrepQueueButton.shouldShow(stage: .review, keptToPrep: 3, prepRunning: false))
        #expect(!PrepQueueButton.shouldShow(stage: nil, keptToPrep: 3, prepRunning: false))
    }

    // Nothing kept means nothing to prep, so no button.
    @Test func hiddenWhenNothingIsKept() {
        #expect(!PrepQueueButton.shouldShow(stage: .prep, keptToPrep: 0, prepRunning: false))
    }

    // A run already in flight must not offer to start a second one (RootView's canStartPrep gates it too,
    // but the button should not even appear while Prep is running).
    @Test func hiddenWhileAPrepRunIsAlreadyRunning() {
        #expect(!PrepQueueButton.shouldShow(stage: .prep, keptToPrep: 3, prepRunning: true))
    }

    // The label names how many shows the run will cover, and agrees with its count.
    @Test func theLabelNamesHowManyShows() {
        #expect(PrepQueueButton.label(count: 1) == "Prep this 1 show")
        #expect(PrepQueueButton.label(count: 3) == "Prep these 3 shows")
    }
}
