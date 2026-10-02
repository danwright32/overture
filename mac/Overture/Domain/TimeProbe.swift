import Foundation

// #4356 (plan v7 Phase 2, T10): the clock a per-row term reads, recording when its answer would next change.
//
// WHY A ROW NEEDS THIS. The queue engine (Phase 4) keeps each row's derived entry and rebuilds it only when
// something it read changes. The clock is the one input that changes with no event at all: a show opens, a
// nudge comes due, a probe goes stale, and nothing saves. A retained entry therefore has to carry the
// instant its answer stops holding (`validUntil`), and that instant has to come from the comparisons the
// term ACTUALLY made, never from a list of dated rules someone wrote beside the term, which is the list a
// new rule is added to the term and forgotten from (L96, plan v5 D4).
//
// So a term never holds a bare `Date`. It asks this probe questions whose answers can only change at a
// known instant (has this moment passed, what is today), and every question records that instant. A term
// that truly needs the instant itself, a relative label that moves every second, says so through
// `readContinuously`, which makes the entry valid for no time at all rather than silently forever.
//
// The answers are exactly what the same comparisons against `now` would give: a probe changes WHEN an
// entry is rebuilt, never what a term computes (`TimeProbeTests` holds both halves).
//
// NOTHING READS THIS YET. Phase 4b(d) (#4363) threads it through the per-row entries.
final class TimeProbe {
    let now: Date
    /// The earliest instant at which an answer this probe has given would differ, or nil when nothing it
    /// answered depends on the clock at all.
    private(set) var validUntil: Date?

    init(now: Date) {
        self.now = now
    }

    /// Whether `moment` is at or before now. A moment still ahead flips this answer when it arrives, so it is
    /// recorded; one already passed stays passed, because the clock only moves forward.
    func hasPassed(_ moment: Date) -> Bool {
        if now >= moment { return true }
        record(moment)
        return false
    }

    /// Whether now is earlier than `interval` after `start`: a window that opened at `start` and is still
    /// open. Recorded at the instant it closes, if that is still ahead.
    func isWithin(_ interval: TimeInterval, after start: Date) -> Bool {
        !hasPassed(start.addingTimeInterval(interval))
    }

    /// Overture's day, which changes at the next Eastern midnight, daylight saving included.
    var today: String {
        record(Self.nextEasternMidnight(after: now))
        return EasternDate.today(now)
    }

    /// The instant itself, for a term whose output moves with every second (a relative time label). The
    /// entry that asked is valid for no time at all, which is the honest answer, rather than silently
    /// valid until some unrelated deadline.
    func readContinuously() -> Date {
        record(now)
        return now
    }

    /// Whether some answer moves with every second, so the entry must be rebuilt on every pass.
    var readsContinuously: Bool { validUntil == now }

    static func nextEasternMidnight(after instant: Date) -> Date {
        let calendar = EasternDate.calendar
        let startOfDay = calendar.startOfDay(for: instant)
        return calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? instant.addingTimeInterval(86_400)
    }

    private func record(_ moment: Date) {
        if let current = validUntil, current <= moment { return }
        validUntil = moment
    }
}

// #4356 (plan v7 Phase 2, T10): the context a per-row term reads, recording which fields it consulted.
//
// The engine (Phase 4) keeps each row's entry until something it read changes. A store field is per row and
// arrives as that row's change; a CONTEXT field (the geography refusals, the client window, whether Gmail is
// connected, whether a run is live) is shared by every row, and a change to it must rebuild exactly the
// rows that consulted it, no more (a bulk rebuild for an unrelated toggle) and no fewer (a stale row).
//
// So a term reads the context through this, and the reader records each field it touched and the value it
// saw. `changedReads(in:)` then answers, for a new context, which of THIS row's recorded reads now differ,
// which is the question the engine's field-to-rows index exists to answer. Recorded at run time from the
// reads actually made, never declared per term, for the reason `TimeProbe` gives (L96).
//
// The clock is not a context field here: `now` and the day are read through `TimeProbe`, whose answers
// change at known instants rather than by comparison with a new value.
//
// NOTHING READS THIS YET. Phase 4b(d) (#4363) threads it through the per-row entries.
final class ContextReader<Context> {
    private let context: Context
    private var recorded: [PartialKeyPath<Context>: (Context) -> Bool] = [:]

    init(_ context: Context) {
        self.context = context
    }

    /// The value at `path`, recorded so a later context that changes it is known to change this row.
    func read<Value: Equatable>(_ path: KeyPath<Context, Value>) -> Value {
        let value = context[keyPath: path]
        if recorded[path] == nil {
            recorded[path] = { $0[keyPath: path] == value }
        }
        return value
    }

    /// Every field this reader was asked for.
    var consulted: Set<PartialKeyPath<Context>> { Set(recorded.keys) }

    /// The consulted fields whose value in `newer` differs from the value this reader handed out. Empty
    /// means every answer given still holds, so a row built through this reader needs no rebuild.
    func changedReads(in newer: Context) -> Set<PartialKeyPath<Context>> {
        Set(recorded.filter { !$0.value(newer) }.keys)
    }
}
