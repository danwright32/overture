import Foundation
import Observation

// #1922: everything a send is DOING right now, which is not something the queue is made of.
//
// Four pieces of state that change only how one card looks: the show whose email is going out, the
// recipient whose reply is going out, the show playing its leaving delight, and the show a jump is
// briefly marking. All four were @State on QueueView, whose body derives the entire store on its first
// line, so a single send re-derived all 724 prospects four times over (mark, clear, depart, and clear
// again) to animate one card, and every search pick or deep link re-derived it twice more.
//
// Held here, each write notifies only the views that actually read it. QueueView itself reads none of
// them, which is what makes a send cost one card instead of the whole queue, and
// QueueInvalidationGuardTests pins that it stays that way. Same shape as ProbeSelectionState (#1774).
//
// Session state, deliberately not persisted: every one of these describes something happening in this
// second, and one surviving a relaunch would be a spinner over a send that finished days ago.
// #2417: why a row is leaving the queue, because the two reasons must not look alike.
//
// A send earns the gold seal SendDelightRow draws. An ending recorded from the close-out menu does not:
// the commonest endings are "no response" and "they passed", and giving those the same seal reads as the
// app congratulating Dan on a rejection. Gold is reserved for what he can act on.
//
// It also exists so a close-out can mark the row leaving BEFORE the write rather than after it. A send
// departs after the fact, because the send has already dropped the row from the store's answer. A
// close-out has the opposite problem: the write is what is slow, so the row has to start leaving on the
// press and let the rebuild happen behind the animation.
enum DepartureReason: String, Equatable, Sendable, CaseIterable {
    case sent
    case closedOut

    // Whether this departure plays the send celebration. Named on the reason rather than decided inside
    // a view body, so the rule is testable and cannot be quietly restated differently by a second caller.
    var showsSendDelight: Bool { self == .sent }
}

@MainActor
@Observable
final class SendProgressState {
    // Show key -> when its outbound send began.
    private(set) var outbound: [String: Date] = [:]
    // Recipient id -> when that reply's send began. Keyed per recipient because a multi-contact show can
    // have one reply in flight while the others sit untouched.
    private(set) var reply: [String: Date] = [:]
    // Show key -> the snapshot of the row that is leaving. The send has already dropped it from the
    // store's answer, so the card playing the exit cannot come from the queue any more.
    private(set) var departing: [String: QueueItem] = [:]
    // #2417: why each departing row is leaving, kept beside the snapshot rather than on it, so a
    // QueueItem stays a description of a show rather than of what a screen is doing to it this second.
    private(set) var departureReasons: [String: DepartureReason] = [:]
    // The show a jump (a deep link, a search pick) is marking, cleared a couple of seconds later.
    private(set) var highlighted: String?

    // `at` is injected so a test can assert the timestamp the row shows its elapsed count from, rather
    // than asserting only that something non-nil landed.
    func markSending(_ key: String, at: Date = Date()) { outbound[key] = at }
    func clearSending(_ key: String) { outbound[key] = nil }
    func sendingSince(_ key: String) -> Date? { outbound[key] }

    func markReplySending(_ recipientId: String, at: Date = Date()) { reply[recipientId] = at }
    func clearReplySending(_ recipientId: String) { reply[recipientId] = nil }
    func replySendingSince(_ recipientId: String) -> Date? { reply[recipientId] }

    // #2417: `because` defaults to .sent so every existing send call site keeps its exact behaviour and
    // its seal, and only a caller that says otherwise gets the quiet exit.
    func depart(_ key: String, as snapshot: QueueItem, because reason: DepartureReason = .sent) {
        departing[key] = snapshot
        departureReasons[key] = reason
    }

    func finishDeparting(_ key: String) {
        departing[key] = nil
        // Cleared with the snapshot, never left behind: a stale reason would make this show's NEXT
        // departure render as whatever its last one was, and the two are drawn differently on purpose.
        departureReasons[key] = nil
    }

    func isDeparting(_ key: String) -> Bool { departing[key] != nil }
    func departureReason(_ key: String) -> DepartureReason? { departureReasons[key] }

    func highlight(_ key: String?) { highlighted = key }
    // Clears only if it is still the show that asked, so a jump that lands while an earlier one's timer
    // is still running cannot have its mark wiped by the older timer firing.
    func clearHighlight(ifStill key: String) {
        if highlighted == key { highlighted = nil }
    }
}
