import Foundation

// #1436/#885: the inquiry views' computed copy lives here, beside a test, not inside a SwiftUI body
// where no test can reach it. Static labels stay in the views; only the sentences that fold in a value
// or choose between wordings belong here.
enum InquiryCopy {
    // #2675: the two send problems an inquiry can carry once its reply has gone out. Short enough for the
    // row's badge line, where the rest of its state lives, with the explanation on the hover: the badge
    // says what is wrong and the sentence says what it costs Dan and what to do instead.
    //
    // They mean what the shows roster means by the same two conditions, said for one inquiry rather than
    // for N shows. Deliberately NOT the roster's own sentences: those count ("3 shows sent, but ..."), and
    // an inquiry is not a show, so borrowing the wording would put the wrong noun on the row (L118).
    //
    // The worse of the two is the thread: an answer arrives and nothing notices it. The message id only
    // affects how OUR next message is filed, which is why they are two badges and not one.
    static let replyTrackingLostBadge = "Replies can't be tracked"
    static let replyTrackingLostHelp =
        "Your reply went out, but Gmail didn't tell Overture which conversation it landed in, so an answer to it won't be spotted automatically. Watch your inbox for this one and mark it here yourself."

    static let threadingDegradedBadge = "A nudge will arrive as a new email"
    static let threadingDegradedHelp =
        "Your reply went out and answers to it are still watched. What couldn't be read is the id a later message would quote, so a nudge on this inquiry will arrive as a separate email rather than under the same conversation."

    static func replyTitle(to inquirerName: String) -> String {
        "Reply to \(inquirerName)"
    }

    // #2145: what the subject line starts at, out of the view now that the shared reply screen takes it
    // as an input. An inquiry has no thread subject to answer into, so this is the one Dan edits.
    //
    // Deliberately NOT marked as outbound-only copy. It ends up on the wire, but he reads it in a field
    // and can change it, so it is a sentence the app says to him and belongs in the inventory.
    static let replySubjectDefault = "Re: your inquiry"

    // #1504: one sheet both logs an inquiry and corrects one, so every sentence in it has to say which
    // it is doing. "Log" wording on an edit would tell Dan he is about to add a second record.
    static func intakeTitle(isEditing: Bool) -> String {
        isEditing ? "Edit inquiry" : "Log an inquiry"
    }

    static func intakeSaveButton(isEditing: Bool) -> String {
        isEditing ? "Save changes" : "Log inquiry"
    }

    // The second half matches the button's verb: on an edit nothing is being added, and the clash is
    // with ANOTHER inquiry rather than the one on screen.
    static func intakeDuplicateWarning(isEditing: Bool) -> String {
        isEditing
            ? "Another inquiry is already logged for this event. You can still save this one."
            : "You've already logged an inquiry for this event. You can still add this one."
    }

    // "Gala at Weill Recital Hall", or whichever parts are known, or empty when neither is.
    static func rowSubtitle(event: String, venue: String?) -> String {
        let e = event.trimmingCharacters(in: .whitespaces)
        let v = venue?.trimmingCharacters(in: .whitespaces) ?? ""
        switch (e.isEmpty, v.isEmpty) {
        case (false, false): return "\(e) at \(v)"
        case (false, true): return e
        case (true, false): return "at \(v)"
        case (true, true): return ""
        }
    }

    // The one-line lifecycle state shown on the row.
    static func rowState(sentAt: Date?, replied: Bool) -> String {
        if sentAt == nil { return "Awaiting your first reply" }
        if replied { return "They replied" }
        return "Sent, waiting to hear back"
    }
}
