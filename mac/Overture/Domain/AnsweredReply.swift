import Foundation

// #2191: recording that Dan answered, across the whole conversation his answer was on.
//
// Deliberately a seam above `Recipient.recordAnswerSent`, which is a method on ONE contact and therefore
// structurally unable to reach the peers detection already marked. Both ways of answering (the in-app send
// and the copy-out path) come through here, so the fan-out cannot land on one of them.
enum AnsweredReply {
    static func record(on recipient: Recipient, in prospect: Prospect, now: Date) {
        // The member facts first, on the one contact that actually sent: the frozen body, the send time,
        // the consumed draft. Those must not travel, or a colleague's record claims words they never sent.
        recipient.recordAnswerSent(now: now)

        // And the group fact. Keyed on the reply's own id rather than on the send group alone, because a
        // colleague may have written something of their own on that group, and answering Nicole says
        // nothing about it. No id recorded means nothing proves it is the same message, so it is left
        // asking: a row that keeps asking costs Dan a glance, a row cleared wrongly hides a real reply.
        guard let answered = recipient.lastReplyId, !answered.isEmpty else { return }
        for peer in SendGroup.peers(of: recipient, in: prospect)
        where peer.id != recipient.id && peer.lastReplyId == answered {
            peer.markReplyAnswered(now: now)
        }
    }
}
