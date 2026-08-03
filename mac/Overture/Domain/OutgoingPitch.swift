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
    // #2010: TWO visible pieces, and nothing else. The opening is the field Dan reads and can edit; the
    // body is the box he writes in. This function may never add a third thing, because anything it adds
    // is by definition invisible to the person approving the email (L64).
    //
    // It used to compose the greeting and the `Attn:` line here, which meant a draft he read and approved
    // was not the string that went out, and a greeting he typed into the body sent twice.
    //
    // nil when there is no body to send yet, the same condition that stops a send.
    static func text(for recipient: Recipient, of prospect: Prospect) -> String? {
        guard let body = recipient.effectiveBody, !body.isEmpty else { return nil }
        return recipient.outgoingOpening + "\n\n" + body
    }

    // #2031: the same email, for several people at once. Nil when there is no single email to compose,
    // which is either no body at all or a group whose members would not read the same words.
    static func text(forGroup recipients: [Recipient], of prospect: Prospect) -> String? {
        guard !recipients.isEmpty else { return nil }
        // Body EQUALITY, not provenance. Measured on the live prep handoff 2026-08-03: the one show
        // waiting there has three contacts, all of them performers, each carrying a DIFFERENT letter. A
        // rule phrased as "a performer beside a non-performer" would wave that through and send one
        // person's letter, greeting them by name, to all three.
        let bodies = Set(recipients.map { $0.effectiveBody ?? "" })
        guard bodies.count == 1, let body = bodies.first, !body.isEmpty else { return nil }
        return JointOpening.text(for: recipients, of: prospect) + "\n\n" + body
    }
}
