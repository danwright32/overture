import Foundation

// The exact text that leaves, for one recipient or for a group sharing one email. Both the Gmail send
// path and the copy-into-a-contact-form path read this, so the two can never drift.
//
// #2545: it is the body, and nothing else. Overture used to compose an opening above it (the `Attn:`
// block and a greeting, per recipient or per group), which meant a greeting could come from two places
// and the app could not tell which one Dan meant. His words, 2026-08-11, on a card showing both: "I want
// to eliminate the appended greeting. It should just be included in the AI prep or manual prep where I
// write it myself. It's confusing to have it there twice." The greeting is now written into the body by
// whoever writes the body, and `Recipient.isBlockedByGreeting` holds a body that forgot one.
//
// The signature still takes the prospect it no longer reads, because every caller has one and the
// symmetry with the group form is worth more than the parameter is worth removing.
enum OutgoingPitch {
    static func text(for recipient: Recipient, of prospect: Prospect) -> String? {
        guard let body = recipient.effectiveBody, !body.isEmpty else { return nil }
        return body
    }

    static func text(forGroup recipients: [Recipient], of prospect: Prospect) -> String? {
        guard !recipients.isEmpty else { return nil }
        // One email cannot carry two different letters. A performer's own override body is what makes
        // this differ, and it is why such a show sends separately rather than jointly.
        let bodies = Set(recipients.map { $0.effectiveBody ?? "" })
        guard bodies.count == 1, let body = bodies.first, !body.isEmpty else { return nil }
        return body
    }
}
