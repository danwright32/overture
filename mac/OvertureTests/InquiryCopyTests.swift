import Testing
import Foundation

@Suite("Inquiry copy")
struct InquiryCopyTests {
    @Test func replyTitleNamesTheInquirer() {
        #expect(InquiryCopy.replyTitle(to: "Ada Lovelace") == "Reply to Ada Lovelace")
    }

    @Test func subtitleJoinsWhicheverPartsAreKnown() {
        #expect(InquiryCopy.rowSubtitle(event: "Gala", venue: "Weill Recital Hall") == "Gala at Weill Recital Hall")
        #expect(InquiryCopy.rowSubtitle(event: "Gala", venue: nil) == "Gala")
        #expect(InquiryCopy.rowSubtitle(event: "Gala", venue: "  ") == "Gala")
        #expect(InquiryCopy.rowSubtitle(event: "", venue: "Weill") == "at Weill")
        #expect(InquiryCopy.rowSubtitle(event: "  ", venue: nil) == "")
    }

    // #1504: the one sheet both logs an inquiry and corrects one, so every sentence in it has to say
    // which it is doing. "Log" wording on an edit would tell Dan he is about to add a second record.
    @Test func theIntakeSheetSaysWhetherItIsLoggingOrEditing() {
        #expect(InquiryCopy.intakeTitle(isEditing: false) == "Log an inquiry")
        #expect(InquiryCopy.intakeTitle(isEditing: true) == "Edit inquiry")
        #expect(InquiryCopy.intakeSaveButton(isEditing: false) == "Log inquiry")
        #expect(InquiryCopy.intakeSaveButton(isEditing: true) == "Save changes")
    }

    // The duplicate warning's second half has to match the button's verb: on an edit there is no
    // "this one" being added, and the clash is with ANOTHER inquiry, not the one on screen.
    @Test func theDuplicateWarningMatchesWhatTheButtonWillDo() {
        #expect(InquiryCopy.intakeDuplicateWarning(isEditing: false).contains("add this one"))
        #expect(InquiryCopy.intakeDuplicateWarning(isEditing: true).contains("save this one"))
        #expect(InquiryCopy.intakeDuplicateWarning(isEditing: true).hasPrefix("Another inquiry"))
    }

    @Test func stateReflectsLifecycle() {
        #expect(InquiryCopy.rowState(sentAt: nil, replied: false) == "Awaiting your first reply")
        #expect(InquiryCopy.rowState(sentAt: Date(), replied: false) == "Sent, waiting to hear back")
        #expect(InquiryCopy.rowState(sentAt: Date(), replied: true) == "They replied")
    }
}
