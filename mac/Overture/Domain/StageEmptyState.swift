import Foundation

// #1134: with stage-only navigation the queue opens on Scout and any stage can be empty on its own. An
// empty stage must never leave Dan staring at a blank screen: it says what the stage is, and (this is
// the point of #1134's decision 3) when the stage he is on is empty, it points him to the next stage
// that actually has work rather than auto-jumping there for him.
//
// The pointer logic lives here, not inside the SwiftUI view, so it can be tested at all (the #863
// lesson: a rule computed inside a view has no seam a test can reach).
enum StageEmptyState {
    struct Message: Equatable, Sendable {
        var title: String
        var detail: String
    }

    // The stages Dan works, in order, so the pointer sends him to the EARLIEST one holding work.
    // #1583/#1691: `.prepBlocked` sits right after `.prep`, so an otherwise-empty queue still points Dan at
    // a show stuck behind a date clash. It is the one focus that cannot resolve itself: everything else in
    // this list moves on when a run finishes or an email goes out, while a blocked show waits on an answer
    // only he can give, and it was reachable from nowhere at all before it had a stage.
    static let pointerOrder: [StageFocus] = [.scout, .prep, .prepBlocked, .review, .reachedOut]

    static func message(for stage: StageFocus, counts: [StageFocus: Int], reachedOut: Int) -> Message {
        let detail = pointer(excluding: stage, counts: counts, reachedOut: reachedOut)
            ?? restingDetail(for: stage)
        return Message(title: title(for: stage), detail: detail)
    }

    // The first stage (other than the one shown) that has work, phrased as a nudge toward it.
    private static func pointer(excluding stage: StageFocus, counts: [StageFocus: Int],
                                reachedOut: Int) -> String? {
        for target in pointerOrder where target != stage {
            let n = target == .reachedOut ? reachedOut : (counts[target] ?? 0)
            if n > 0 { return "You have \(pointerPhrase(for: target, count: n)) next." }
        }
        return nil
    }

    private static func pointerPhrase(for target: StageFocus, count: Int) -> String {
        switch target {
        case .scout: return "\(Plural.count(count, "show")) to triage"
        case .prep: return "\(Plural.count(count, "show")) to prep"
        case .prepBlocked: return "\(Plural.count(count, "show")) held by a date clash"
        // #2050: shows, not drafts. An approved show waiting to send is counted here too now.
        case .review: return "\(Plural.count(count, "show")) to review"
        case .reachedOut: return "\(Plural.count(count, "show")) you've pitched"
        default: return Plural.count(count, "show")
        }
    }

    // The reached-out stage renders reachedOutList (which owns its own empty copy), so message() is never
    // called for .reachedOut here; only pointerPhrase(.reachedOut) is reachable (pointing TO it from
    // another empty stage). The default arm covers the send focuses, which can empty out while focused.
    private static func title(for stage: StageFocus) -> String {
        switch stage {
        case .scout: return "Nothing new to triage"
        case .prep: return "Nothing to prep yet"
        case .prepBlocked: return "Nothing held by a date clash"
        case .review: return "Nothing to review"
        default: return "Nothing here right now"
        }
    }

    // Shown only when there is no work anywhere to point at, so it explains what the stage is for.
    // #1195/#843: the send focuses (the default arm) have no single purpose to explain (each names a
    // different problem: an unconfirmed send, a failed one, one that cannot be watched, a held contact,
    // an approved email waiting on a click), so there is nothing a resting line could add that the title
    // "Nothing here right now" does not already say. It returns empty, and the view shows the title alone
    // rather than restating it with a generic "Nothing waiting on you here."
    private static func restingDetail(for stage: StageFocus) -> String {
        switch stage {
        case .scout: return "New finds land here to keep or dismiss."
        case .prep: return "Keep a show from Scout and it lands here to prep."
        // Says what puts a show here, which is not something Dan does: he kept it, and a booking landed on
        // that night afterwards. Without that, an empty stage he never navigated to himself reads as a
        // stage he is somehow failing to feed.
        // "a clash with your calendar", not "if you're booked that night": a clash is equally a day off Dan
        // typed in himself, and calling that a booking would describe his vacation as a shoot. "turns up
        // later" is the other half, and the load-bearing half: what puts a show here is the TIMING, a clash
        // arriving after he kept it, not the clash itself.
        case .prepBlocked: return "A show you kept lands here if a clash with your calendar turns up later."
        case .review: return "Prepped drafts land here to read, approve, and send."
        default: return ""
        }
    }
}
