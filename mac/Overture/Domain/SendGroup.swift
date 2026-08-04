import Foundation

// #2033: the contacts that received the SAME email.
//
// One definition, because eleven surfaces need it and each of them was written when one contact meant
// one email. A shared thread makes them all wrong in a different way (two nudge buttons for one
// conversation, two OmniFocus tasks, a cap spent twice), and eleven private answers to the same question
// would drift the moment one of them was updated.
enum SendGroup {
    // Everyone who received this contact's email, including them, in a stable order.
    //
    // A contact who received their own email is a group of ONE rather than a special case, so a caller
    // never has to ask whether a group exists.
    static func peers(of recipient: Recipient, in prospect: Prospect) -> [Recipient] {
        guard let id = recipient.sendGroupId, !id.isEmpty else { return [recipient] }
        return prospect.recipients.filter { $0.sendGroupId == id }.sorted { $0.id < $1.id }
    }

    // The one contact that stands for the group wherever a LIST would otherwise show it once per person.
    // Stable (lowest id) rather than "whoever is first in the relationship", because SwiftData's to-many
    // is unordered and a row that moves between launches reads as a different row.
    static func isRepresentative(_ recipient: Recipient, in prospect: Prospect) -> Bool {
        peers(of: recipient, in: prospect).first?.id == recipient.id
    }

    // #2033: the contacts the NEXT press of Send will email, which is the pre-send half of the same
    // question `peers` answers after the fact. One definition, so the card, the confirmation and the send
    // itself cannot disagree about who is about to be written to.
    //
    // Held contacts are excluded by `isSendablePending`, so a contact waiting on Dan's glance is never
    // quietly folded into somebody else's email.
    static func pendingGroup(of prospect: Prospect) -> [Recipient] {
        // The SHOW-level gate, the same one `SendService.nextPendingRecipient` applies: an unapproved draft
        // sends to nobody, whatever its contacts look like. Without this a card would name contacts on a
        // draft Dan has not approved, and a joint send would email them.
        guard prospect.status == .approved, prospect.draftBody != nil else { return [] }
        let sendable = prospect.recipients
            .filter(\.isSendablePending)
            .sorted { $0.sendOrderRank != $1.sendOrderRank ? $0.sendOrderRank < $1.sendOrderRank : $0.id < $1.id }
        guard prospect.sendsTogether else { return Array(sendable.prefix(1)) }
        return sendable
    }
}
