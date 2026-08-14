import Foundation

// #2113/#2121: who a reached-out row is ABOUT.
//
// The row stands on one contact per email (SendGroup.isRepresentative), chosen by lowest sorted id so it
// cannot shuffle between launches. That is the right way to pick a stable row and the wrong way to name
// a person: on Dan's Pumpkin Singalong card it put Chelsea on screen because "c" sorts before "n", while
// Nicole was the one who had written back.
//
// Pure and outside the view, because the line used to be an expression inside SwiftUI where nothing
// could test it.
enum ReplyIdentity {
    // #2121: everyone the row's NEXT email reaches, and which of them wrote the reply being answered.
    struct RowAudience: Equatable {
        // Never empty. Falls back to the contact pitched so a row can never render as a blank gap.
        let lines: [String]
        // The writer of the latest reply, only when they are actually one of the lines above. A highlight
        // pointing at nobody reads as no highlight rather than as a fault, so it is not offered.
        let responder: String?

        // What a screen reader says for one line. The highlight is weight and colour, and neither reaches
        // somebody listening, so for that one line the mark has to be in the words. Lives here rather than
        // in the view because the view may not compose copy (ViewCopyGuardTests), and because this is a
        // sentence Dan's Mac can say out loud, so it belongs in the copy inventory like any other.
        func spokenLabel(for address: String) -> String {
            address == responder ? "\(address), replied" : address
        }
    }

    // Dan, 2026-08-05: "I want to know if I'm emailing 1 or 5 people and who I'm responding to."
    //
    // Which audience that is depends on what the row's next email IS, and both answers are taken from the
    // send paths rather than decided again here, so the row cannot promise an audience the send will not
    // use (L64): a reply goes to SendGroup.replyAudience, a follow-up or conversation nudge goes to the
    // whole send group.
    // The peer this row's reply is actually ABOUT.
    //
    // The list stands on SendGroup.isRepresentative, which is lowest sorted id and knows nothing about who
    // wrote. Detection files the reply's words and its audience on the WRITER alone (ReplyService.swift,
    // `if wroteIt`), deliberately, so nothing is credited to somebody who did not say it. Those two facts
    // together mean the row is routinely standing on a contact who holds neither: on Dan's Pumpkin
    // Singalong card the row is Chelsea and everything about the reply is on Nicole.
    //
    // Resolved through the writer recorded on every peer (#2113), so any row of the group answers the same.
    static func answering(for recipient: Recipient, in prospect: Prospect) -> Recipient {
        guard recipient.hasUnhandledReply, let writer = recipient.replyFromAddress, !writer.isEmpty else {
            return recipient
        }
        return SendGroup.peers(of: recipient, in: prospect)
            .first { ReplyDetection.isSameAddress($0.email, writer) } ?? recipient
    }

    static func rowAudience(for recipient: Recipient, in prospect: Prospect) -> RowAudience {
        // Everything below asks the peer who WROTE, not the peer the list happens to stand on.
        let answerer = answering(for: recipient, in: prospect)
        // #2716: a form or DM pitch that nobody has answered has no next email AT ALL, so there is no
        // audience to name. That was invisible while such a contact had no address; #2715 saves the one
        // the presenter wrote from, and listing it here would promise a send that does not exist, on a
        // route Overture cannot take (L64). The row names where the pitch actually WENT instead.
        //
        // Only until they write back: an answer is a real send, and it goes to the address they used, so
        // the reply audience below is exactly right from that moment on.
        if recipient.outreachChannel == .contactForm, !answerer.hasUnhandledReply {
            return RowAudience(lines: [pitchedLine(recipient)], responder: nil)
        }
        let addresses: [String] = answerer.hasUnhandledReply
            ? SendGroup.replyAudience(of: answerer)
            : SendGroup.peers(of: recipient, in: prospect).compactMap(\.email).filter { !$0.isEmpty }

        // Nothing emailable (a form outreach, a record with no address). The row still has to name
        // something rather than leave a gap where a contact belongs.
        guard !addresses.isEmpty else {
            return RowAudience(lines: [pitchedLine(recipient)], responder: nil)
        }
        // Matched through reply detection's own comparison, so casing or a display name on the stored
        // writer cannot make them fail to match their own line and silently lose the highlight.
        let responder = answerer.replyFromAddress.flatMap { writer in
            addresses.first { ReplyDetection.isSameAddress($0, writer) }
        }
        return RowAudience(lines: addresses, responder: responder)
    }

    // #2169: what this row's slot says when there is no address to list.
    //
    // Dan, reading the Alex Syiek row cold: "why does it say 'no contact' and 'sent through their form'".
    // A form pitch has nothing emailable, so this fell through to "no contact" while the record it renders
    // from was holding the form URL it was sent to the whole time, and the line below said so. A line may
    // claim only what its check measured, and what was measured is "no email address" (L11).
    //
    // The route comes first for a form pitch, ahead of any stored name: on the two live rows that carry a
    // name, a bare "Reeve Carney" reads as an emailable person whose address is merely not shown, which is
    // the same gap in a politer font. "no contact" survives only for a record with neither, which on the
    // live store today is no row at all.
    //
    // #2716: and the route leads for a form pitch, ahead of the address too. Until this milestone a form
    // pitch had no address and the ordering could not be observed; an attach saves one, and the
    // email-first ordering would then silently swap the host Dan recognises for a stranger's gmail
    // address on the card he triages from.
    private static func pitchedLine(_ r: Recipient) -> String {
        if r.outreachChannel == .contactForm,
           let route = FormOutreachCopy.routeLine(formURL: r.formOutreachURL) { return route }
        if let email = r.email, !email.isEmpty { return email }
        if let route = FormOutreachCopy.routeLine(formURL: r.formOutreachURL) { return route }
        return r.name ?? "no contact"
    }
}
