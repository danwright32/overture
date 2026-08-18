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
        #expect(InquiryCopy.rowState(sentAt: nil, replied: false, answeredReplyLine: nil)
                    == "Awaiting your first reply")
        #expect(InquiryCopy.rowState(sentAt: Date(), replied: false, answeredReplyLine: nil)
                    == "Sent, waiting to hear back")
        #expect(InquiryCopy.rowState(sentAt: Date(), replied: true, answeredReplyLine: nil)
                    == "They replied")
    }

    // #2943: the fourth state, which used to be word for word the second one. An answered inquiry read
    // "Sent, waiting to hear back", identical to one nobody ever wrote back to, because the answer was
    // recorded by clearing the reply.
    @Test func anAnsweredExchangeSaysSoRatherThanReadingAsSilence() {
        let answered = "Replied Aug 14, you answered Aug 15"
        #expect(InquiryCopy.rowState(sentAt: Date(), replied: true, answeredReplyLine: answered)
                    == answered)
    }

    // A row Dan has not sent anything on cannot have answered anything, so the first branch still wins:
    // the states are ordered, not a set of independent tests.
    @Test func nothingSentStillReadsAsAwaitingHisFirstReply() {
        #expect(InquiryCopy.rowState(sentAt: nil, replied: true,
                                     answeredReplyLine: "Replied Aug 14, you answered that day")
                    == "Awaiting your first reply")
    }
}
