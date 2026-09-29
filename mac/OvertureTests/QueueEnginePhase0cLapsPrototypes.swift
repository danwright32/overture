import Foundation
import SwiftData

// #4106 plan v7, probe 0c.7 (term T9): TEST-ONLY prototypes of the reconcile tick's candidate indexes.
//
// Each is the plan section 4 pattern applied to one lap: a value built once from facts extracted from the
// rows (keyed by persistentModelID, never naturalKey or Recipient.id), updated from the rows a change
// touched and from the clock, and answering the lap's question ("which rows would this lap write?") without
// visiting every row. None of them is product code and nothing under `mac/Overture/` calls them. Each is
// judged in `QueueEnginePhase0cLapsProbeTests` against today's lap run as a DRY RUN, and that dry run is in
// turn proved equal to the real lap (run for real, then rolled back or diffed) before it is trusted.
//
// The facts each prototype extracts RESTATE the predicate's inputs from stored fields rather than calling
// the model's own computed properties, so a prototype and its oracle do not share the one mechanism the
// comparison exists to check (L70). Where a restated rule drifts from the product one, the property test
// goes red rather than both sides agreeing.

typealias Phase0cPID = PersistentIdentifier

// MARK: - A sorted map from a comparable key to the rows filed under it

/// The plan's "sorted map": distinct keys kept sorted, each holding the rows filed under it, so "every row
/// whose key is below X" is a binary search plus the rows actually returned, never a walk of every row.
struct Phase0cSortedBuckets<Key: Comparable & Hashable> {
    private(set) var keys: [Key] = []
    private(set) var members: [Key: Set<Phase0cPID>] = [:]

    var rowCount: Int { members.values.reduce(0) { $0 + $1.count } }

    mutating func insert(_ pid: Phase0cPID, at key: Key) {
        if members[key] == nil { keys.insert(key, at: lowerBound(key)) }
        members[key, default: []].insert(pid)
    }

    mutating func remove(_ pid: Phase0cPID, at key: Key) {
        guard var set = members[key] else { return }
        set.remove(pid)
        if set.isEmpty {
            members[key] = nil
            keys.remove(at: lowerBound(key))
        } else {
            members[key] = set
        }
    }

