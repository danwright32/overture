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
}
