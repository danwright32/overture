import Foundation

// #2113: who a reached-out row is ABOUT.
//
// The row stands on one contact per email (SendGroup.isRepresentative), chosen by lowest sorted id so it
// cannot shuffle between launches. That is the right way to pick a stable row and the wrong way to name
// a person: on Dan's Pumpkin Singalong card it put Chelsea on screen because "c" sorts before "n", while
// Nicole was the one who had written back.
//
// Pure and outside the view, because the line used to be an expression inside SwiftUI where nothing
// could test it.
enum ReplyIdentity {
    // The contact this row should name: whoever wrote back once somebody has, otherwise the contact Dan
    // pitched. Prefers the address over the display name, matching every other row in the queue, so the
    // fix changes WHO is named without changing how a row reads.
    static func rowContactLine(for recipient: Recipient, in prospect: Prospect) -> String {
        // Nobody has written back, or the row replied before the writer was ever recorded and the backfill
        // has not reached it. Either way the contact Dan pitched is the honest answer, and the row must
        // never go blank while waiting to learn better.
        guard recipient.replied, let writer = recipient.replyFromAddress, !writer.isEmpty else {
            return pitchedLine(recipient)
        }
        // The writer was one of the people emailed: name them the way every other row names a contact.
        if let peer = SendGroup.peers(of: recipient, in: prospect)
            .first(where: { ReplyDetection.isSameAddress($0.email, writer) }) {
            return pitchedLine(peer)
        }
        // Somebody nobody was written at. Shown as they wrote, rather than credited to a contact who did
        // not say it.
        return writer
    }

    private static func pitchedLine(_ r: Recipient) -> String {
        r.email ?? r.name ?? "no contact"
    }
}
