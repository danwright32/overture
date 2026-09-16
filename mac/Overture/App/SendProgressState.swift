import Foundation
import Observation

// #1922: everything a send is DOING right now, which is not something the queue is made of.
//
// Four pieces of state that change only how one card looks: the show whose email is going out, the
// recipient whose reply is going out, the show playing its leaving delight, and the show a jump is
// briefly marking. All four were @State on QueueView, whose body derives the entire store on its first
// line, so a single send re-derived every prospect in the store four times over (mark, clear, depart, and clear
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
    // #2729: WHEN it was marked, so a departure whose clear never ran cannot outlive the exit it was
    // covering. See `SendProgressState.departureCeiling`.
    let at: Date
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
    // #2598: the addresses struck but not yet gone from the store's answer.
    private var struck: [String: Date] = [:]

    // The leaving rows alone, for the splice that puts them back into the date list. Stale entries are
    // filtered here too (#2729): this is what the queue's own splice reads, so a stranded departure left
    // unfiltered would go on putting a closed-out show back into the list it just left.
    var departing: [String: QueueItem] {
        let now = Date()
        return departures.filter { !Self.isStale($0.value, now: now) }.mapValues { $0.item }
    }
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

    // #2729: how long a departure may live before it is disregarded.
    //
    // A departure is written by `depart` and cleared by `finishDeparting`, and NOTHING else removes one.
    // If the clear never runs, the entry survives the whole session and that show keeps drawing its exit
    // wherever it appears. The clear can be missed: `closeOut` marks the departure BEFORE its write,
    // deliberately, so a refused save leaves the mark behind; a view can be torn down mid animation; and
    // any future caller that marks a departure and returns early on an error path does the same.
    //
    // A CEILING rather than the reconcile the issue sketched, and that is a correction to its premise
    // rather than a shortcut. Reconciling against "keys the queue still returns" would clear every
    // departure the instant it was made: a departure exists precisely BECAUSE the row is already gone
    // from the queue's answer, which is what `closeOut`'s own comment says about clearing early making
    // the row flash back onto the screen. The two states are indistinguishable by key alone.
    //
    // What CAN be judged is age, because a departure has a known duration: `SendDelightTiming.plan`
    // totals 0.97s at its longest (0.55 hold plus 0.42 exit) and 0.58s under Reduced Motion. Thirty
    // seconds is thirty times the longest of those, so it cannot cut short a real exit even on a
    // badly contended main thread, and it turns "for the rest of the session" into a bounded wrong.
    static let departureCeiling: TimeInterval = 30

    // #2417: `because` defaults to .sent so every existing send call site keeps its exact behaviour and
    // its seal, and only a caller that says otherwise gets the quiet exit.
    //
    // `at` is injected so a test can place a departure in the past rather than waiting thirty seconds
    // for one, which is the only way the ceiling above is reachable at all (L1).
    func depart(_ key: String, as snapshot: QueueItem, because reason: DepartureReason = .sent,
                at: Date = Date()) {
        // Anything already past the ceiling goes now. Doing it here rather than on a timer means the
        // dictionary is bounded by the number of shows departing at once rather than by the length of
        // the session, and it costs one pass over a dictionary that holds one or two entries.
        departures = departures.filter { !Self.isStale($0.value, now: at) }
        departures[key] = Departure(item: snapshot, reason: reason, at: at)
    }

    // One line clears the whole departure. A reason left behind would make this show's NEXT departure
    // render as whatever the last one was, and the two are drawn differently on purpose.
    func finishDeparting(_ key: String) { departures[key] = nil }

    // #2598: an address Dan has struck, hidden on the PRESS rather than when the rebuild lands.
    //
    // Striking an address removes ONE LINE from a card that stays on screen. There is no departure to
    // mark and no snapshot to draw from: the card is rebuilt from the store's answer, so until the write
    // lands and the rebuild finishes, the address he just struck is still drawn. Measured 2026-09-06,
    // that wait is 860 ms on the live shape (`FeltWaitCostTests`), and a control that does nothing
    // visible for that long reads as broken and gets pressed again (L44).
    //
    // ONE mechanism rather than an optimistic path per control, which is what #2598 asks for: both ways
    // of striking an address (a researched contact and an inherited one) mark the same thing here, and
    // any control that removes an address from a card can use it without inventing a second rule that
    // can drift from what the write really did.
    //
    // KEYED ON THE SHOW AND THE ADDRESS TOGETHER, because one address can sit on two shows: keyed on the
    // address alone, striking it here would blank it on a card Dan never touched.
    static func strikeKey(show: String, email: String) -> String { "\(show)|\(email)" }

    // NOTHING CLEARS IT, and that is the design rather than an omission. The obvious clear, on the same
    // timing plan a departure uses, is WRONG here: a departure's row leaves for good, so a clear after
    // the hold is invisible, while a struck address is hidden from a card that stays, and the rebuild it
    // is covering for takes longer than the hold. Clearing on the plan would make the address FLASH BACK
    // and then vanish again, which is worse than the wait it replaces.
    //
    // So it ages out through the same ceiling a departure does, and until then it is harmless: once the
    // rebuild lands, the address is gone from the card's own answer and nothing consults the mark. What
    // the ceiling buys is the case where the write FAILED, where the address comes back rather than
    // staying hidden for the session (#2729's reasoning, applied to the other transient mark).
    func strike(_ key: String, at: Date = Date()) {
        struck = struck.filter { !Self.isStale($0.value, now: at) }
        struck[key] = at
    }

    func isStruck(_ key: String, now: Date = Date()) -> Bool {
        guard let at = struck[key] else { return false }
        return !Self.isStale(at, now: now)
    }

    // Here for the caller that wants the mark gone at once, which today is only a test and an undo.
    func finishStriking(_ key: String) { struck[key] = nil }

    private static func isStale(_ at: Date, now: Date) -> Bool {
        now.timeIntervalSince(at) > departureCeiling
    }

    private static func isStale(_ departure: Departure, now: Date) -> Bool {
        now.timeIntervalSince(departure.at) > departureCeiling
    }

    func isDeparting(_ key: String, now: Date = Date()) -> Bool { departure(key, now: now) != nil }
    func departureReason(_ key: String, now: Date = Date()) -> DepartureReason? {
        departure(key, now: now)?.reason
    }

    // #2417/#2644: what a row needs to decide what it draws this second.
    //
    // Answered here rather than in the view that wants it, because a rule decided in a view body is a
    // rule no test can reach (#885), and the only guard left for it would be one reading the source for
    // the words it expects, which passes just as happily on words that no longer do the job (L1, L103).
    //
    // #2729: a departure past `departureCeiling` answers nil, so a clear that never ran cannot make a
    // show draw its exit for the rest of the session. `now` is injected for the same reason `at` is.
    func departure(_ key: String, now: Date = Date()) -> Departure? {
        guard let departure = departures[key], !Self.isStale(departure, now: now) else { return nil }
        return departure
    }

    func highlight(_ key: String?) { highlighted = key }
    // Clears only if it is still the show that asked, so a jump that lands while an earlier one's timer
    // is still running cannot have its mark wiped by the older timer firing.
    func clearHighlight(ifStill key: String) {
        if highlighted == key { highlighted = nil }
    }
}
