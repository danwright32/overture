import Foundation

// #2934: what the reply block offers for one conversation.
//
// `ReplyConversationView` is drawn by both the reached-out queue and the Archive card, and it chose
// between its states from its own reading of the reply fields, none of which asked whether the
// conversation had already been ANSWERED. An answered conversation is still `replied`, so the block came
// up with its "Draft a reply" button on the Archive card.
//
// Since #2921 the queue builder refuses an answered conversation, so that button stamps the request,
// launches the paid run, and the run correctly finds nothing for the row. It then reads "Drafting a
// reply" until the timeout flips it to the stuck state, whose Retry does the same thing again. A control
// that cannot do anything, with no sentence saying why (L109, L148). Before #2921 it "worked" by drafting
// a reply to a message Dan had already answered, which is the spend #2921 exists to stop, so the fix is
// not to let the run through again.
//
// Decided here rather than in the view, so both surfaces read one rule and a test can reach it (the
// "decide purely, keep the SwiftUI row dumb" pattern the contact row already follows).
enum ReplyConversationMode: CaseIterable, Equatable, Sendable {
    /// A reply nobody has answered and no draft yet: offer to draft one.
    case offerADraft
    /// A draft was asked for and has not arrived.
    case drafting
    /// A draft is here, on a conversation still owed an answer: send, copy or edit it.
    case draftReadyToSend
    /// Answered, and a draft was written along the way: keep the text as a record, with no way to send
    /// a second answer.
    case answeredDraftAsRecord
    /// Answered, with nothing written: the block has nothing to draw but the reason.
    case answeredNothingToShow
    /// Not owed an answer for some other reason (the contact was stood down, the address bounced). The
    /// record stays; nothing claims an answer was given, because none was.
    case closedDraftAsRecord
    case closedNothingToShow

    static func of(hasUnhandledReply: Bool, replyIsAnswered: Bool,
                   hasReplyDraft: Bool, isDrafting: Bool) -> ReplyConversationMode {
        if hasUnhandledReply {
            if hasReplyDraft { return .draftReadyToSend }
            return isDrafting ? .drafting : .offerADraft
        }
        // Nothing below may offer a control, whatever the request stamps say: a request left over from an
        // exchange that has since been answered is not a live run, and this is where that ends.
        if replyIsAnswered { return hasReplyDraft ? .answeredDraftAsRecord : .answeredNothingToShow }
        return hasReplyDraft ? .closedDraftAsRecord : .closedNothingToShow
    }

    /// The button that asks for a paid drafting run. Exactly one mode carries it.
    var offersToDraft: Bool { self == .offerADraft }

    /// The "drafting a reply" progress, and the stuck state that follows it.
    var showsDraftingProgress: Bool { self == .drafting }

    /// Send, copy and edit, which act on a conversation still owed an answer.
    var offersToSend: Bool { self == .draftReadyToSend }

    /// The stored draft text, with or without the controls beside it.
    var showsDraftText: Bool {
        switch self {
        case .draftReadyToSend, .answeredDraftAsRecord, .closedDraftAsRecord: return true
        case .offerADraft, .drafting, .answeredNothingToShow, .closedNothingToShow: return false
        }
    }

    /// Why there is nothing to press, said only where Overture actually knows the answer was given.
    ///
    /// The closed modes say NOTHING on purpose: "you already answered" would be false of a contact stood
    /// down or a bounced address, and a message may claim only what its check measured (L11).
    var explanation: String? {
        switch self {
        case .answeredDraftAsRecord:
            return "You already answered this one. The draft below is kept as a record."
        case .answeredNothingToShow:
            return "You already answered this one."
        case .offerADraft, .drafting, .draftReadyToSend, .closedDraftAsRecord, .closedNothingToShow:
            return nil
        }
    }
}
