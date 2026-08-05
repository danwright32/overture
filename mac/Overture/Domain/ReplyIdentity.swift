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
    static func rowAudience(for recipient: Recipient, in prospect: Prospect) -> RowAudience {
        let addresses: [String] = recipient.hasUnhandledReply
            ? SendGroup.replyAudience(of: recipient)
            : SendGroup.peers(of: recipient, in: prospect).compactMap(\.email).filter { !$0.isEmpty }

        // Nothing emailable (a form outreach, a record with no address). The row still has to name
        // something rather than leave a gap where a contact belongs.
        guard !addresses.isEmpty else {
            return RowAudience(lines: [pitchedLine(recipient)], responder: nil)
        }
        // Matched through reply detection's own comparison, so casing or a display name on the stored
        // writer cannot make them fail to match their own line and silently lose the highlight.
        let responder = recipient.replyFromAddress.flatMap { writer in
            addresses.first { ReplyDetection.isSameAddress($0, writer) }
        }
        return RowAudience(lines: addresses, responder: responder)
    }

    private static func pitchedLine(_ r: Recipient) -> String {
        r.email ?? r.name ?? "no contact"
    }
}
