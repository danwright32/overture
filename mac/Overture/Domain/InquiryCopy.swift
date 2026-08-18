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

    // #2712: Overture found this inquiry's conversation in Gmail rather than starting it with a send of
    // its own, and has begun watching it. Said on the row because Overture changed what this inquiry is on
    // the strength of something it read in his mailbox, and nothing else on the row carries that: the
    // state line says whether he has answered, never how Overture came to know.
    //
    // Nil until there is a conversation to say it about, so an ordinary inquiry gains no line it does not
    // need (#843). The badge is the fact and the help is the consequence, the same split the two send
    // problems below it use.
    static func foundInGmailBadge(attachedAt: Date?) -> String? {
        attachedAt == nil ? nil : "Found in Gmail"
    }

    // Says only what the stamp actually measures. "Overture didn't email them" was in an earlier draft
    // and is not true of every row this fires on: a send whose thread id Gmail never returned
    // (`replyTrackingLostBadge`) is recovered by the same pass, and Overture very much did email that one.
    static let foundInGmailHelp =
        "Overture found this conversation in your Gmail, from the address you logged, and is watching it for replies."

    // The one-line lifecycle state shown on the row.
    //
    // #2943: four states now, not three. Answering an inquiry used to be recorded by clearing `replied`,
    // so this line went back to "Sent, waiting to hear back", word for word what it says for an inquiry
    // nobody ever wrote back to. A live negotiation and total silence read identically, which is #2919's
    // finding on the scouted half arriving here by a worse route: there the exchange was unreported, here
    // it was destroyed.
    //
    // `answeredReplyLine` is rendered by `AnsweredReplyNote`, the SAME function the scouted row's line
    // comes from, rather than a wording of this file's own. The two kinds of row sit in one list under one
    // set of date headings, and one exchange described in two sets of words is the collision that only
    // shows up when they are read together (L118). Nil is the whole of the empty branch: no heading over
    // an absence, no placeholder, just the state this row was already in.
    //
    // It is a rendered sentence rather than two dates because this row is a pure snapshot taken against
    // one `now` (see `QueueModel.inquiryRows`), the same reading `followUpNudgeDue` and
    // `shouldSuggestClosing` already arrive as, so the view holds no clock of its own.
    static func rowState(sentAt: Date?, replied: Bool, answeredReplyLine: String?) -> String {
        if sentAt == nil { return "Awaiting your first reply" }
        if let answeredReplyLine { return answeredReplyLine }
        if replied { return "They replied" }
        return "Sent, waiting to hear back"
    }
}