    /// The first index whose key is at or above `key`.
    func lowerBound(_ key: Key) -> Int {
        var low = 0, high = keys.count
        while low < high {
            let mid = (low + high) / 2
            if keys[mid] < key { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// Every row filed under a key strictly below `bound`.
    func below(_ bound: Key) -> Set<Phase0cPID> {
        var out = Set<Phase0cPID>()
        for key in keys[0..<lowerBound(bound)] { out.formUnion(members[key] ?? []) }
        return out
    }

    /// Every (row, key) filed at or below `bound`.
    func atOrBelow(_ bound: Key) -> [(Phase0cPID, Key)] {
        var end = lowerBound(bound)
        if end < keys.count, keys[end] == bound { end += 1 }
        return keys[0..<end].flatMap { key in (members[key] ?? []).map { ($0, key) } }
    }
}

// MARK: - Bookings: settle's due set and expiry index (plan section 3, fact 8)

/// Everything `ContactScoreAdjustment.settle`'s guard reads, restated from stored fields.
struct Phase0cSettleFacts: Equatable, Sendable {
    var probedAt: Date?
    var resultRaw: String?
    var routeAtScore: String?
    var tierAtScore: String?
    /// The best tier among the row's contacts holding an address no guard holds (`contactTierFromRecipients`).
    var bestTierRaw: String?

    @MainActor
    static func extract(_ p: Prospect) -> Phase0cSettleFacts {
        var best: ContactTier?
        for r in p.recipients {
            guard let email = r.email, !email.isEmpty else { continue }
            let held = (r.looksLikeVenue && !r.looksLikeVenueDismissed)
                || (r.looksLikePressContact && !r.looksLikePressContactDismissed)
                || (r.looksLikeDuplicateContact && !r.looksLikeDuplicateContactDismissed)
                || (r.looksLikeAnotherPersons && !r.looksLikeAnotherPersonsDismissed)
            guard !held, let tier = r.contactTierRaw.flatMap(ContactTier.init(rawValue:)) else { continue }
            if best.map({ tier.rank > $0.rank }) ?? true { best = tier }
        }
        return Phase0cSettleFacts(probedAt: p.reachabilityProbedAt, resultRaw: p.reachabilityResultRaw,
                                  routeAtScore: p.contactRouteAtScore, tierAtScore: p.contactTierAtScore,
                                  bestTierRaw: best?.rawValue)
    }

    static func stale(_ probedAt: Date?, at now: Date) -> Bool {
        guard let probedAt else { return false }
        return now.timeIntervalSince(probedAt) > Reachability.probeFreshness
    }

    func isDue(at now: Date) -> Bool {
        let isStale = Self.stale(probedAt, at: now)
        let route = isStale ? ContactRoute.unchecked
            : ContactRoute(probeResult: resultRaw.flatMap(Reachability.ProbeResult.init(rawValue:)))
        let tier = isStale ? nil : bestTierRaw
        return route.rawValue != (routeAtScore ?? ContactRoute.unchecked.rawValue) || tier != tierAtScore
    }
}

/// The due set: rows whose settle would write now. A row enters or leaves it only when its own facts change
/// (`update`) or when the clock crosses `reachabilityProbedAt + probeFreshness` (`advance`), the one way the
/// guard reads `now`.
struct Phase0cSettleIndex {
    private(set) var asOf: Date
    private(set) var facts: [Phase0cPID: Phase0cSettleFacts] = [:]
    private(set) var due: Set<Phase0cPID> = []
    private var expiry = Phase0cSortedBuckets<Date>()
    private var expiryOf: [Phase0cPID: Date] = [:]
    /// Rows judged since the counter was last read, so a test can say how many one change re-evaluated.
    var judged = 0

    init(rows: [(Phase0cPID, Phase0cSettleFacts)], now: Date) {
        asOf = now
        for (pid, f) in rows { update(pid, f) }
    }

    var pendingCrossings: Int { expiryOf.count }

    mutating func update(_ pid: Phase0cPID, _ new: Phase0cSettleFacts?) {
        if let old = expiryOf.removeValue(forKey: pid) { expiry.remove(pid, at: old) }
        guard let new else {
            facts[pid] = nil
            due.remove(pid)
            return
        }
        facts[pid] = new
        if let probedAt = new.probedAt, !Phase0cSettleFacts.stale(probedAt, at: asOf) {
            let crossing = probedAt.addingTimeInterval(Reachability.probeFreshness)
            expiry.insert(pid, at: crossing)
            expiryOf[pid] = crossing
        }
        judge(pid)
    }

    /// Moves the clock forward. `probedAt + freshness` and `now - probedAt > freshness` can disagree in the
    /// last bit of a Double, so the sorted key only NOMINATES (with a millisecond of margin) and the exact
    /// staleness test the product uses decides; a nominee that is not yet stale stays filed.
    mutating func advance(to now: Date) {
        precondition(now >= asOf, "the settle index only moves forward; a clock moving back is a cold rebuild")
        asOf = now
        for (pid, at) in expiry.atOrBelow(now.addingTimeInterval(0.001)) {
            guard let f = facts[pid], Phase0cSettleFacts.stale(f.probedAt, at: now) else { continue }
            expiry.remove(pid, at: at)
            expiryOf[pid] = nil
            judge(pid)
        }
    }

    private mutating func judge(_ pid: Phase0cPID) {
        judged += 1
        if facts[pid]?.isDue(at: asOf) == true { due.insert(pid) } else { due.remove(pid) }
    }
}

// MARK: - Retirement: untriaged by opening night, kept unpitched by last night

struct Phase0cRetireFacts: Equatable, Sendable {
    var statusRaw: String
    var performanceDate: String?
    var runEndDate: String?
    var wasPitched: Bool

    @MainActor
    static func extract(_ p: Prospect) -> Phase0cRetireFacts {
        Phase0cRetireFacts(statusRaw: p.statusRaw, performanceDate: p.performanceDate, runEndDate: p.runEndDate,
                           wasPitched: p.sentAt != nil
                               || p.recipients.contains { $0.sendStateRaw == SendState.sent.rawValue })
    }

    static let keptStatuses: Set<String> = ["queued", "drafted", "approved"]
}

struct Phase0cRetireIndex {
    enum Slot: Hashable { case untriaged(String), kept(String) }

    private(set) var untriaged = Phase0cSortedBuckets<String>()
    private(set) var kept = Phase0cSortedBuckets<String>()
    private var slotOf: [Phase0cPID: Slot] = [:]

    init(rows: [(Phase0cPID, Phase0cRetireFacts)]) {
        for (pid, f) in rows { update(pid, f) }
    }

    var filed: Int { slotOf.count }

    mutating func update(_ pid: Phase0cPID, _ new: Phase0cRetireFacts?) {
        if let old = slotOf.removeValue(forKey: pid) { unfile(pid, from: old) }
        guard let new else { return }
        if new.statusRaw == "new", let opening = new.performanceDate {
            untriaged.insert(pid, at: opening)
            slotOf[pid] = .untriaged(opening)
        } else if Phase0cRetireFacts.keptStatuses.contains(new.statusRaw), !new.wasPitched,
                  let last = new.runEndDate ?? new.performanceDate {
            kept.insert(pid, at: last)
            slotOf[pid] = .kept(last)
        }
    }

    private mutating func unfile(_ pid: Phase0cPID, from slot: Slot) {
        switch slot {
        case .untriaged(let key): untriaged.remove(pid, at: key)
        case .kept(let key): kept.remove(pid, at: key)
        }
    }

    /// The rows the two retirements would dismiss on `today`: an opening night or a last night strictly
    /// before it.
    func candidates(today: String) -> (wentBy: Set<Phase0cPID>, passedKept: Set<Phase0cPID>) {
        (untriaged.below(today), kept.below(today))
    }
}

// MARK: - Conflicts: nights to rows, the last calendar, and a diff of its inputs

/// The five inputs `ScoutService.blockedCalendar` builds from (plan section 3, fact 9), read the same way.
struct Phase0cCalendarInputs: Equatable {
    var bookings: [OvertureBooking]
    var blockedDates: [String]
    var health: DownbeatBridge.Health
    var daysOff: [DayOffRange]
    var cancelled: Set<String>
    var weekly: [WeeklyBlock]

    @MainActor
    static func read(export: DayOffEditing.Export, context: ModelContext) -> Phase0cCalendarInputs {
        Phase0cCalendarInputs(bookings: export.bookings, blockedDates: export.blockedDates, health: export.health,
                              daysOff: DayOffEditing.ranges(in: context),
                              cancelled: CancelledShootEditing.cancelledIds(in: context),
                              weekly: WeeklyDayOffEditing.blocks(in: context))
    }

    func build() -> BlockedCalendar {
        BlockedCalendar.build(availability: BlockedCalendar.Availability(health: health), bookings: bookings,
                              exportedBlockedDates: blockedDates, daysOff: daysOff,
                              cancelledBookingIds: cancelled, weeklyBlocks: weekly)
    }
}

struct Phase0cConflictFacts: Equatable, Sendable {
    var playing: PlayingNights
    var conflictKey: String?

    @MainActor
    static func extract(_ p: Prospect) -> Phase0cConflictFacts {
        Phase0cConflictFacts(playing: PlayingNights.of(runNights: p.runNights, performanceDate: p.performanceDate,
                                                       runEndDate: p.runEndDate),
                             conflictKey: p.conflictKey)
    }

    var nights: [String] {
        switch playing {
        case .recorded(let nights): return nights
        case .spanOnly(let opening, let lastNight): return EasternDate.days(from: opening, through: lastNight)
        case .undated: return []
        }
    }
}

struct Phase0cConflictIndex {
    private(set) var inputs: Phase0cCalendarInputs
    private(set) var calendar: BlockedCalendar
    private var facts: [Phase0cPID: Phase0cConflictFacts] = [:]
    private var rowNights: [Phase0cPID: [String]] = [:]
    private var nightRows: [String: Set<Phase0cPID>] = [:]
    /// The deciding key of every night some row plays, under `calendar`; "" is a free night.
    private var decided: [String: String] = [:]
    private var dirty: Set<Phase0cPID> = []

    /// What the last `judge` did, for the neighbourhood report.
    private(set) var lastCandidateNights = 0
    private(set) var lastChangedNights = 0
    private(set) var lastJudgedRows = 0

    var indexedNights: Int { decided.count }
    var largestNight: Int { nightRows.values.map(\.count).max() ?? 0 }

    init(rows: [(Phase0cPID, Phase0cConflictFacts)], inputs: Phase0cCalendarInputs) {
        self.inputs = inputs
        calendar = inputs.build()
        for (pid, f) in rows { update(pid, f) }
    }

    private func decidingKey(_ night: String, in calendar: BlockedCalendar) -> String {
        calendar.blockedNights(.recorded([night])).first?.key ?? ""
    }

    /// A row's own facts changed (or it was inserted or deleted): refile its nights and judge it next time.
    mutating func update(_ pid: Phase0cPID, _ new: Phase0cConflictFacts?) {
        let oldNights = rowNights[pid] ?? []
        let newNights = new?.nights ?? []
        if oldNights != newNights {
            for n in oldNights {
                nightRows[n]?.remove(pid)
                if nightRows[n]?.isEmpty == true {
                    nightRows[n] = nil
                    decided[n] = nil
                }
            }
            for n in newNights {
                nightRows[n, default: []].insert(pid)
                if decided[n] == nil { decided[n] = decidingKey(n, in: calendar) }
            }
        }
        rowNights[pid] = new == nil ? nil : newNights
        facts[pid] = new
        if new == nil { dirty.remove(pid) } else { dirty.insert(pid) }
    }

    /// The indexed nights whose deciding day COULD have moved between two sets of inputs.
    private func candidateNights(from old: Phase0cCalendarInputs, to new: Phase0cCalendarInputs) -> Set<String> {
        var dates = Set<String>()
        func add(_ start: String, _ end: String) { dates.formUnion(EasternDate.days(from: start, through: end)) }
        for b in old.bookings where !new.bookings.contains(b) { add(b.startDate, b.endDate) }
        for b in new.bookings where !old.bookings.contains(b) { add(b.startDate, b.endDate) }
        for id in old.cancelled.symmetricDifference(new.cancelled) {
            for b in old.bookings + new.bookings where b.id == id { add(b.startDate, b.endDate) }
        }
        dates.formUnion(Set(old.blockedDates).symmetricDifference(new.blockedDates))
        for r in old.daysOff where !new.daysOff.contains(r) { add(r.startDate, r.endDate) }
        for r in new.daysOff where !old.daysOff.contains(r) { add(r.startDate, r.endDate) }
        var nights = dates.filter { decided[$0] != nil }
        let movedRules = old.weekly.filter { !new.weekly.contains($0) } + new.weekly.filter { !old.weekly.contains($0) }
        for rule in movedRules { nights.formUnion(decided.keys.filter { rule.blocks($0) }) }
        return nights
    }

    /// The writes `ConflictSweep.reapplyAll` would make against `newInputs`: rows on a night whose deciding
    /// day changed, plus every row changed since the last call, judged against the new calendar. Adopts the
    /// new calendar as its snapshot and returns the intended writes (row to new key, nil to clear).
    mutating func judge(_ newInputs: Phase0cCalendarInputs) -> [Phase0cPID: String?] {
        let newCalendar = newInputs.build()
        let candidates = candidateNights(from: inputs, to: newInputs)
        var rows = dirty
        var changed = 0
        for n in candidates {
            let key = decidingKey(n, in: newCalendar)
            guard key != decided[n] else { continue }
            decided[n] = key
            changed += 1
            rows.formUnion(nightRows[n] ?? [])
        }
        var writes: [Phase0cPID: String?] = [:]
        for pid in rows {
            guard let f = facts[pid] else { continue }
            let key = newCalendar.conflict(f.playing)?.key
            if key != f.conflictKey { writes[pid] = .some(key) }
        }
        lastCandidateNights = candidates.count
        lastChangedNights = changed
        lastJudgedRows = rows.count
        inputs = newInputs
        calendar = newCalendar
        dirty = []
        return writes
    }
}

// MARK: - The closing read: replied, booked and DueWork as per-row entries with running totals

struct Phase0cClosingTotals {
    struct Entry {
        var key: String
        var name: String
        var replied: Bool
        var booked: Bool
        var counts: [Bool: DueWork.Counts]
        var until: Date?
    }

    private(set) var entries: [Phase0cPID: Entry] = [:]
    private(set) var totals: [Bool: DueWork.Counts] = [false: Self.zero, true: Self.zero]
    private var expiry = Phase0cSortedBuckets<Date>()
    private(set) var asOf: Date

    static let zero = DueWork.Counts(followUps: 0, afterTheShow: 0)

    init(now: Date) { asOf = now }

    static func add(_ a: DueWork.Counts, _ b: DueWork.Counts, sign: Int) -> DueWork.Counts {
        DueWork.Counts(followUps: a.followUps + sign * b.followUps,
                       afterTheShow: a.afterTheShow + sign * b.afterTheShow,
                       conversationsToConfirm: a.conversationsToConfirm + sign * b.conversationsToConfirm,
                       stalledReplyDrafts: a.stalledReplyDrafts + sign * b.stalledReplyDrafts,
                       repliesToAnswer: a.repliesToAnswer + sign * b.repliesToAnswer)
    }

    @MainActor
    mutating func update(_ pid: Phase0cPID, _ p: Prospect?) {
        if let old = entries.removeValue(forKey: pid) {
            for alive in [false, true] { totals[alive] = Self.add(totals[alive]!, old.counts[alive]!, sign: -1) }
            if let until = old.until { expiry.remove(pid, at: until) }
        }
        guard let p else { return }
        var counts: [Bool: DueWork.Counts] = [:]
        var until: Date?
        for alive in [false, true] {
            counts[alive] = DueWork.counts(prospects: [p], inquiries: [], now: asOf, replyRunAlive: alive)
            if let next = DueWork.nextChange(prospects: [p], now: asOf, replyRunAlive: alive),
               until.map({ next < $0 }) ?? true { until = next }
        }
        let entry = Entry(key: p.naturalKey, name: p.groupName, replied: ReconcileScheduler.hasNewReply(p),
                          booked: p.outcome == .booked, counts: counts, until: until)
        for alive in [false, true] { totals[alive] = Self.add(totals[alive]!, counts[alive]!, sign: 1) }
        if let until { expiry.insert(pid, at: until) }
        entries[pid] = entry
    }

    /// Moves the clock and re-derives every row whose own next change has come due.
    @MainActor
    mutating func advance(to now: Date, row: (Phase0cPID) -> Prospect?) -> Int {
        asOf = now
        let due = expiry.atOrBelow(now)
        for (pid, _) in due { update(pid, row(pid)) }
        return due.count
    }

    /// The read the tick's closing step would make: the lists and the counts, inquiries added whole.
    @MainActor
    func read(inquiries: [Inquiry], replyRunAlive: Bool) -> (replied: Set<String>, booked: Set<String>,
                                                              due: DueWork.Counts) {
        let inquiryPart = DueWork.counts(prospects: [], inquiries: inquiries, now: asOf, replyRunAlive: replyRunAlive)
        var replied = Set<String>(), booked = Set<String>()
        for e in entries.values {
            if e.replied { replied.insert(e.key) }
            if e.booked { booked.insert(e.key) }
        }
        return (replied, booked, Self.add(totals[replyRunAlive]!, inquiryPart, sign: 1))
    }
}

// MARK: - The oracles: today's laps as dry runs, and the real laps to prove each dry run against

@MainActor
enum Phase0cLapOracle {
    /// settle's guard, asked of every row through the model's own methods and written nowhere.
    static func settleDryRun(_ rows: [Prospect], now: Date) -> Set<Phase0cPID> {
        Set(rows.filter { p in
            let route = p.contactRouteForScoring(now: now)
            let tier = p.contactTierForScoring(now: now)
            let alreadyAt = p.contactRouteAtScore ?? ContactRoute.unchecked.rawValue
            return route.rawValue != alreadyAt || tier?.rawValue != p.contactTierAtScore
        }.map(\.persistentModelID))
    }

    /// The REAL `ContactScoreAdjustment.settle` over every row, its changed set collected, then rolled back.
    /// The context must hold no unsaved change on entry, or the rollback would take it too.
    ///
    /// #4324: THROWS when the hand restore below cannot be saved. It used to end in `try? context.save()`, so a
    /// restore that never reached the store read exactly like one that did, and every comparison after it
    /// judged a store still holding the real lap's writes (L515, L10). `save` is the seam a test fails.
    static func settleReal(_ rows: [Prospect], now: Date, context: ModelContext,
                           save: (ModelContext) throws -> Void = { try $0.save() }) throws -> Set<Phase0cPID> {
        precondition(!context.hasChanges, "settleReal would roll back an unsaved change")
        typealias Stamp = (Int?, Int, String, String?, String?)
        func stamp(_ p: Prospect) -> Stamp {
            (p.fitScoreBeforeContactCheck, p.fitScore, p.tier, p.contactRouteAtScore, p.contactTierAtScore)
        }
        let before = rows.map(stamp)
        let changed = Set(rows.filter { ContactScoreAdjustment.settle($0, now: now) }.map(\.persistentModelID))
        context.rollback()
        // Measured 2026-09-27: `rollback()` discards the pending changes but does NOT put back the values an
        // already fetched model instance holds, so a caller keeping its array would read the settled values
        // from then on. Each field is therefore put back by hand, and every row that needed it is counted.
        var leaked = 0
        for (p, s) in zip(rows, before) where stamp(p) != s {
            leaked += 1
            (p.fitScoreBeforeContactCheck, p.fitScore, p.tier, p.contactRouteAtScore, p.contactTierAtScore) = s
        }
        if leaked > 0 {
            rollbackLeaks += leaked
            try saveRestore(context, lap: "settle", save: save)
        }
        return changed
    }

    /// A hand restore that did not reach the store. Its own type, so a failure names which lap it came from.
    struct RestoreNotSaved: Error, CustomStringConvertible {
        let lap: String
        let underlying: String
        var description: String { "the \(lap) lap's hand restore was not saved: \(underlying)" }
    }

    /// The one save both laps' restores go through, so neither can swallow a failure the other reports.
    private static func saveRestore(_ context: ModelContext, lap: String,
                                    save: (ModelContext) throws -> Void) throws {
        do {
            try save(context)
        } catch {
            throw RestoreNotSaved(lap: lap, underlying: String(describing: type(of: error)))
        }
    }

    /// Rows whose values `rollback()` left in place and the oracle had to put back by hand.
    static var rollbackLeaks = 0

    /// The two retirements' filters, asked through the model's own methods over the same fetches.
    static func retireDryRun(context: ModelContext, today: String)
        -> (wentBy: Set<Phase0cPID>, passedKept: Set<Phase0cPID>) {
        let all = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        let wentBy = all.filter { $0.statusRaw == "new" && $0.hasOpened(today: today) }
        let passed = all.filter {
            Phase0cRetireFacts.keptStatuses.contains($0.statusRaw) && !$0.wasPitched
                && EasternDate.lastNightHasPassed(performanceDate: $0.performanceDate, runEndDate: $0.runEndDate,
                                                  today: today)
        }
        return (Set(wentBy.map(\.persistentModelID)), Set(passed.map(\.persistentModelID)))
    }

    /// The REAL `WentByRetirement.run` then `PassedKeptRetirement.run`, which rows each dismissed, rolled back.
    /// #4324: throws when the restore cannot be saved, for the reason `settleReal` gives.
    static func retireReal(context: ModelContext, today: String,
                           save: (ModelContext) throws -> Void = { try $0.save() }) throws
        -> (wentBy: Set<Phase0cPID>, passedKept: Set<Phase0cPID>) {
        precondition(!context.hasChanges, "retireReal would roll back an unsaved change")
        let all = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        let before = Dictionary(all.map { ($0.persistentModelID, $0.statusRaw) }, uniquingKeysWith: { a, _ in a })
        let outcomes = Dictionary(all.map { ($0.persistentModelID, $0.showOutcomeRaw) }, uniquingKeysWith: { a, _ in a })
        let dismissed = Dictionary(all.map { ($0.persistentModelID, $0.dismissedAt) }, uniquingKeysWith: { a, _ in a })
        let wentCount = WentByRetirement.run(in: context, today: today)
        let afterWent = Set(all.filter { before[$0.persistentModelID] != $0.statusRaw }.map(\.persistentModelID))
        let passedCount = PassedKeptRetirement.run(in: context, today: today)
        let afterBoth = Set(all.filter { before[$0.persistentModelID] != $0.statusRaw }.map(\.persistentModelID))
        context.rollback()
        // The same hand restore as `settleReal`, for the same measured reason.
        var leaked = 0
        for p in all where before[p.persistentModelID] != p.statusRaw {
            leaked += 1
            p.statusRaw = before[p.persistentModelID] ?? p.statusRaw
            p.showOutcomeRaw = outcomes[p.persistentModelID] ?? nil
            p.dismissedAt = dismissed[p.persistentModelID] ?? nil
        }
        if leaked > 0 {
            rollbackLeaks += leaked
            try saveRestore(context, lap: "retirement", save: save)
        }
        precondition(afterWent.count == wentCount && afterBoth.count == wentCount + passedCount,
                     "a retirement's count disagrees with the rows it changed")
        return (afterWent, afterBoth.subtracting(afterWent))
    }

    /// `ConflictSweep.reapplyAll`'s comparison over every row, against the calendar it would build.
    static func conflictDryRun(_ rows: [Prospect], export: DayOffEditing.Export,
                               context: ModelContext) -> [Phase0cPID: String?] {
        let calendar = ScoutService.blockedCalendar(export: export, context: context)
        var out: [Phase0cPID: String?] = [:]
        for p in rows {
            let key = calendar.conflict(p.playingNights)?.key
            if key != p.conflictKey { out[p.persistentModelID] = .some(key) }
        }
        return out
    }

    /// Each row's stored conflict key, for diffing before and after a real sweep.
    static func conflictKeys(_ rows: [Prospect]) -> [Phase0cPID: String?] {
        Dictionary(rows.map { ($0.persistentModelID, $0.conflictKey) }, uniquingKeysWith: { a, _ in a })
    }

    static func written(before: [Phase0cPID: String?], after rows: [Prospect]) -> [Phase0cPID: String?] {
        var out: [Phase0cPID: String?] = [:]
        for p in rows where before[p.persistentModelID].map({ $0 != p.conflictKey }) ?? false {
            out[p.persistentModelID] = .some(p.conflictKey)
        }
        return out
    }
}
