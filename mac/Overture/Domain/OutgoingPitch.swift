import Foundation

// #1630: the complete pitch as this contact receives it, greeting and all.
//
// This composition used to live inside SendService.deliver and nowhere else, which was fine while the
// only way a pitch left Overture was Gmail. It is not fine once Dan copies one into a contact form:
// `draftBody` is deliberately salutation-free (#393), so copying it hands him a pitch that opens cold
// with no name on it, and he either pastes it that way or retypes the opener every time.
//
// So both paths read this. What lands on the clipboard is by construction the same string the mail
// would have carried, and the two cannot drift.
enum OutgoingPitch {
    // nil when there is no body to send yet, the same condition that stops a send.
    static func text(for recipient: Recipient, of prospect: Prospect) -> String? {
        guard let body = recipient.effectiveBody, !body.isEmpty else { return nil }
        return Salutation.attnLine(for: recipient) + Salutation.greeting(for: recipient) + "\n\n" + body
    }
}
