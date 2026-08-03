import Testing

// #1418: the "Why lost?" note used to save on every keystroke (a twelve-character note was twelve writes
// to the live store). It now saves on submit and on focus loss, and only when the text actually changed
// since the last save, so focusing an untouched field and leaving it writes nothing. The changed-guard is
// pure so it can be tested; the "when" (submit / focus loss, not per keystroke) is guarded at the source,
// since it lives in a SwiftUI view no unit test can reach (#863).
@Suite("Lost-reason note saves once, not per keystroke (#1418)")
struct LostReasonCommitTests {
    @Test func aChangedNoteSaves() {
        #expect(LostReasonCommit.shouldSave(current: "self-covered", lastSaved: ""))
        #expect(LostReasonCommit.shouldSave(current: "self-covered", lastSaved: "self"))
    }

    @Test func anUnchangedNoteDoesNotSaveAgain() {
        #expect(!LostReasonCommit.shouldSave(current: "self-covered", lastSaved: "self-covered"))
        #expect(!LostReasonCommit.shouldSave(current: "", lastSaved: ""))
    }
}

// The wiring the pure guard cannot see: the field must NOT save per keystroke, and MUST commit on both
// submit and focus loss. Guarded at the source because it lives inside DraftReviewView (#863).
@Suite("The lost-reason field commits on submit and focus loss, not per keystroke (#1418)")
struct LostReasonFieldWiringGuardTests {
    private func source(_ relativeFromMac: String, file: StaticString = #filePath) -> String {
        SourceGuardHelper.source(relativeFromMac, file: file)
    }

    private var view: String { source("Overture/UI/DraftReviewView.swift") }

    @Test func thereIsNoPerKeystrokeSaveOnTheLostReasonText() {
        #expect(!view.contains(".onChange(of: lostReason)"),
                "the lost-reason note must not save on every keystroke; commit on submit / focus loss")
    }

    @Test func itCommitsOnSubmitAndOnFocusLoss() {
        #expect(view.contains(".onSubmit { commitLostReason() }"))
        #expect(view.contains(".focused($lostReasonFocused)"))
        #expect(view.contains(".onChange(of: lostReasonFocused)"))
    }
}
