import Testing
import Foundation

// #2308: the Sources sheet's Done button is its default action, so Return anywhere in the sheet that
// does not handle Return itself pressed it and dismissed the sheet, discarding a part-typed inline edit
// with no warning and no undo.
@Suite("The Sources sheet refuses to close over typed work (#2308)")
struct SourcesSheetCloseTests {

    @Test func nothingTypedMeansDoneJustCloses() {
        #expect(SourcesSheetClose.unsaved(roomPlaceOpen: false, venueLocationOpen: false,
                                          venueNameOpen: false, newSourceTyped: false) == nil)
    }

    @Test func eachOpenEditorStopsTheClose() {
        #expect(SourcesSheetClose.unsaved(roomPlaceOpen: true, venueLocationOpen: false,
                                          venueNameOpen: false, newSourceTyped: false) == .roomPlace)
        #expect(SourcesSheetClose.unsaved(roomPlaceOpen: false, venueLocationOpen: true,
                                          venueNameOpen: false, newSourceTyped: false) == .venueLocation)
        #expect(SourcesSheetClose.unsaved(roomPlaceOpen: false, venueLocationOpen: false,
                                          venueNameOpen: true, newSourceTyped: false) == .venueName)
        #expect(SourcesSheetClose.unsaved(roomPlaceOpen: false, venueLocationOpen: false,
                                          venueNameOpen: false, newSourceTyped: true) == .newSource)
    }

    // The add form is judged on its TEXT, not on being open: one Dan opened and left empty has nothing
    // in it to protect, and refusing to close over it would be a guard that only ever gets in the way
    // (#928's shape, where the Days off sheet asks only when the form was really edited).
    @Test func anEmptyAddFormIsNotUnsavedWork() {
        #expect(SourcesSheetClose.unsaved(roomPlaceOpen: false, venueLocationOpen: false,
                                          venueNameOpen: false, newSourceTyped: false) == nil)
    }

    // Two at once is possible in this sheet, and the inline editor is reported first: it holds a draft of
    // an existing row's field, so abandoning it changes nothing visible, while the add form at least
    // stays on screen with its text still in it.
    @Test func anInlineEditIsReportedBeforeTheAddForm() {
        #expect(SourcesSheetClose.unsaved(roomPlaceOpen: false, venueLocationOpen: true,
                                          venueNameOpen: false, newSourceTyped: true) == .venueLocation)
    }

    // Every refusal names what is unfinished AND the way out of it, because each editor carries its own
    // Save and Cancel: a message that did not would leave Dan pressing Done again.
    @Test func everyRefusalSaysWhatToDoAboutIt() {
        for unsaved in [SourcesSheetClose.Unsaved.roomPlace, .venueLocation, .venueName, .newSource] {
            let message = SourcesSheetClose.message(for: unsaved)
            #expect(!message.isEmpty)
            #expect(message.contains("cancel") || message.contains("clear"),
                    "\(unsaved) does not say how to get out of it: \(message)")
        }
    }

    @Test func thefourMessagesAreAllDifferent() {
        let all = [SourcesSheetClose.Unsaved.roomPlace, .venueLocation, .venueName, .newSource]
            .map(SourcesSheetClose.message(for:))
        #expect(Set(all).count == all.count, "two causes sharing one sentence is two states Dan cannot tell apart")
    }
}

// The rule is worth nothing unless Done asks it. A guard and its wiring are two claims (#887), and a
// SwiftUI button's closure cannot be reached from a test.
@Suite("The Sources sheet's Done button asks the rule (#2308)")
struct SourcesSheetCloseWiringTests {
    private var sources: String { SourceGuardHelper.source("Overture/UI/SourcesView.swift") }

    @Test func doneGoesThroughTheRuleRatherThanStraightToDismiss() {
        #expect(!sources.isEmpty)
        #expect(sources.contains("Button(\"Done\") { close() }.keyboardShortcut(.defaultAction)"))
        #expect(sources.contains("SourcesSheetClose.unsaved("))
    }

    // The message is DERIVED from the live editing state, not stored when Done was pressed. Stored, it
    // would still be on screen after Dan saved the edit it names, which is a sentence that stopped being
    // true (L11/L14).
    @Test func theRefusalMessageIsDerivedFromTheLiveState() {
        #expect(sources.contains("if closeRefused, let unsaved = unsavedWork"))
        #expect(sources.contains("SourcesSheetClose.message(for: unsaved)"))
    }
}
