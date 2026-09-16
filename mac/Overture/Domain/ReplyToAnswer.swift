import Foundation
import SwiftData

// #3890: a conversation where somebody wrote back and is waiting on Dan's answer, as one row of due work.
//
// The Dock badge and the menu bar count state `DueWork.Counts.total`, and from #2397 (2026-08-10) until
// this, nothing in that total was a reply: three people were waiting on an answer on 2026-09-14 and both
// surfaces read 0, while the Reached out pill inside the app said "3 due". Dan's call, 2026-09-15: replies
// JOIN the Due list, so the badge is still one derivation with a row behind every unit of it (L16).
//
// Waiting is `hasUnhandledReply` on both kinds of conversation, the predicate the Answer button and the
// Reached out pill already ask, and never a comparison against when Overture RECORDED a reply: #3890
// measured that reading finding 6 on a store where 3 were waiting, because a reply answered before
// Overture noticed it is recorded after its own answer.
enum ReplyToAnswer {
    // A scouted show's conversation or a hire inquiry. The two are separate entities with no relationship
    // (AGENTS.md), so they are two cases rather than one record pretending to be both.
    enum DueConversation {
        // `recipient` is the contact who WROTE (`ReplyIdentity.answering`), which is who the answer goes
        // to and who the row names, never whichever member of a joint email sorts first.
        case show(prospect: Prospect, recipient: Recipient)
        case inquiry(Inquiry)

        // When their message arrived, which orders the list: whoever has waited longest is first.
        var arrivedAt: Date? {
            switch self {
            case .show(_, let recipient): return recipient.replyArrivedAt
            case .inquiry(let inquiry): return inquiry.replyArrivedAt
            }
        }

        // The row's identity on screen, stable across rebuilds.
        var id: AnyHashable {
            switch self {
            case .show(let prospect, let recipient): return "\(prospect.naturalKey)|\(recipient.id)"
            case .inquiry(let inquiry): return inquiry.persistentModelID
            }
        }
    }

    // One row per CONVERSATION. Reply detection records a reply on every contact sharing the thread
    // (`ReplyService`, #2113), so a joint email one person answered holds several contacts that each
    // read as waiting, and counting contacts would state that one reply as several.
    //
    // A show is asked through `Prospect.hasUnhandledReply` first, so the booked exclusion that rollup has
    // always applied is the same one here rather than a second copy of it (L16).
    static func dueConversations(prospects: [Prospect], inquiries: [Inquiry]) -> [DueConversation] {
        var due: [DueConversation] = []
        for p in prospects where p.hasUnhandledReply {
            let waiting = p.recipients.filter(\.hasUnhandledReply)
            for member in SendGroup.oneRowPerGroup(waiting, recipient: { $0 }) {
                due.append(.show(prospect: p, recipient: ReplyIdentity.answering(for: member, in: p)))
            }
        }
        due.append(contentsOf: inquiries.filter(\.hasUnhandledReply).map { .inquiry($0) })
        return due.sorted { ($0.arrivedAt ?? .distantPast) < ($1.arrivedAt ?? .distantPast) }
    }
}

// #3890: what the replies section says on screen. Beside the rule rather than inside the view, so the
// sentences Dan reads are testable and appear in the copy inventory for a cold read.
enum ReplyToAnswerCopy {
    static let section = "Replies to answer"

    // How long they have been waiting, in words that change with the wait, so a message from an hour ago
    // and one from last week do not read alike. The row's other lines already say who and which show.
    static func line(arrivedAt: Date, now: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return "Wrote back \(f.localizedString(for: arrivedAt, relativeTo: now))"
    }

    // Said where nothing is due, so the sheet's empty state names every subject it holds (L11). It follows
    // the stalled draft sentence, which ends "appears here too", and reads as its continuation.
    static let nothingWaiting = "So does anyone who wrote back and is waiting on your answer."
}
