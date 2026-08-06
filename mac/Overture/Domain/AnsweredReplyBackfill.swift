import Foundation
import SwiftData

// #2190: repair the replies Dan answered BEFORE the answered stamp existed.
//
// #2170 added `Recipient.replyHandledAt` and merged at 21:38:57 on 2026-08-05. Dan had answered the
// Pumpkin Singalong reply at 18:49:38 that same day. The answer was recorded, but the field that means
// "Dan answered" did not exist yet, so nothing wrote it and `hasUnhandledReply` read the empty field as a
// no. The row went on asking for work he had done, and went on feeding the Dock badge, the OmniFocus task
// and the conversation reminder with it.
//
// Selected by the defect's SIGNATURE rather than by the field being empty (L68): an empty stamp is the
// ordinary state of every reply genuinely still waiting, and a pass keyed on emptiness would bury them
// all. The signature is an answer demonstrably sent on this conversation, later than the reply arrived.
// `replySentAt` is only ever written by `freezeSentReply`, whose one caller is `recordAnswerSent`, so it
// cannot be produced by anything except an answer that actually went out.
//
// Dated to that stored instant rather than to the clock at migration time (L74). A stamp of "now" would
// read as answered today for an answer sent days ago, and would also swallow a reply that arrived in
// between instead of leaving it to re-open the row.
enum AnsweredReplyBackfill {
    @discardableResult
    static func run(in context: ModelContext) -> Int {
        let prospects = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        var changed = 0
        for p in prospects {
            for r in p.recipients where r.replyHandledAt == nil {
                guard r.hasUnhandledReply else { continue }
                guard let answered = answerInstant(for: r, in: p) else { continue }
                // Only an answer sent AFTER their message: an earlier one belongs to a previous round of
                // the conversation and says nothing about the message now waiting.
                guard let arrived = r.replyArrivedAt, answered > arrived else { continue }
                r.replyHandledAt = answered
                changed += 1
            }
        }
        return changed
    }

    // When this contact's conversation was answered: its own send, or a peer's on the same incoming reply.
    // The same reply-id key #2191 fans out on, so the repair and the rule that replaces it agree about what
    // one conversation is.
    private static func answerInstant(for recipient: Recipient, in prospect: Prospect) -> Date? {
        SendGroup.peers(of: recipient, in: prospect)
            .filter { $0.id == recipient.id || $0.lastReplyId == recipient.lastReplyId }
            .compactMap(\.replySentAt)
            .max()
    }
}
