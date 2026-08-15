import Foundation

// What the reply screen is about: the show and the peer who wrote. A struct rather than the two ids, so the
// sheet never has to look anything up and cannot land on a different row than the one Dan pressed.
struct ReplyTarget: Identifiable {
    let prospect: Prospect
    let recipient: Recipient
    var id: String { prospect.naturalKey + "|" + recipient.id }
}

// #2718: which pitch the manual "Link their reply" picker is open for. Its own type rather than reusing
// ReplyTarget above, because that one names a conversation being ANSWERED and this one names a pitch with
// no conversation at all: one word meaning two things is how a sheet ends up opened on the wrong row.
struct ManualLinkTarget: Identifiable {
    let prospect: Prospect
    let recipient: Recipient
    var id: String { prospect.naturalKey + "|" + recipient.id }
}

// #2144: the composed reply held while Dan reads it. A wrapper only because SendConfirmation carries no
// identity of its own and `.sheet(item:)` needs one, the same reason PendingRowNudge below has an id.
struct PendingReply: Identifiable {
    let confirmation: SendConfirmation
    var id: String { confirmation.recipient + "|" + confirmation.subject }
}

// #2130: the nudge or closing note the reached-out row is about to send, held while Dan approves it.
struct PendingRowNudge: Identifiable {
    let naturalKey: String
    let recipientId: String
    let confirmation: SendConfirmation
    let isClosing: Bool
    // Which sender it goes through. The two write different emails, so the confirmation Dan reads and the
    // send that follows have to agree about which one this is.
    let isConversation: Bool
    var id: String { naturalKey + "|" + recipientId }
}
