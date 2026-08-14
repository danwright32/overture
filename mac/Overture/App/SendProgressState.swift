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

// #2417: a row on its way out of the queue, and why it is going.
//
// The snapshot is here because the row may already be gone from the store's answer (a send drops it at
// once), and the reason is here because the two exits look nothing alike. They travel as one value so no
// reader has to put them back in step.
struct Departure {
    let item: QueueItem
    let reason: DepartureReason
}

@MainActor
@Observable
final class SendProgressState {
    // Show key -> when its outbound send began.
    private(set) var outbound: [String: Date] = [:]
    // Recipient id -> when that reply's send began. Keyed per recipient because a multi-contact show can
    // have one reply in flight while the others sit untouched.
    private(set) var reply: [String: Date] = [:]
    // Show key -> the row that is leaving, and why. The send has already dropped it from the store's
    // answer, so the card playing the exit cannot come from the queue any more, and the reason lives
    // beside the snapshot rather than on it, so a QueueItem stays a description of a show rather than of
    // what a screen is doing to it this second.
    //
    // #2417: ONE dictionary, deliberately, not a snapshot dictionary beside a reason dictionary. The two
    // halves are written together, cleared together and meaningless apart, so holding them separately
    // bought nothing and left every reader folding a `?? .sent` over a disagreement that could then never
    // be provoked in a test: a defended invariant with no reachable failure is dead code that reads as
    // care (L90). Held as one value, the disagreement cannot be expressed.
    private(set) var departures: [String: Departure] = [:]

    // The leaving rows alone, for the splice that puts them back into the date list.
    var departing: [String: QueueItem] { departures.mapValues { $0.item } }
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
        departures[key] = Departure(item: snapshot, reason: reason)
    }

    // One line clears the whole departure. A reason left behind would make this show's NEXT departure
    // render as whatever the last one was, and the two are drawn differently on purpose.
    func finishDeparting(_ key: String) { departures[key] = nil }

    func isDeparting(_ key: String) -> Bool { departures[key] != nil }
    func departureReason(_ key: String) -> DepartureReason? { departures[key]?.reason }

    // #2417/#2644: what a row needs to decide what it draws this second.
    //
    // Answered here rather than in the view that wants it, because a rule decided in a view body is a
    // rule no test can reach (#885), and the only guard left for it would be one reading the source for
    // the words it expects, which passes just as happily on words that no longer do the job (L1, L103).
    func departure(_ key: String) -> Departure? { departures[key] }

    func highlight(_ key: String?) { highlighted = key }
    // Clears only if it is still the show that asked, so a jump that lands while an earlier one's timer
    // is still running cannot have its mark wiped by the older timer firing.
    func clearHighlight(ifStill key: String) {
        if highlighted == key { highlighted = nil }
    }
}
