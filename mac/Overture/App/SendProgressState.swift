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

    func depart(_ key: String, as snapshot: QueueItem) { departing[key] = snapshot }
    func finishDeparting(_ key: String) { departing[key] = nil }
    func isDeparting(_ key: String) -> Bool { departing[key] != nil }

    func highlight(_ key: String?) { highlighted = key }
    // Clears only if it is still the show that asked, so a jump that lands while an earlier one's timer
    // is still running cannot have its mark wiped by the older timer firing.
    func clearHighlight(ifStill key: String) {
        if highlighted == key { highlighted = nil }
    }
}
