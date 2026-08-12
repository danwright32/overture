import Foundation

// #2546: why a row's send button is refusing, for the send controls that gate on the same two facts,
// whether Gmail is connected and whether the contact this row stands on has an address to send to.
//
// Both call sites had the defect #2544 named, in two different shapes.
//
// FollowUpsView's "Send nudge" and "Send closing note" already gated on exactly these two
// (`gmailConnected && r.email != nil`) and showed nothing at all, while the tooltip they shared read
// "Review and send" whenever Gmail was connected. So the single sentence on offer was actively wrong for
// the one cause it could not name: a contact with no address got a grey button and a tooltip promising
// it would send (L11, distinct causes get distinct messages).
//
// ReplyConversationView's "Send reply" gated on Gmail alone, so a contact with no address reached
// SendService.sendReplyDraft, whose first line refuses a blank address by returning false. The press was
// impossible before it happened and reported as nothing at all, which is the thing L67 is about: code
// that has already detected a missing required value must block the action, not let it run and fail.
//
// One predicate, three readings (the disabled state, the sentence beside the button, the help and the
// VoiceOver hint), so a grey button and the words next to it cannot disagree (L109). Same shape #2544
// settled on for the manual prep sheet.
enum SendGate {
    // Deliberately NOT ReplyPanelCopy.refusalLine's vocabulary, which is a different surface's answer to
    // a different question: it returns nil for its own no-audience case on purpose, because ReplySheet's
    // header two lines above already reads "No address to reply to". These rows carry no such header, so
    // borrowing that answer would put the silent grey button straight back.
    //
    // Also not DraftReviewNotes.noSendableEmail ("No email to send to. Add a contact by hand."), which is
    // the Review screen's sentence about a SHOW carrying no emailable contact anywhere and names the fix
    // available there. This is about the one contact whose row this is, and the fix is not on this row,
    // so it states the fact rather than promising an action that is not here (L111, #843).
    static let noAddressReason = "No email address for this contact"

    enum Refusal: Equatable {
        case noAddress
        case gmailNotConnected

        // What the button is refusing, true BEFORE any press, so it never reports on a send that has not
        // happened. #2544's rule: only an acknowledgement may say what became of a press.
        var reason: String {
            switch self {
            case .noAddress: return SendGate.noAddressReason
            // The sentence the rest of the app already uses for this, rather than a second wording of it
            // (#843). DraftReviewView and ReplySheet both say exactly this.
            case .gmailNotConnected: return GmailCopy.notConnected
            }
        }
    }

    // One definition of "there is somewhere to send this", because the two FollowUpsView buttons had two:
    // the nudge asked `email?.isEmpty == false` and the closing note asked `email != nil`, so a contact
    // holding an empty-string address was refused by one button and offered by the other, which then hit
    // SendService's own blank-address refusal and did nothing (L16).
    static func hasAddress(_ email: String?) -> Bool {
        !(email ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // The missing address is named first when both are true. It is the fact about the row Dan is looking
    // at and it survives connecting Gmail, so naming Gmail first would change the sentence under him and
    // still leave the button grey.
    static func refusal(gmailConnected: Bool, hasAddress: Bool) -> Refusal? {
        if !hasAddress { return .noAddress }
        if !gmailConnected { return .gmailNotConnected }
        return nil
    }

    // What the row shows beside the button while it is grey. Nil exactly when the button works, so a live
    // reason and a working button are mutually exclusive by construction rather than by agreement.
    static func reason(gmailConnected: Bool, hasAddress: Bool) -> String? {
        refusal(gmailConnected: gmailConnected, hasAddress: hasAddress)?.reason
    }

    static func canSend(gmailConnected: Bool, hasAddress: Bool) -> Bool {
        refusal(gmailConnected: gmailConnected, hasAddress: hasAddress) == nil
    }
}
