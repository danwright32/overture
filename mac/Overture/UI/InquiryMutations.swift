import Foundation
import SwiftData

// #1436: the inquiry actions that CHANGE something, moved out of QueueView, InquiryRowView, and
// InquiryReplySheet so each is a plain function a test can call (#863, the ExcludedTownMutations /
// WatchlistMutations idiom). Marking an inquiry booked or lost removes it from the queue on screen, so
// the write behind it has to be confirmed rather than attempted: the previous bare
// `try? context.save()` discarded a genuine failure and left the screen showing an outcome the store
// did not have. Persisting goes through the shared `saveOrWarn` (#618) rather than a fifth hand-rolled
// do/catch.
@MainActor
enum InquiryMutations {
    // Dan's two manual closes. Lost is the SOFT case: he is closing something that went quiet, which is
    // not a hard refusal, and #16's outcome reporting keeps the two apart.
    enum MarkAction: Equatable {
        case booked
        case lost

        var outcome: Outcome {
            switch self {
            case .booked: return .booked
            case .lost: return .lostSoft
            }
        }
    }

    // Returns whether the change is confirmed on disk. A false means Dan has already been warned and
    // the caller must not treat the inquiry as closed.
    @discardableResult
    static func mark(_ inquiry: Inquiry, as action: MarkAction, context: ModelContext,
                     feedback: ActionFeedback, now: Date = Date()) -> Bool {
        inquiry.markOutcomeManually(action.outcome, now: now)
        return context.saveOrWarn(org: inquiry.inquirerName, feedback: feedback)
    }

    // The reply sheet's Send enablement. An inquiry logged without an address cannot be replied to from
    // here at all, which is the case the sheet calls out in its header.
    static func canSend(email: String?, subject: String, body: String) -> Bool {
        guard let email, !email.isEmpty else { return false }
        return !subject.trimmingCharacters(in: .whitespaces).isEmpty
            && !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // Reply is the FIRST reply only. Answering again once they have written back is a different,
    // unbuilt thing (#1497), so the button must not imply it exists.
    static func showsReplyAction(sentAt: Date?) -> Bool { sentAt == nil }
}
