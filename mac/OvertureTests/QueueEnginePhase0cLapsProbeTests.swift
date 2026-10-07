import Testing
import Foundation
import SwiftData

// #4106 plan v7, probe 0c.7 (term T9): the reconcile tick's laps as candidate indexes, proved against today's
// laps run as DRY RUNS, and each dry run proved against the REAL lap before it is trusted.
//
// TWO HALVES, deliberately different in cost and in who runs them:
//
// 1. The PROPERTY TESTS always run, on committed synthetic fixtures of 60 and 300 rows built from a seeded
//    generator (L339): invented, containment-rich titles and venues, example.org addresses, a pinned clock
//    (L130, L155). After EVERY operation and every undo, each prototype's answer must equal the dry run's,
//    and the dry run's must equal the real lap's: settle over every row then rolled back, the two retirements
//    then rolled back, and a real conflict sweep (or the hand edit's own sweep, diffed). A failure names the
//    seed, the step, the operation and 8 hex digit hashes, never a name. CI settings (`Phase0cTickLaps.ciPlan`):
//    1 seed of 40 operations at 60 rows, 1 seed of 12 operations at 300 rows.
//    `TEST_RUNNER_MEASURE_4106_PHASE0C_LAPS_DEEP=1` runs `Phase0cTickLaps.deepPlan`:
//    20 seeds of 500 operations at 60 rows, 20 seeds of 500 operations at 300 rows.
//    #4324: those two sentences are checked against the constants by
//    `theHeaderStatesThePlanTheHarnessRuns`, because this header said "two seeds of 40 per fixture" for a
//    plan that never ran that (L32, L407).
//
// 2. The CLONE PROBE is opt in (`TEST_RUNNER_MEASURE_4106_PHASE0C_LAPS=1`), like every #4106 probe before it
//    and for the same reasons: it clones Dan's store, and a stopwatch on a shared Mac measures the Mac (L224).
//    Unset, it prints one line saying it was not measured and passes (L98). It reads a `LiveStoreClone` copy
//    and the fourfold copy `Phase0.scaledCopy` builds from it, never the live store, and prints counts,
//    durations and hashes only (L222). Debug build, like every #4106 figure so far.
//
// Every per-key cost is taken over EVERY real key of its kind (plan section 4): every row for a row change,
// every pending expiry crossing for the clock, every playing night, weekday, booking id and row for the
// calendar. Where a key can be timed more than once without moving state, its cost is the median of three.

enum Phase0cTickLaps {
    nonisolated static var enabled: Bool {
        ProcessInfo.processInfo.environment["MEASURE_4106_PHASE0C_LAPS"] != nil
    }

    nonisolated static var deep: Bool {
        ProcessInfo.processInfo.environment["MEASURE_4106_PHASE0C_LAPS_DEEP"] != nil
    }

    nonisolated static func say(_ line: String) { print("phase0c7 " + line) }

    typealias Plan = [(size: Int, seeds: [UInt64], ops: Int)]

    // CI settings are sized against plan section 4's harness budget (measured 2026-09-27: two seeds of 40
    // on both fixtures took 84 s, too much of the 90 s every harness shares).
    nonisolated static let ciPlan: Plan = [(60, [11], 40), (300, [29], 12)]
    nonisolated static let deepPlan: Plan = [(60, Array(1...20), 500), (300, Array(1...20), 500)]

    /// A plan in the words the header states it in, so the header can be held to the constant.
    nonisolated static func describe(_ plan: Plan) -> String {
        plan.map { "\($0.seeds.count) seed\($0.seeds.count == 1 ? "" : "s") of \($0.ops) operations at \($0.size) rows" }
            .joined(separator: ", ") + "."
    }

    /// max, p99 and median of a set of per-key costs, in ms.
    struct Spread {
        let samples: [Double]
        var sorted: [Double] { samples.sorted() }
        var max: Double { samples.max() ?? 0 }
        var median: Double { samples.isEmpty ? 0 : sorted[samples.count / 2] }
        var p99: Double {
            guard !samples.isEmpty else { return 0 }
            return sorted[Swift.min(samples.count - 1, Int((Double(samples.count) * 0.99).rounded(.up)) - 1)]
        }
        var text: String {
            String(format: "max %.3f  p99 %.3f  median %.3f ms over %d keys", max, p99, median, samples.count)
        }
    }

    static func median3(_ work: () -> Void) -> Double {
        let runs = (0..<3).map { _ in Phase0.time(work) }.sorted()
        return runs[1]
    }

    static func hash(_ keys: some Sequence<String>) -> String {
        Phase0b.hash8(keys.sorted().joined(separator: ","))
    }
}

// MARK: - The synthetic world the property tests drive

@MainActor
final class Phase0cLapsWorld {
    let container: ModelContainer
    let context: ModelContext
    let seed: UInt64
    let size: Int
    var now: Date
    var today: String { QueueModel.easternToday(now) }
    let exportURL: URL
    var bookings: [OvertureBooking] = []
    var blockedDates: [String] = []
    var rng: SeededGenerator
    let scheduler: ReconcileScheduler
    var settle: Phase0cSettleIndex
    var retire: Phase0cRetireIndex
    var conflicts: Phase0cConflictIndex
    private var minted = 0

    // 2027-01-15 12:00 UTC, 07:00 in Eastern time, so `today` is 2027-01-15 (the Step T0 fixtures' clock).
    static let base = Date(timeIntervalSince1970: 1_800_014_400)
    static let titles = ["Lantern", "Glass Lantern", "Lantern Revue", "Harbor", "Harbor Lights",
                         "Harbor Lights Encore", "Cedar", "Cedar Strings", "Cedar Strings Trio", "Quarry Songs"]
    static let venues = ["Harbor Hall", "Quarry Hall", "Willow Barn", "Willow Barn Annex", "Glass House"]
    static let statuses: [ReviewStatus] = [.new, .new, .new, .queued, .drafted, .approved, .contacted, .dismissed]

    init(size: Int, seed: UInt64, dir: URL) throws {
        self.size = size
        self.seed = seed
        rng = SeededGenerator(seed: seed)
        now = Self.base
        container = try ModelContainer(for: AppSchema.schema,
                                       configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        context = container.mainContext
        context.autosaveEnabled = false
        exportURL = dir.appendingPathComponent("downbeat-export-\(size)-\(seed).json")
        scheduler = ReconcileScheduler(context: context, replyRunAlive: { _ in false })
        settle = Phase0cSettleIndex(rows: [], now: Self.base)
        retire = Phase0cRetireIndex(rows: [])
        conflicts = Phase0cConflictIndex(rows: [], inputs: Phase0cCalendarInputs(
            bookings: [], blockedDates: [], health: .missing, daysOff: [], cancelled: [], weekly: []))

        for _ in 0..<size { mintRow() }
        for k in 0..<6 { bookings.append(booking(k)) }
        blockedDates = (0..<3).map { _ in day(Int.random(in: -5...80, using: &rng)) }
        try writeExport()
        context.insert(DayOff(startDate: day(10), endDate: day(14), note: "Away"))
        context.insert(DayOff(startDate: day(40), endDate: day(40), note: nil))
        context.insert(WeeklyDayOff(weekday: 4, firstDate: day(0), lastDate: day(60), note: "Rehearsal",
                                    freedDates: [day(20), day(21)]))
        context.insert(CancelledShoot(bookingId: bookings[1].id, shootName: bookings[1].shootName,
                                      startDate: bookings[1].startDate, cancelledAt: Self.base))
        try context.save()
        // Score stamps settled, then a tenth knocked out of step so the fixture starts with due rows.
        _ = ContactScoreAdjustment.settleAll(rows(), now: now)
        for p in rows() where Int.random(in: 0..<10, using: &rng) == 0 { p.contactRouteAtScore = nil }
        try context.save()
        ConflictSweep.reapplyAll(export: export, in: context)
        try context.save()

        let all = rows()
        settle = Phase0cSettleIndex(rows: all.map { ($0.persistentModelID, Phase0cSettleFacts.extract($0)) }, now: now)
        retire = Phase0cRetireIndex(rows: all.map { ($0.persistentModelID, Phase0cRetireFacts.extract($0)) })
        conflicts = Phase0cConflictIndex(rows: all.map { ($0.persistentModelID, Phase0cConflictFacts.extract($0)) },
                                         inputs: inputs())
        _ = conflicts.judge(inputs())
    }

    // MARK: fixture pieces

    func day(_ offset: Int) -> String { ScoutTestClock.day(offset, after: Self.base) }

    func booking(_ k: Int) -> OvertureBooking {
        let start = Int.random(in: -3...80, using: &rng)
        return OvertureBooking(id: "bk-\(seed)-\(k)-\(minted)", clientId: "client-\(k)",
                               clientDisplayName: "Client \(k)", shootName: "Shoot \(k)",
                               startDate: day(start), endDate: day(start + Int.random(in: 0...2, using: &rng)),
                               venueId: nil, venueName: Self.venues[k % Self.venues.count])
    }

    private struct ExportFile: Encodable {
        let version = 2
        let clients: [DownbeatClient] = []
        let venues: [DownbeatVenue] = []
        let bookings: [OvertureBooking]
        let blockedDates: [String]
    }

    func writeExport() throws {
        try JSONEncoder().encode(ExportFile(bookings: bookings, blockedDates: blockedDates)).write(to: exportURL)
    }

    var export: DayOffEditing.Export {
        let loaded = DownbeatBridge.loadWithHealth(from: exportURL, now: now)
        return (loaded.bookings, loaded.blockedDates, loaded.health)
    }

    func inputs() -> Phase0cCalendarInputs { Phase0cCalendarInputs.read(export: export, context: context) }

    func rows() -> [Prospect] {
        ((try? context.fetch(FetchDescriptor<Prospect>())) ?? []).sorted { $0.naturalKey < $1.naturalKey }
    }

    @discardableResult
    func mintRow() -> Prospect {
        minted += 1
        let i = minted
        let title = Self.titles[Int.random(in: 0..<Self.titles.count, using: &rng)]
        let venue = Self.venues[Int.random(in: 0..<Self.venues.count, using: &rng)]
        let status = Self.statuses[Int.random(in: 0..<Self.statuses.count, using: &rng)]
        let undated = Int.random(in: 0..<10, using: &rng) == 0
        let opening = Int.random(in: -20...90, using: &rng)
        let p = Prospect(naturalKey: String(format: "fx-%05d", i), groupName: title, discipline: "choral",
                         venue: venue, performanceDate: undated ? nil : day(opening), sourceListingURL: nil,
                         priorRelationship: "none", production: "presenter", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil, status: status)
        context.insert(p)
        if !undated, Int.random(in: 0..<3, using: &rng) == 0 {
            p.runEndDate = day(opening + Int.random(in: 1...20, using: &rng))
        }
        if !undated, Int.random(in: 0..<4, using: &rng) == 0 {
            p.runNights = (0..<Int.random(in: 1...5, using: &rng)).map { k in day(opening + k * 2) }
        }
        if Int.random(in: 0..<5, using: &rng) == 0 { p.sentAt = now.addingTimeInterval(-86_400 * 3) }
        if Int.random(in: 0..<5, using: &rng) < 3 {
            p.reachabilityProbedAt = now.addingTimeInterval(-Double(Int.random(in: 0...(120 * 86_400), using: &rng)))
            p.reachabilityResultRaw = Reachability.ProbeResult.allCases.randomElement(using: &rng)?.rawValue
        }
        var contacts: [Recipient] = []
        for j in 0..<Int.random(in: 0...3, using: &rng) {
            contacts.append(recipient(on: i, j))
        }
        p.setRecipients(contacts)
        return p
    }

    func recipient(on i: Int, _ j: Int) -> Recipient {
        let hasAddress = Int.random(in: 0..<10, using: &rng) < 7
        let r = Recipient(id: "person\(i)-\(j)-\(minted)@example.org",
                          email: hasAddress ? "person\(i)-\(j)@example.org" : nil, provenance: .act)
        r.looksLikeVenue = Int.random(in: 0..<10, using: &rng) == 0
        r.looksLikePressContact = Int.random(in: 0..<12, using: &rng) == 0
        r.looksLikeDuplicateContact = Int.random(in: 0..<12, using: &rng) == 0
        r.looksLikeAnotherPersons = Int.random(in: 0..<12, using: &rng) == 0
        r.contactTierRaw = ([nil] + ContactTier.allCases.map(\.rawValue)).randomElement(using: &rng)!
        if Int.random(in: 0..<7, using: &rng) == 0 { r.sendStateRaw = SendState.sent.rawValue }
        return r
    }

    // MARK: change detection, the stand-in for the engine's intake

    static func signature(_ p: Prospect) -> String {
        var s = [p.statusRaw, p.performanceDate ?? "-", p.runEndDate ?? "-", p.runNights.joined(separator: ","),
                 "\(p.sentAt?.timeIntervalSince1970 ?? -1)", "\(p.reachabilityProbedAt?.timeIntervalSince1970 ?? -1)",
                 p.reachabilityResultRaw ?? "-", p.contactRouteAtScore ?? "-", p.contactTierAtScore ?? "-",
                 p.conflictKey ?? "-", "\(p.fitScore)"].joined(separator: "|")
        for r in p.recipients.sorted(by: { $0.id < $1.id }) {
            s += "#" + [r.id, r.email ?? "-", r.contactTierRaw ?? "-", r.sendStateRaw,
                        "\(r.looksLikeVenue)\(r.looksLikeVenueDismissed)\(r.looksLikePressContact)"
                            + "\(r.looksLikePressContactDismissed)\(r.looksLikeDuplicateContact)"
                            + "\(r.looksLikeDuplicateContactDismissed)\(r.looksLikeAnotherPersons)"
                            + "\(r.looksLikeAnotherPersonsDismissed)"].joined(separator: "|")
        }
        return s
    }

    func signatures() -> [Phase0cPID: String] {
        Dictionary(rows().map { ($0.persistentModelID, Self.signature($0)) }, uniquingKeysWith: { a, _ in a })
    }

    /// Feeds every changed, inserted or deleted row to the three indexes. The conflict index is fed only
    /// when `conflictsToo`, because a sweep op must be judged BEFORE its writes reach the index.
    func sync(from before: [Phase0cPID: String], conflictsToo: Bool = true) -> Set<Phase0cPID> {
        let current = rows()
        let byPID = Dictionary(current.map { ($0.persistentModelID, $0) }, uniquingKeysWith: { a, _ in a })
        var changed = Set<Phase0cPID>()
        for p in current where before[p.persistentModelID] != Self.signature(p) { changed.insert(p.persistentModelID) }
        for pid in before.keys where byPID[pid] == nil { changed.insert(pid) }
        for pid in changed {
            let p = byPID[pid]
            settle.update(pid, p.map(Phase0cSettleFacts.extract))
            retire.update(pid, p.map(Phase0cRetireFacts.extract))
            if conflictsToo { conflicts.update(pid, p.map(Phase0cConflictFacts.extract)) }
        }
        return changed
    }

    func feedConflicts(_ changed: Set<Phase0cPID>) {
        let byPID = Dictionary(rows().map { ($0.persistentModelID, $0) }, uniquingKeysWith: { a, _ in a })
        for pid in changed { conflicts.update(pid, byPID[pid].map(Phase0cConflictFacts.extract)) }
    }

    // MARK: undo

    struct RowSnapshot {
        struct Contact {
            let object: Recipient
            let id: String, email: String?, tier: String?, sendState: String
            let flags: [Bool]
        }
        let row: Prospect
        let statusRaw: String, performanceDate: String?, runEndDate: String?, runNights: [String]
        let sentAt: Date?, probedAt: Date?, resultRaw: String?, routeAt: String?, tierAt: String?
        let conflictKey: String?
        let contacts: [Contact]
    }

    func snapshot(_ p: Prospect) -> RowSnapshot {
        RowSnapshot(row: p, statusRaw: p.statusRaw, performanceDate: p.performanceDate, runEndDate: p.runEndDate,
                    runNights: p.runNights, sentAt: p.sentAt, probedAt: p.reachabilityProbedAt,
                    resultRaw: p.reachabilityResultRaw, routeAt: p.contactRouteAtScore, tierAt: p.contactTierAtScore,
                    conflictKey: p.conflictKey,
                    contacts: p.recipients.map { r in
                        RowSnapshot.Contact(object: r, id: r.id, email: r.email, tier: r.contactTierRaw,
                                            sendState: r.sendStateRaw,
                                            flags: [r.looksLikeVenue, r.looksLikeVenueDismissed, r.looksLikePressContact,
                                                    r.looksLikePressContactDismissed, r.looksLikeDuplicateContact,
                                                    r.looksLikeDuplicateContactDismissed, r.looksLikeAnotherPersons,
                                                    r.looksLikeAnotherPersonsDismissed])
                    })
    }

    func restore(_ s: RowSnapshot) {
        let p = s.row
        p.statusRaw = s.statusRaw
        p.performanceDate = s.performanceDate
        p.runEndDate = s.runEndDate
        p.runNights = s.runNights
        p.sentAt = s.sentAt
        p.reachabilityProbedAt = s.probedAt
        p.reachabilityResultRaw = s.resultRaw
        p.contactRouteAtScore = s.routeAt
        p.contactTierAtScore = s.tierAt
        p.conflictKey = s.conflictKey
        var kept: [Recipient] = []
        for c in s.contacts {
            let r = p.recipients.first { $0 === c.object } ?? Recipient(id: c.id, email: c.email, provenance: .act)
            r.email = c.email
            r.contactTierRaw = c.tier
            r.sendStateRaw = c.sendState
            (r.looksLikeVenue, r.looksLikeVenueDismissed, r.looksLikePressContact, r.looksLikePressContactDismissed)
                = (c.flags[0], c.flags[1], c.flags[2], c.flags[3])
            (r.looksLikeDuplicateContact, r.looksLikeDuplicateContactDismissed, r.looksLikeAnotherPersons,
             r.looksLikeAnotherPersonsDismissed) = (c.flags[4], c.flags[5], c.flags[6], c.flags[7])
            kept.append(r)
        }
        p.setRecipients(kept)
    }
}

// MARK: - The operations

enum Phase0cLapsOp: String, CaseIterable {
    // settle's inputs
    case freshProbe, probeNearExpiry, clearProbe, gainAddress, handDeleteContact, guardFlip, tierChange, stampReset,
         settleTick
    // retirement's inputs
    case statusChange, dateMove, pitched, retireTick
    // the clock
    case clockAdvance
    // the nine `ConflictSweep.reapplyAll` callers: DayOff.swift:153, 161; WeeklyDayOff.swift:140, 148, 166, 192;
    // CancelledShootEditing.swift:86, 104; ReconcileScheduler.swift:378 (the tick, with an export change)
    case dayOffAdd, dayOffRemove, weeklyAdd, weeklyRemove, weeklyFree, weeklyReblock, cancelShoot, restoreShoot,
         exportTick
    // rows arriving, leaving, and a writer outside the sweep setting a conflict key (the scout)
    case externalConflictWrite, insertRow, deleteRow

    var sweeps: Bool {
        switch self {
        case .dayOffAdd, .dayOffRemove, .weeklyAdd, .weeklyRemove, .weeklyFree, .weeklyReblock, .cancelShoot,
             .restoreShoot, .exportTick: return true
        default: return false
        }
    }
}

@MainActor
struct Phase0cLapsStep {
    let label: String
    let sweeps: Bool
    let undo: (() throws -> Phase0cLapsStep?)?
}

extension Phase0cLapsWorld {
    private func pick() -> Prospect? {
        let all = rows()
        return all.isEmpty ? nil : all[Int.random(in: 0..<all.count, using: &rng)]
    }

    private func rowUndo(_ s: RowSnapshot, _ label: String) -> () throws -> Phase0cLapsStep? {
        { [self] in
            restore(s)
            try context.save()
            return Phase0cLapsStep(label: "undo " + label, sweeps: false, undo: nil)
        }
    }

    /// Performs one operation and saves. Returns what it was and how to undo it, or nil when it had nothing
    /// to act on.
    func perform(_ op: Phase0cLapsOp) throws -> Phase0cLapsStep? {
        let label = op.rawValue
        switch op {
        case .freshProbe, .probeNearExpiry, .clearProbe, .gainAddress, .handDeleteContact, .guardFlip, .tierChange,
             .stampReset, .statusChange, .dateMove, .pitched, .externalConflictWrite:
            guard let p = pick() else { return nil }
            let s = snapshot(p)
            switch op {
            case .freshProbe:
                p.reachabilityProbedAt = now.addingTimeInterval(-Double(Int.random(in: 0...3 * 86_400, using: &rng)))
                p.reachabilityResultRaw = Reachability.ProbeResult.allCases.randomElement(using: &rng)?.rawValue
            case .probeNearExpiry:
                let offset = Double(Int.random(in: 85 * 86_400...95 * 86_400, using: &rng))
                p.reachabilityProbedAt = now.addingTimeInterval(-offset)
                p.reachabilityResultRaw = Reachability.ProbeResult.allCases.randomElement(using: &rng)?.rawValue
            case .clearProbe:
                p.reachabilityProbedAt = nil
                p.reachabilityResultRaw = nil
            case .gainAddress:
                if let bare = p.recipients.first(where: { $0.email == nil }) {
                    bare.email = "gained-\(p.naturalKey)@example.org"
                } else {
                    let r = recipient(on: 9_000 + p.recipients.count, p.recipients.count)
                    r.email = "gained-\(p.naturalKey)-\(p.recipients.count)@example.org"
                    p.setRecipients(p.recipients + [r])
                }
            case .handDeleteContact:
                guard !p.recipients.isEmpty else { return nil }
                let gone = p.recipients[Int.random(in: 0..<p.recipients.count, using: &rng)]
                p.setRecipients(p.recipients.filter { $0 !== gone })
            case .guardFlip:
                guard let r = p.recipients.randomElement(using: &rng) else { return nil }
                switch Int.random(in: 0..<8, using: &rng) {
                case 0: r.looksLikeVenue.toggle()
                case 1: r.looksLikeVenueDismissed.toggle()
                case 2: r.looksLikePressContact.toggle()
                case 3: r.looksLikePressContactDismissed.toggle()
                case 4: r.looksLikeDuplicateContact.toggle()
                case 5: r.looksLikeDuplicateContactDismissed.toggle()
                case 6: r.looksLikeAnotherPersons.toggle()
                default: r.looksLikeAnotherPersonsDismissed.toggle()
                }
            case .tierChange:
                guard let r = p.recipients.randomElement(using: &rng) else { return nil }
                r.contactTierRaw = ([nil] + ContactTier.allCases.map(\.rawValue)).randomElement(using: &rng)!
            case .stampReset:
                if Int.random(in: 0..<2, using: &rng) == 0 { p.contactRouteAtScore = nil }
                else { p.contactTierAtScore = ContactTier.allCases.randomElement(using: &rng)?.rawValue }
            case .statusChange:
                p.statusRaw = Self.statuses[Int.random(in: 0..<Self.statuses.count, using: &rng)].rawValue
            case .dateMove:
                switch Int.random(in: 0..<4, using: &rng) {
                case 0: p.performanceDate = nil
                case 1: p.performanceDate = day(Int.random(in: -20...90, using: &rng))
                case 2: p.runEndDate = p.runEndDate == nil ? day(Int.random(in: -5...95, using: &rng)) : nil
                default:
                    p.runNights = p.runNights.isEmpty
                        ? (0..<Int.random(in: 1...4, using: &rng)).map { _ in day(Int.random(in: -10...90, using: &rng)) }
                        : []
                }
            case .pitched:
                if Int.random(in: 0..<2, using: &rng) == 0 || p.recipients.isEmpty {
                    p.sentAt = p.sentAt == nil ? now : nil
                } else {
                    let r = p.recipients.randomElement(using: &rng)!
                    r.sendStateRaw = r.sendStateRaw == SendState.sent.rawValue
                        ? SendState.pending.rawValue : SendState.sent.rawValue
                }
            case .externalConflictWrite:
                p.setScoutConflict(Int.random(in: 0..<2, using: &rng) == 0 ? nil
                                   : "bookedShoot|\(day(Int.random(in: 0...60, using: &rng)))|Elsewhere")
            default: break
            }
            try context.save()
            return Phase0cLapsStep(label: label, sweeps: false, undo: rowUndo(s, label))

        case .settleTick:
            _ = ContactScoreAdjustment.settleAll(rows(), now: now)
            try context.save()
            return Phase0cLapsStep(label: label, sweeps: false, undo: nil)

        case .retireTick:
            _ = scheduler.retireShowsThatOpened(now: now)
            return Phase0cLapsStep(label: label, sweeps: false, undo: nil)

        case .clockAdvance:
            now = now.addingTimeInterval(Double(Int.random(in: 3_600...5 * 86_400, using: &rng)))
            settle.advance(to: now)
            return Phase0cLapsStep(label: label, sweeps: false, undo: nil)

        case .insertRow:
            let p = mintRow()
            try context.save()
            return Phase0cLapsStep(label: label, sweeps: false, undo: { [self] in
                context.delete(p)
                try context.save()
                return Phase0cLapsStep(label: "undo " + label, sweeps: false, undo: nil)
            })

        case .deleteRow:
            guard let p = pick() else { return nil }
            context.delete(p)
            try context.save()
            return Phase0cLapsStep(label: label, sweeps: false, undo: nil)

        case .dayOffAdd:
            let start = Int.random(in: -5...80, using: &rng)
            let note = Int.random(in: 0..<2, using: &rng) == 0 ? nil : "Away \(start)"
            DayOffEditing.add(start: day(start), end: day(start + Int.random(in: 0...6, using: &rng)), note: note,
                              export: export, into: context)
            guard let row = DayOffEditing.rows(in: context).max(by: { $0.createdAt < $1.createdAt }) else {
                return Phase0cLapsStep(label: label, sweeps: true, undo: nil)
            }
            return Phase0cLapsStep(label: label, sweeps: true, undo: { [self] in
                DayOffEditing.remove(row, export: export, in: context)
                return Phase0cLapsStep(label: "undo " + label, sweeps: true, undo: nil)
            })

        case .dayOffRemove:
            let all = DayOffEditing.rows(in: context).sorted { ($0.startDate, $0.endDate) < ($1.startDate, $1.endDate) }
            guard !all.isEmpty else { return nil }
            let row = all[Int.random(in: 0..<all.count, using: &rng)]
            let (start, end, note) = (row.startDate, row.endDate, row.note)
            DayOffEditing.remove(row, export: export, in: context)
            return Phase0cLapsStep(label: label, sweeps: true, undo: { [self] in
                DayOffEditing.add(start: start, end: end, note: note, export: export, into: context)
                return Phase0cLapsStep(label: "undo " + label, sweeps: true, undo: nil)
            })

        case .weeklyAdd:
            let first = Int.random(in: 0..<3, using: &rng) == 0 ? nil : day(Int.random(in: -5...30, using: &rng))
            let last = Int.random(in: 0..<3, using: &rng) == 0 ? nil : day(Int.random(in: 31...90, using: &rng))
            WeeklyDayOffEditing.add(weekday: Int.random(in: 1...7, using: &rng), firstDate: first, lastDate: last,
                                    note: Int.random(in: 0..<2, using: &rng) == 0 ? nil : "Class", export: export,
                                    into: context)
            guard let rule = WeeklyDayOffEditing.rows(in: context).max(by: { $0.createdAt < $1.createdAt }) else {
                return Phase0cLapsStep(label: label, sweeps: true, undo: nil)
            }
            return Phase0cLapsStep(label: label, sweeps: true, undo: { [self] in
                WeeklyDayOffEditing.remove(rule, export: export, in: context)
                return Phase0cLapsStep(label: "undo " + label, sweeps: true, undo: nil)
            })

        case .weeklyRemove:
            let all = WeeklyDayOffEditing.rows(in: context).sorted { ($0.weekday, $0.note ?? "") < ($1.weekday, $1.note ?? "") }
            guard !all.isEmpty else { return nil }
            let rule = all[Int.random(in: 0..<all.count, using: &rng)]
            let (w, f, l, n, freed) = (rule.weekday, rule.firstDate, rule.lastDate, rule.note, rule.freedDates)
            WeeklyDayOffEditing.remove(rule, export: export, in: context)
            return Phase0cLapsStep(label: label, sweeps: true, undo: { [self] in
                WeeklyDayOffEditing.add(weekday: w, firstDate: f, lastDate: l, note: n, freedDates: freed,
                                        export: export, into: context)
                return Phase0cLapsStep(label: "undo " + label, sweeps: true, undo: nil)
            })

        case .weeklyFree, .weeklyReblock:
            let all = WeeklyDayOffEditing.rows(in: context).sorted { ($0.weekday, $0.note ?? "") < ($1.weekday, $1.note ?? "") }
            guard !all.isEmpty else { return nil }
            let rule = all[Int.random(in: 0..<all.count, using: &rng)]
            if op == .weeklyReblock {
                // With no freed date anywhere, free one in the same step first: both halves sweep, and the
                // index is judged on the net change, which is what the two sweeps leave behind.
                if !all.contains(where: { !$0.freedDates.isEmpty }) {
                    let block = WeeklyDayOffEditing.block(all[0])
                    guard let date = (0..<90).map(day).first(where: { block.blocks($0) }) else { return nil }
                    _ = WeeklyDayOffEditing.free(date, from: all[0], export: export, in: context)
                }
                guard let rule = all.first(where: { !$0.freedDates.isEmpty }),
                      let date = rule.freedDates.sorted().first else { return nil }
                WeeklyDayOffEditing.reblock(date, on: rule, export: export, in: context)
                return Phase0cLapsStep(label: label, sweeps: true, undo: { [self] in
                    _ = WeeklyDayOffEditing.free(date, from: rule, export: export, in: context)
                    return Phase0cLapsStep(label: "undo " + label, sweeps: true, undo: nil)
                })
            }
            let block = WeeklyDayOffEditing.block(rule)
            let blocked = (0..<90).map(day).filter { block.blocks($0) }
            guard let date = blocked.randomElement(using: &rng) else { return nil }
            _ = WeeklyDayOffEditing.free(date, from: rule, export: export, in: context)
            return Phase0cLapsStep(label: label, sweeps: true, undo: { [self] in
                WeeklyDayOffEditing.reblock(date, on: rule, export: export, in: context)
                return Phase0cLapsStep(label: "undo " + label, sweeps: true, undo: nil)
            })

        case .cancelShoot:
            let cancelled = CancelledShootEditing.cancelledIds(in: context)
            let open = bookings.filter { !cancelled.contains($0.id) }
            guard let b = open.randomElement(using: &rng) else { return nil }
            CancelledShootEditing.cancel(bookingIds: [b.id], named: b.shootName, on: b.startDate, export: export,
                                         in: context, now: now)
            return Phase0cLapsStep(label: label, sweeps: true, undo: { [self] in
                CancelledShootEditing.restore(bookingIds: [b.id], export: export, in: context)
                return Phase0cLapsStep(label: "undo " + label, sweeps: true, undo: nil)
            })

        case .restoreShoot:
            let cancelled = CancelledShootEditing.rows(in: context).sorted { $0.bookingId < $1.bookingId }
            guard let row = cancelled.randomElement(using: &rng) else { return nil }
            let (id, name, date) = (row.bookingId, row.shootName, row.startDate)
            CancelledShootEditing.restore(bookingIds: [id], export: export, in: context)
            return Phase0cLapsStep(label: label, sweeps: true, undo: { [self] in
                CancelledShootEditing.cancel(bookingIds: [id], named: name, on: date, export: export,
                                             in: context, now: now)
                return Phase0cLapsStep(label: "undo " + label, sweeps: true, undo: nil)
            })

        case .exportTick:
            let (oldBookings, oldBlocked) = (bookings, blockedDates)
            switch Int.random(in: 0..<4, using: &rng) {
            case 0: bookings.append(booking(bookings.count))
            case 1: if !bookings.isEmpty { bookings.remove(at: Int.random(in: 0..<bookings.count, using: &rng)) }
            case 2: blockedDates.append(day(Int.random(in: -5...80, using: &rng)))
            default: if !blockedDates.isEmpty { blockedDates.remove(at: Int.random(in: 0..<blockedDates.count, using: &rng)) }
            }
            try writeExport()
            scheduler.reapplyConflicts(now: now, from: exportURL, prospects: rows())
            return Phase0cLapsStep(label: label, sweeps: true, undo: { [self] in
                bookings = oldBookings
                blockedDates = oldBlocked
                try writeExport()
                scheduler.reapplyConflicts(now: now, from: exportURL, prospects: rows())
                return Phase0cLapsStep(label: "undo " + label, sweeps: true, undo: nil)
            })
        }
    }

    // MARK: the per-step comparison

    /// Every disagreement found after one step, described by counts and hashes only.
    ///
    /// THROWS when a store write it depends on did not land: the real sweep's save below, or either real lap's
    /// hand restore (#4324). A comparison made after one of those failed would judge a store nobody committed.
    func check(step: Int, label: String, sweeps: Bool, before: [Phase0cPID: String]) throws -> [String] {
        var problems: [String] = []
        let where_ = "seed \(seed) size \(size) step \(step) op \(label)"
        func keys(_ set: Set<Phase0cPID>, _ rows: [Prospect]) -> [String] {
            rows.filter { set.contains($0.persistentModelID) }.map(\.naturalKey)
        }
        func keys(_ writes: [Phase0cPID: String?], _ rows: [Prospect]) -> [String] {
            rows.compactMap { p in writes[p.persistentModelID].map { "\(p.naturalKey)=\($0 ?? "nil")" } }
        }

        // Conflicts first, because a sweep op must be judged before its writes reach the index.
        if sweeps {
            // #4324: the op's sweep ran before this check, through `reapplyAll`'s own `try?` save, so it is
            // saved here as well, for the reason given in the branch below.
            try context.save()
            let intended = conflicts.judge(inputs())
            let changed = sync(from: before, conflictsToo: false)
            let current = rows()
            // The sweep's own writes are exactly the rows whose signature moved (a calendar op writes nothing else).
            var observed: [Phase0cPID: String?] = [:]
            for p in current where changed.contains(p.persistentModelID) { observed[p.persistentModelID] = .some(p.conflictKey) }
            if intended != observed {
                problems.append("\(where_): conflict index intended \(intended.count) writes (\(Phase0cTickLaps.hash(keys(intended, current)))), "
                                + "the real sweep wrote \(observed.count) (\(Phase0cTickLaps.hash(keys(observed, current))))")
            }
            feedConflicts(changed)
        } else {
            _ = sync(from: before)
            let current = rows()
            let intended = conflicts.judge(inputs())
            let dry = Phase0cLapOracle.conflictDryRun(current, export: export, context: context)
            let prior = Phase0cLapOracle.conflictKeys(current)
            ConflictSweep.reapplyAll(export: export, in: context)
            // #4324: saved here, exactly as the world's setup saves after its own sweep. `reapplyAll` saves only
            // through `try?` and only when it changed something, so a failed save there left the sweep's writes
            // pending, and the real laps below would stop on their precondition rather than judge anything.
            // Measured with `reapplyAll`'s own save removed (scripts/mutate.sh, 2026-09-29): with only this save,
            // the harness crashed on "settleReal would roll back an unsaved change" after a sweep op; with this
            // one and the sweep branch's above, it passed, so the probe no longer rests on that `try?`.
            try context.save()
            let real = Phase0cLapOracle.written(before: prior, after: current)
            if intended != dry {
                problems.append("\(where_): conflict index intended \(intended.count) writes (\(Phase0cTickLaps.hash(keys(intended, current)))), "
                                + "the dry run \(dry.count) (\(Phase0cTickLaps.hash(keys(dry, current))))")
            }
            if dry != real {
                problems.append("\(where_): conflict dry run \(dry.count) writes, the real sweep \(real.count): the mirror is wrong")
            }
            feedConflicts(Set(real.keys))
        }

        let current = rows()
        settle.advance(to: now)
        let settleDry = Phase0cLapOracle.settleDryRun(current, now: now)
        let settleReal = try Phase0cLapOracle.settleReal(current, now: now, context: context)
        if settle.due != settleDry {
            problems.append("\(where_): settle due set \(settle.due.count) (\(Phase0cTickLaps.hash(keys(settle.due, current)))) "
                            + "against the dry run \(settleDry.count) (\(Phase0cTickLaps.hash(keys(settleDry, current))))")
        }
        if settleDry != settleReal {
            problems.append("\(where_): settle dry run \(settleDry.count), the real settle \(settleReal.count): the mirror is wrong")
        }

        let candidates = retire.candidates(today: today)
        let retireDry = Phase0cLapOracle.retireDryRun(context: context, today: today)
        let retireReal = try Phase0cLapOracle.retireReal(context: context, today: today)
        if candidates.wentBy != retireDry.wentBy || candidates.passedKept != retireDry.passedKept {
            problems.append("\(where_): retirement index \(candidates.wentBy.count)+\(candidates.passedKept.count) "
                            + "(\(Phase0cTickLaps.hash(keys(candidates.wentBy.union(candidates.passedKept), current)))) against the dry run "
                            + "\(retireDry.wentBy.count)+\(retireDry.passedKept.count) "
                            + "(\(Phase0cTickLaps.hash(keys(retireDry.wentBy.union(retireDry.passedKept), current))))")
        }
        if retireDry.wentBy != retireReal.wentBy || retireDry.passedKept != retireReal.passedKept {
            problems.append("\(where_): retirement dry run \(retireDry.wentBy.count)+\(retireDry.passedKept.count), "
                            + "the real laps \(retireReal.wentBy.count)+\(retireReal.passedKept.count): the mirror is wrong")
        }
        return problems
    }
}

// MARK: - The suite

@MainActor
@Suite("#4106 Phase 0c.7 tick laps: candidate indexes against today's laps as dry runs")
final class QueueEnginePhase0cLapsProbeTests {
    private let sandboxes = TemporarySandboxes()

    /// Drives one world through `ops` seeded operations, checking after every one and every undo.
    private func drive(size: Int, seed: UInt64, ops: Int) throws -> (steps: Int, problems: [String], kinds: Set<String>,
                                                                      dueSeen: Int, retireSeen: Int, writesSeen: Int) {
        let world = try Phase0cLapsWorld(size: size, seed: seed, dir: try sandboxes.make(named: "phase0c7-world"))
        var problems = try world.check(step: 0, label: "build", sweeps: false, before: world.signatures())
        var steps = 1
        var kinds = Set<String>()
        var dueSeen = 0, retireSeen = 0, writesSeen = 0
        var pendingUndo: (() throws -> Phase0cLapsStep?)?
        var opIndex = 0
        var cycle: [Phase0cLapsOp] = []
        while opIndex < ops, problems.count < 5 {
            let before = world.signatures()
            let step: Phase0cLapsStep?
            if let undo = pendingUndo {
                step = try undo()
                pendingUndo = nil
            } else {
                // Seeded shuffles of every kind, one after another, so a short CI run still draws each kind.
                if cycle.isEmpty { cycle = Phase0cLapsOp.allCases.shuffled(using: &world.rng) }
                let op = cycle.removeFirst()
                step = try world.perform(op)
                opIndex += 1
                if let s = step, s.undo != nil, Int.random(in: 0..<10, using: &world.rng) < 3 { pendingUndo = s.undo }
            }
            guard let step else { continue }
            kinds.insert(step.label)
            let dueBefore = world.settle.due.count
            problems += try world.check(step: steps, label: step.label, sweeps: step.sweeps, before: before)
            dueSeen += max(dueBefore, world.settle.due.count) > 0 ? 1 : 0
            let c = world.retire.candidates(today: world.today)
            retireSeen += c.wentBy.count + c.passedKept.count > 0 ? 1 : 0
            writesSeen += world.conflicts.lastJudgedRows > 0 ? 1 : 0
            steps += 1
        }
        return (steps, problems, kinds, dueSeen, retireSeen, writesSeen)
    }

    @Test func candidateIndexesEqualTodaysLapsAfterEveryOperationAndUndo() throws {
        let plan = Phase0cTickLaps.deep ? Phase0cTickLaps.deepPlan : Phase0cTickLaps.ciPlan
        let start = Phase0.now()
        var lines: [String] = []
        var problems: [String] = []
        var kinds = Set<String>()
        for (size, seeds, ops) in plan {
            for seed in seeds {
                let r = try drive(size: size, seed: seed, ops: ops)
                problems += r.problems
                kinds.formUnion(r.kinds)
                lines.append("size \(size) seed \(seed): \(r.steps) checked steps; steps with rows due to settle \(r.dueSeen), "
                             + "with retirement candidates \(r.retireSeen), judging conflict rows \(r.writesSeen); "
                             + "\(r.problems.count) disagreements")
            }
        }
        let missing = Phase0cLapsOp.allCases.map(\.rawValue).filter { !kinds.contains($0) }
        Phase0cTickLaps.say("""
            property harness (\(Phase0cTickLaps.deep ? "deep" : "CI") settings: \(plan.map { "\($0.seeds.count) seeds of \($0.ops) ops at \($0.size) rows" }.joined(separator: ", "))) \
            in \(String(format: "%.1f", Phase0.ms(since: start) / 1000)) s
              \(lines.joined(separator: "\n  "))
              operation kinds exercised \(kinds.filter { !$0.hasPrefix("undo") }.count) of \(Phase0cLapsOp.allCases.count), \
            undo kinds \(kinds.filter { $0.hasPrefix("undo") }.count); rows rollback() left holding a real lap's writes, \
            put back by hand \(Phase0cLapOracle.rollbackLeaks)\(missing.isEmpty ? "" : "; never drawn: " + missing.joined(separator: ","))
            """)
        for p in problems.prefix(10) { Phase0cTickLaps.say("MISMATCH " + p) }
        #expect(problems.isEmpty, "0c.7: \(problems.count) disagreements; first: \(problems.first ?? "")")
        #expect(missing.isEmpty, "0c.7: operation kinds never drawn: \(missing)")
    }

    // #4324: the header states the plan the harness runs, read from the constants rather than trusted. The
    // header is joined into one line first, so rewrapping it cannot fail this and cannot satisfy it either.
    @Test func theHeaderStatesThePlanTheHarnessRuns() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath), encoding: .utf8)
        let header = try #require(source.components(separatedBy: "\nenum Phase0cTickLaps").first)
        let prose = header.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("//") }
            .map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")
        #expect(prose.count > 500, "the header was not found, so nothing was compared")
        #expect(prose.contains(Phase0cTickLaps.describe(Phase0cTickLaps.ciPlan)),
                "the header no longer states the CI plan: \(Phase0cTickLaps.describe(Phase0cTickLaps.ciPlan))")
        #expect(prose.contains(Phase0cTickLaps.describe(Phase0cTickLaps.deepPlan)),
                "the header no longer states the deep plan: \(Phase0cTickLaps.describe(Phase0cTickLaps.deepPlan))")
    }

    // Carries its own text, so the tests can see the save's own reason reaches the error it becomes (L520).
    private struct SaveRefused: Error, CustomStringConvertible {
        var description: String { "the store refused the save: disk full" }
    }

    // #4324: a real lap whose hand restore cannot be saved THROWS, naming its lap, rather than reading as a
    // restore that landed. Each lap is driven to an instant where it really writes, or the save it is meant
    // to fail would never be reached and the test would pass on a restore that never ran (L159).
    @Test func aSettleRestoreThatFailsToSaveThrows() throws {
        let world = try Phase0cLapsWorld(size: 60, seed: 11, dir: try sandboxes.make(named: "phase0c7-restore-settle"))
        let rows = world.rows()
        let instant = try #require((0...400).lazy.map { world.now.addingTimeInterval(Double($0) * 86_400) }
            .first { !Phase0cLapOracle.settleDryRun(rows, now: $0).isEmpty },
            "no instant in 400 days where settle writes anything, so the restore is never reached")
        let leaksBefore = Phase0cLapOracle.rollbackLeaks
        let error = #expect(throws: Phase0cLapOracle.RestoreNotSaved.self) {
            _ = try Phase0cLapOracle.settleReal(rows, now: instant, context: world.context,
                                                save: { _ in throw SaveRefused() })
        }
        #expect(error?.lap == "settle")
        #expect(error?.underlying.contains("disk full") == true, "the save's own reason was lost: \(error?.underlying ?? "")")
        #expect(Phase0cLapOracle.rollbackLeaks > leaksBefore, "the settle restore wrote nothing, so no save was asked")
    }

    @Test func aRetirementRestoreThatFailsToSaveThrows() throws {
        let world = try Phase0cLapsWorld(size: 60, seed: 11, dir: try sandboxes.make(named: "phase0c7-restore-retire"))
        let day = try #require((0...400).lazy.map { ScoutTestClock.day($0, after: world.now) }
            .first { let d = Phase0cLapOracle.retireDryRun(context: world.context, today: $0)
                     return !d.wentBy.isEmpty || !d.passedKept.isEmpty },
            "no day in 400 where a retirement dismisses anything, so the restore is never reached")
        let error = #expect(throws: Phase0cLapOracle.RestoreNotSaved.self) {
            _ = try Phase0cLapOracle.retireReal(context: world.context, today: day, save: { _ in throw SaveRefused() })
        }
        #expect(error?.lap == "retirement")
        #expect(error?.underlying.contains("disk full") == true, "the save's own reason was lost: \(error?.underlying ?? "")")
    }

    /// Fact 8's clock half: the due set equals settle's changed set at every instant on either side of every
    /// expiry crossing in the fixture (one millisecond before, the computed crossing itself, one after), plus
    /// 50 evenly spaced instants, with no write in between.
    @Test func settleDueSetEqualsSettleAtEveryExpiryCrossing() throws {
        var lines: [String] = []
        var problems: [String] = []
        for size in [60, 300] {
            let world = try Phase0cLapsWorld(size: size, seed: 7, dir: try sandboxes.make(named: "phase0c7-crossing"))
            let rows = world.rows()
            let horizon = world.now.addingTimeInterval(130 * 86_400)
            let crossings = Set(rows.compactMap { p -> Date? in
                p.reachabilityProbedAt.map { $0.addingTimeInterval(Reachability.probeFreshness) }
            }).filter { $0 > world.now && $0 <= horizon }
            // Every crossing at 60 rows; at 300, twenty spread across them unless deep, for the harness budget.
            let ordered = crossings.sorted()
            let chosen = size == 60 || Phase0cTickLaps.deep || ordered.count <= 20 ? ordered
                : (0..<20).map { ordered[$0 * ordered.count / 20] }
            var instants = Set<Date>()
            for c in chosen { for d in [-0.001, 0, 0.001] { instants.insert(c.addingTimeInterval(d)) } }
            for k in 1...50 { instants.insert(world.now.addingTimeInterval(Double(k) * 130 * 86_400 / 50)) }
            var index = world.settle
            var dueMax = 0
            for instant in instants.filter({ $0 >= world.now }).sorted() {
                index.advance(to: instant)
                let dry = Phase0cLapOracle.settleDryRun(rows, now: instant)
                let real = try Phase0cLapOracle.settleReal(rows, now: instant, context: world.context)
                dueMax = max(dueMax, dry.count)
                if index.due != dry { problems.append("size \(size): due set \(index.due.count) against dry run \(dry.count) at +\(instant.timeIntervalSince(world.now)) s") }
                if dry != real { problems.append("size \(size): dry run \(dry.count) against real settle \(real.count) at +\(instant.timeIntervalSince(world.now)) s") }
            }
            lines.append("size \(size): \(chosen.count) of \(crossings.count) expiry crossings, \(instants.count) instants, most rows due at one instant \(dueMax)")
        }
        Phase0cTickLaps.say("settle due set at every expiry crossing\n  " + lines.joined(separator: "\n  ")
                        + "\n  rows rollback() left holding the real lap's writes, put back by hand so far: \(Phase0cLapOracle.rollbackLeaks)")
        #expect(problems.isEmpty, "0c.7 settle: \(problems.count) disagreements; first: \(problems.first ?? "")")
    }

    // MARK: - The clone probe (opt in)

    private func corpora(_ name: String) throws -> [(label: String, url: URL)] {
        let dir = try sandboxes.make(named: name)
        guard let base = try LiveStoreClone.makeClone(in: dir) else {
            throw LiveStoreClone.Refusal.backupFailed("no live store on this machine")
        }
        return [("live clone", base), ("4x", try Phase0.scaledCopy(of: base, factor: 4, in: dir))]
    }

    /// A copy of the RELEASE app's Downbeat export. Not `DownbeatBridge.defaultURL`: under test that resolves
    /// to the test run's own handoff folder (#2097), where no export exists, so 0b.5 timed the bookings lap
    /// with the export MISSING and the health guard refused before boxing or classifying anything.
    private func scratchExport() throws -> URL {
        let out = try sandboxes.make(named: "phase0c7-export").appendingPathComponent("downbeat-export.json")
        let live = StoreLocation.handoffDirectory(appSupport: StoreLocation.appSupport, isDebugBuild: false)
            .appendingPathComponent("downbeat-export.json")
        if FileManager.default.fileExists(atPath: live.path) {
            try FileManager.default.copyItem(at: live, to: out)
        }
        return out
    }

    private func missingExport() throws -> URL {
        try sandboxes.make(named: "phase0c7-no-export").appendingPathComponent("downbeat-export.json")
    }

    @Test(.enabled(if: Phase0.liveStoreExists, "no live store on this machine"))
    func probe0c7TickLapsOnTheClone() throws {
        guard Phase0cTickLaps.enabled else {
            print("phase0c7 clone probe: not measured. Set TEST_RUNNER_MEASURE_4106_PHASE0C_LAPS=1 to run it.")
            return
        }
        let exportURL = try scratchExport()
        var verdicts: [String] = []
        for (label, url) in try corpora("phase0c7") {
            let container = try Phase0.openContainer(at: url)
            let ctx = container.mainContext
            ctx.autosaveEnabled = false
            defer { withExtendedLifetime(container) {} }
            let now = Date()
            verdicts += try bookingsBlock(label: label, ctx: ctx, exportURL: exportURL, now: now)
            verdicts += try retirementBlock(label: label, ctx: ctx, now: now)
            verdicts += try conflictsBlock(label: label, ctx: ctx, exportURL: exportURL, now: now)
            closingReadBlock(label: label, ctx: ctx, now: now)
        }
        Phase0cTickLaps.say("0c.7 stop rule verdicts\n  " + verdicts.joined(separator: "\n  "))
    }

    // MARK: bookings: attribution, then settle's due set and expiry index

    private func bookingsBlock(label: String, ctx: ModelContext, exportURL: URL, now: Date) throws -> [String] {
        let scheduler = ReconcileScheduler(context: ctx, replyRunAlive: { _ in false })
        // A warm-up tick first, so the first tick's real writes are not what the samples time (0b.5's rule).
        _ = scheduler.reconcileBookings(now: now, from: exportURL, rows: StoreRows.fetch(from: ctx))
        let rows = StoreRows.fetch(from: ctx)
        for p in rows.prospects { _ = p.recipients.count }
        let loaded = DownbeatBridge.loadWithHealth(from: exportURL, now: now)

        let whole = Phase0.median5 { _ = scheduler.reconcileBookings(now: now, from: exportURL, rows: rows) }
        let noExport = try missingExport()
        let wholeMissing = Phase0.median5 { _ = scheduler.reconcileBookings(now: now, from: noExport, rows: rows) }
        // 0b.5 read the rows through a fetch it had not walked; this is the lap on a context that has read
        // nothing, so relationship faults are paid inside it. Five fresh contexts, one sample each.
        let freshContext = Phase0b.reading((0..<5).map { _ in
            let fresh = ModelContext(ctx.container)
            let freshScheduler = ReconcileScheduler(context: fresh, replyRunAlive: { _ in false })
            let freshRows = StoreRows.fetch(from: fresh)
            return Phase0.time { _ = freshScheduler.reconcileBookings(now: now, from: exportURL, rows: freshRows) }
        })
        let load = Phase0.median5 { _ = DownbeatBridge.loadWithHealth(from: exportURL, now: now) }
        var live: [Prospect] = []
        let liveFilter = Phase0.median5 { live = rows.liveProspects }
        var entities: [any BookingMatchable] = []
        let boxing = Phase0.median5 { entities = DownbeatBooking.bookingEntities(prospects: live, in: ctx) }
        var contacted: [any BookingMatchable] = []
        let filter = Phase0.median5 { contacted = entities.filter { $0.wasProvablyContacted } }
        var sorted: [any BookingMatchable] = []
        let sort = Phase0.median5 {
            sorted = contacted.sorted {
                let d0 = $0.performanceDate ?? "", d1 = $1.performanceDate ?? ""
                if d0 != d1 { return d0 < d1 }
                if $0.permitsAutoBook != $1.permitsAutoBook { return !$0.permitsAutoBook }
                return $0.groupName < $1.groupName
            }
        }
        let classify = Phase0.median5 { for e in sorted { _ = BookingMatch.classify(entity: e, bookings: loaded.bookings) } }
        // The two other things the loop does per contacted row: read its guards, and (on no match) ask every
        // client whether it confidently names the row's group.
        func orgMatch(_ e: any BookingMatchable) -> Bool {
            loaded.clients.contains { client in
                GroupNameMatch.isConfident(client.displayName, e.groupName)
                    || (client.shortName.map { GroupNameMatch.isConfident($0, e.groupName) } ?? false)
            }
        }
        let results = sorted.map { BookingMatch.classify(entity: $0, bookings: loaded.bookings) }
        let unmatched = zip(sorted, results).filter { $0.1 == .none && !$0.0.bookingPriorRelationshipBooked }.map(\.0)
        let clientMatch = Phase0.median5 { for e in unmatched { _ = orgMatch(e) } }
        let guards = Phase0.median5 {
            for e in sorted {
                _ = e.bookingManualOutcome || e.bookingIsBooked || e.autoBookingRejectedWithoutId
                    || e.rejectedBookingIds.isEmpty || e.bookingSuggestionDismissed || e.bookingPriorRelationshipBooked
            }
        }
        // A bookings patch re-asks one row when that row changes: classify plus the client match, every
        // contacted row, median of three.
        var perContacted: [Double] = []
        for e in sorted {
            perContacted.append(Phase0cTickLaps.median3 {
                if BookingMatch.classify(entity: e, bookings: loaded.bookings) == .none { _ = orgMatch(e) }
            })
        }
        let contactedSpread = Phase0cTickLaps.Spread(samples: perContacted)
        let reconcile = Phase0.median5 {
            _ = DownbeatBooking.reconcileBooked(entities: entities, clients: loaded.clients, bookings: loaded.bookings,
                                                health: loaded.health, now: now)
        }
        ctx.rollback()
        let settleReal = Phase0.median5 {
            _ = ContactScoreAdjustment.settleAll(live, now: now)
            ctx.rollback()
        }
        let settleDry = Phase0.median5 { _ = Phase0cLapOracle.settleDryRun(live, now: now) }
        let named = load.median + liveFilter.median + boxing.median + reconcile.median + settleReal.median

        // The prototype: cold build, equality at 50 or more instants (every sampled expiry crossing on both
        // sides), and its costs over every real key.
        var index = Phase0cSettleIndex(rows: [], now: now)
        let cold = Phase0.median5 {
            index = Phase0cSettleIndex(rows: live.map { ($0.persistentModelID, Phase0cSettleFacts.extract($0)) }, now: now)
        }
        let horizon = now.addingTimeInterval(400 * 86_400)
        let crossings = Set(live.compactMap { p -> Date? in
            p.reachabilityProbedAt.map { $0.addingTimeInterval(Reachability.probeFreshness) }
        }).filter { $0 > now && $0 <= horizon }.sorted()
        let sampled: [Date] = crossings.isEmpty ? [] : (0..<min(20, crossings.count)).map { crossings[$0 * crossings.count / min(20, crossings.count)] }
        var instants = Set<Date>()
        for c in sampled { for d in [-0.001, 0, 0.001] { instants.insert(c.addingTimeInterval(d)) } }
        for k in 0..<max(10, 50 - instants.count) { instants.insert(now.addingTimeInterval(Double(k) * 400 * 86_400 / 50)) }
        var check = index
        var indexMismatch = 0, mirrorMismatch = 0, dueMost = 0
        for instant in instants.filter({ $0 >= now }).sorted() {
            check.advance(to: instant)
            let dry = Phase0cLapOracle.settleDryRun(live, now: instant)
            let real = try Phase0cLapOracle.settleReal(live, now: instant, context: ctx)
            dueMost = max(dueMost, dry.count)
            if check.due != dry { indexMismatch += 1 }
            if dry != real { mirrorMismatch += 1 }
        }
        // Row change: extract plus update, every row, median of three.
        var perRow: [Double] = []
        for p in live {
            let pid = p.persistentModelID
            perRow.append(Phase0cTickLaps.median3 { index.update(pid, Phase0cSettleFacts.extract(p)) })
        }
        // Clock: advance across each pending crossing in turn, one sample each (the state moves).
        var perCrossing: [Double] = []
        var moving = index
        var rowsPerCrossing: [Int] = []
        for c in crossings {
            moving.judged = 0
            perCrossing.append(Phase0.time { moving.advance(to: c.addingTimeInterval(0.001)) })
            rowsPerCrossing.append(moving.judged)
        }
        let rowSpread = Phase0cTickLaps.Spread(samples: perRow), clockSpread = Phase0cTickLaps.Spread(samples: perCrossing)
        let equal = indexMismatch == 0 && mirrorMismatch == 0
        Phase0cTickLaps.say("""
            bookings [\(label)] \(live.count) shows, \(entities.count) booking entities, \(contacted.count) contacted, \
            \(loaded.bookings.count) bookings, export \(loaded.health), \(Phase0.load())
              today's whole lap (reconcileBookings)                 \(whole.text)
              the same lap with the export missing (0b.5's case)    \(wholeMissing.text)
              the whole lap on a fresh context, faults included     \(freshContext.text)
              attribution: export load                              \(load.text)
                           liveProspects filter                     \(liveFilter.text)
                           boxing (bookingEntities, inquiry fetch)  \(boxing.text)
                           reconcileBooked on boxed entities        \(reconcile.text)
                             of which: contacted filter             \(filter.text)
                                       sort                         \(sort.text)
                                       classify loop (dry)          \(classify.text)
                                       client match on \(unmatched.count) unmatched rows over \(loaded.clients.count) clients  \(clientMatch.text)
                                       guard reads                  \(guards.text)
                           settleAll (real, rolled back)            \(settleReal.text)
                           settle guard alone (dry run)             \(settleDry.text)
              per contacted row re-asked (classify + client match)  \(contactedSpread.text)
                           named parts sum \(String(format: "%.1f", named)) ms against the whole \(String(format: "%.1f", whole.median)) ms
              settle due set: cold build                            \(cold.text)
                due set against dry run at \(instants.count) instants (\(sampled.count) of \(crossings.count) crossings in 400 days, each at -1 ms, 0, +1 ms): \
            \(indexMismatch) mismatches; dry run against real settle: \(mirrorMismatch); most rows due at one instant \(dueMost)
                per row change (extract + update)                   \(rowSpread.text)
                per clock crossing (advance)                        \(clockSpread.text); rows judged per crossing max \(rowsPerCrossing.max() ?? 0), median \(rowsPerCrossing.sorted().dropFirst(rowsPerCrossing.count / 2).first ?? 0)
            """)
        return ["settle due set [\(label)]: \(equal ? "PASS" : "FAIL") equality (\(indexMismatch) index, \(mirrorMismatch) mirror mismatches); "
                + "row change max \(String(format: "%.3f", rowSpread.max)) ms, crossing max \(String(format: "%.3f", clockSpread.max)) ms "
                + "judging up to \(rowsPerCrossing.max() ?? 0) rows at one instant (\(max(rowSpread.max, clockSpread.max) < 1 ? "under" : "OVER") "
                + "1 ms, the retirement line, since T9 names none for settle)"]
    }

    // MARK: retirement

    private func retirementBlock(label: String, ctx: ModelContext, now: Date) throws -> [String] {
        let rows = try ctx.fetch(FetchDescriptor<Prospect>())
        for p in rows { _ = p.recipients.count }
        let today = QueueModel.easternToday(now)
        // #4324: a restore that failed to save ends the block rather than being timed as if it had not.
        var restoreFailure: Error?
        let whole = Phase0.median5 {
            // Once a restore has failed its writes are still pending, and the next call would stop on
            // `retireReal`'s precondition before this block could report the failure, so it stops here.
            guard restoreFailure == nil else { return }
            do { _ = try Phase0cLapOracle.retireReal(context: ctx, today: today) } catch { restoreFailure = error }
        }
        if let restoreFailure { throw restoreFailure }
        let wentFetch = Phase0.median5 {
            _ = try? ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.statusRaw == "new" }))
        }
        let keptFetch = Phase0.median5 {
            _ = try? ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.statusRaw == "queued"
                || $0.statusRaw == "drafted" || $0.statusRaw == "approved" }))
        }
        var index = Phase0cRetireIndex(rows: [])
        let cold = Phase0.median5 {
            index = Phase0cRetireIndex(rows: rows.map { ($0.persistentModelID, Phase0cRetireFacts.extract($0)) })
        }
        var indexMismatch = 0, mirrorMismatch = 0, mirrorChecked = 0, most = 0
        var queries: [Double] = []
        for k in 0..<50 {
            let day = ScoutTestClock.day(k, after: now)
            var c: (wentBy: Set<Phase0cPID>, passedKept: Set<Phase0cPID>) = ([], [])
            queries.append(Phase0cTickLaps.median3 { c = index.candidates(today: day) })
            let dry = Phase0cLapOracle.retireDryRun(context: ctx, today: day)
            most = max(most, dry.wentBy.count + dry.passedKept.count)
            if c.wentBy != dry.wentBy || c.passedKept != dry.passedKept { indexMismatch += 1 }
            if label == "live clone" || k % 5 == 0 {
                let real = try Phase0cLapOracle.retireReal(context: ctx, today: day)
                mirrorChecked += 1
                if real.wentBy != dry.wentBy || real.passedKept != dry.passedKept { mirrorMismatch += 1 }
            }
        }
        var perRow: [Double] = []
        for p in rows {
            let pid = p.persistentModelID
            perRow.append(Phase0cTickLaps.median3 { index.update(pid, Phase0cRetireFacts.extract(p)) })
        }
        let rowSpread = Phase0cTickLaps.Spread(samples: perRow), querySpread = Phase0cTickLaps.Spread(samples: queries)
        Phase0cTickLaps.say("""
            retirement [\(label)] \(rows.count) shows, \(index.filed) filed (untriaged \(index.untriaged.rowCount) \
            under \(index.untriaged.keys.count) opening nights, kept unpitched \(index.kept.rowCount) under \
            \(index.kept.keys.count) last nights), \(Phase0.load())
              today's two laps (real, rolled back)                  \(whole.text)
                of which: the untriaged fetch                       \(wentFetch.text)
                          the kept fetch                            \(keptFetch.text)
              index cold build                                      \(cold.text)
              index against dry run over 50 days: \(indexMismatch) mismatches; dry run against the real laps on \(mirrorChecked) days: \(mirrorMismatch); most rows due on one day \(most)
              per row change (extract + update)                     \(rowSpread.text)
              per day advance (candidates for the day)              \(querySpread.text)
            """)
        let equal = indexMismatch == 0 && mirrorMismatch == 0
        let worst = max(rowSpread.max, querySpread.max)
        return ["retirement [\(label)]: \(equal && worst < 1 ? "PASS" : "FAIL") (\(indexMismatch) index, \(mirrorMismatch) mirror mismatches; "
                + "worst per change \(String(format: "%.3f", worst)) ms against 1 ms)"]
    }

    // MARK: conflicts

    private func conflictsBlock(label: String, ctx: ModelContext, exportURL: URL, now: Date) throws -> [String] {
        let loaded = DownbeatBridge.loadWithHealth(from: exportURL, now: now)
        let export: DayOffEditing.Export = (loaded.bookings, loaded.blockedDates, loaded.health)
        var rows = try ctx.fetch(FetchDescriptor<Prospect>())
        // Bring the copy into step with this export first, as the tick would, and prove the mirror on it.
        let dryFirst = Phase0cLapOracle.conflictDryRun(rows, export: export, context: ctx)
        let prior = Phase0cLapOracle.conflictKeys(rows)
        _ = ConflictSweep.reapplyAll(export: export, in: ctx, prospects: rows)
        let realFirst = Phase0cLapOracle.written(before: prior, after: rows)
        rows = try ctx.fetch(FetchDescriptor<Prospect>())

        let whole = Phase0.median5 { _ = ConflictSweep.reapplyAll(export: export, in: ctx, prospects: rows) }
        let dryWhole = Phase0.median5 { _ = Phase0cLapOracle.conflictDryRun(rows, export: export, context: ctx) }
        var inputs = Phase0cCalendarInputs.read(export: export, context: ctx)
        let readInputs = Phase0.median5 { inputs = Phase0cCalendarInputs.read(export: export, context: ctx) }
        let build = Phase0.median5 { _ = inputs.build() }
        let facts = rows.map { ($0.persistentModelID, Phase0cConflictFacts.extract($0)) }
        var index = Phase0cConflictIndex(rows: [], inputs: inputs)
        let cold = Phase0.median5 { index = Phase0cConflictIndex(rows: facts, inputs: inputs) }
        let firstJudge = index.judge(inputs)
        let withKey = rows.filter { $0.conflictKey != nil }.count
        let nights = Set(facts.flatMap { $0.1.nights }).sorted()

        // Equality on sampled real keys: each change made in the context (unsaved), the dry run read from it,
        // the index judged against the same inputs, then rolled back and the index judged back.
        var sampleMismatch = 0, samples = 0
        var sampleDetail: [String] = []
        func sample(_ kind: String, _ make: () -> Void, rowsTouched: [Prospect] = [], export ex: DayOffEditing.Export? = nil,
                    putBack: () -> Void = {}) {
            make()
            let e = ex ?? export
            for p in rowsTouched { index.update(p.persistentModelID, Phase0cConflictFacts.extract(p)) }
            let intended = index.judge(Phase0cCalendarInputs.read(export: e, context: ctx))
            let dry = Phase0cLapOracle.conflictDryRun(rows, export: e, context: ctx)
            samples += 1
            if intended != dry {
                sampleMismatch += 1
                let extra = intended.keys.filter { dry[$0] == nil }.count
                let missed = dry.keys.filter { intended[$0] == nil }.count
                let differ = intended.keys.filter { k in dry[k].map { $0 != intended[k]! } ?? false }.count
                sampleDetail.append("\(kind): index \(intended.count) writes, dry run \(dry.count); extra \(extra), missed \(missed), "
                                    + "different key \(differ); judged \(index.lastJudgedRows) rows over \(index.lastChangedNights) "
                                    + "changed of \(index.lastCandidateNights) candidate nights")
            }
            ctx.rollback()
            putBack()   // rollback() leaves a fetched row's values as they were written (measured above)
            for p in rowsTouched { index.update(p.persistentModelID, Phase0cConflictFacts.extract(p)) }
            _ = index.judge(Phase0cCalendarInputs.read(export: export, context: ctx))
        }
        var g = SeededGenerator(seed: 47)
        for n in nights.shuffled(using: &g).prefix(10) {
            sample("day off") { ctx.insert(DayOff(startDate: n, endDate: n, note: "Probe")) }
        }
        for w in [2, 5, 7] { sample("weekly \(w)") { ctx.insert(WeeklyDayOff(weekday: w, note: "Probe")) } }
        for b in loaded.bookings.prefix(5) {
            sample("cancel") { ctx.insert(CancelledShoot(bookingId: b.id, shootName: b.shootName, startDate: b.startDate, cancelledAt: now)) }
            sample("booking lost", {}, export: (loaded.bookings.filter { $0 != b }, loaded.blockedDates, loaded.health))
        }
        for p in rows.shuffled(using: &g).prefix(5) where p.performanceDate != nil {
            let (nights, end, opening) = (p.runNights, p.runEndDate, p.performanceDate)
            sample("date move", {
                p.runNights = []
                p.runEndDate = nil
                p.performanceDate = ScoutTestClock.day(7, after: EasternDate.date(from: p.performanceDate!) ?? now)
            }, rowsTouched: [p], putBack: {
                p.runNights = nights
                p.runEndDate = end
                p.performanceDate = opening
            })
        }

        // Cost over every real key, each change and its reverse timed as a pair, three times (median).
        func pairCost(_ changed: Phase0cCalendarInputs) -> (Double, Double) {
            var there: [Double] = [], back: [Double] = []
            for _ in 0..<3 {
                there.append(Phase0.time { _ = index.judge(changed) })
                back.append(Phase0.time { _ = index.judge(inputs) })
            }
            return (there.sorted()[1], back.sorted()[1])
        }
        var dayOffAdd: [Double] = [], dayOffRemove: [Double] = [], exportGain: [Double] = [], exportLose: [Double] = []
        var weeklyAdd: [Double] = [], weeklyRemove: [Double] = [], cancel: [Double] = [], restore: [Double] = []
        var bookingLost: [Double] = [], bookingBack: [Double] = [], dateMove: [Double] = []
        var biggest = (candidates: 0, changed: 0, judged: 0)
        for n in nights {
            var c = inputs
            c.daysOff.append(DayOffRange(startDate: n, endDate: n, note: "Probe"))
            let (a, r) = pairCost(c)
            dayOffAdd.append(a); dayOffRemove.append(r)
            var e = inputs
            e.blockedDates.append(n)
            let (g1, l1) = pairCost(e)
            exportGain.append(g1); exportLose.append(l1)
        }
        for w in 1...7 {
            var c = inputs
            c.weekly.append(WeeklyBlock(weekday: w, note: "Probe"))
            _ = index.judge(c)
            if index.lastJudgedRows > biggest.judged {
                biggest = (index.lastCandidateNights, index.lastChangedNights, index.lastJudgedRows)
            }
            _ = index.judge(inputs)
            let (a, r) = pairCost(c)
            weeklyAdd.append(a); weeklyRemove.append(r)
        }
        for b in loaded.bookings {
            var c = inputs
            c.cancelled.insert(b.id)
            let (a, r) = pairCost(c)
            cancel.append(a); restore.append(r)
            var l = inputs
            l.bookings.removeAll { $0 == b }
            let (x, y) = pairCost(l)
            bookingLost.append(x); bookingBack.append(y)
        }
        func shift(_ day: String) -> String {
            ScoutTestClock.day(7, after: EasternDate.date(from: day) ?? now)
        }
        for (pid, f) in facts {
            var moved = f
            switch f.playing {
            case .recorded(let ns): moved.playing = .recorded(ns.map(shift))
            case .spanOnly(let o, let l): moved.playing = .spanOnly(opening: shift(o), lastNight: shift(l))
            case .undated: continue
            }
            dateMove.append(Phase0cTickLaps.median3 {
                index.update(pid, moved)
                _ = index.judge(inputs)
                index.update(pid, f)
                _ = index.judge(inputs)
            } / 2)
        }
        let kinds: [(String, Phase0cTickLaps.Spread)] = [
            ("day off added (DayOff.swift:153)", .init(samples: dayOffAdd)),
            ("day off removed (DayOff.swift:161)", .init(samples: dayOffRemove)),
            ("weekly rule added (WeeklyDayOff.swift:140)", .init(samples: weeklyAdd)),
            ("weekly rule removed (WeeklyDayOff.swift:148)", .init(samples: weeklyRemove)),
            ("shoot cancelled (CancelledShootEditing.swift:86)", .init(samples: cancel)),
            ("shoot restored (CancelledShootEditing.swift:104)", .init(samples: restore)),
            ("export night gained (tick, ReconcileScheduler.swift:378)", .init(samples: exportGain)),
            ("export night lost (tick)", .init(samples: exportLose)),
            ("export booking lost (tick)", .init(samples: bookingLost)),
            ("export booking back (tick)", .init(samples: bookingBack)),
            ("date move, one row (per judge)", .init(samples: dateMove)),
        ]
        let calendarKinds = kinds.prefix(10)
        let worst = calendarKinds.map(\.1.max).max() ?? 0
        let firstEqual = firstJudge.isEmpty && dryFirst == realFirst
        Phase0cTickLaps.say("""
            conflicts [\(label)] \(rows.count) shows, \(withKey) holding a conflict key, \(nights.count) playing nights indexed \
            (largest night \(index.largestNight) rows), \(loaded.bookings.count) bookings, \(Phase0.load())
              first real sweep of the copy: dry run \(dryFirst.count) writes, real \(realFirst.count), same \(dryFirst == realFirst); \
            index's first judge after it \(firstJudge.count) writes
              today's reapplyAll (real, nothing to write)           \(whole.text)
              today's comparison as a dry run                       \(dryWhole.text)
              reading the five calendar inputs                      \(readInputs.text)
              building the calendar from them                       \(build.text)
              index cold build                                      \(cold.text)
              sampled real keys against the dry run: \(sampleMismatch) mismatches of \(samples)
              \(sampleDetail.joined(separator: "\n  "))
              widest weekly rule judged \(biggest.judged) rows over \(biggest.changed) changed of \(biggest.candidates) candidate nights
              \(kinds.map { Phase0b.pad($0.0, 58) + " " + $0.1.text }.joined(separator: "\n  "))
              the index's judge includes building the new calendar; reading the inputs above is paid on top of it
            """)
        let equal = sampleMismatch == 0 && firstEqual
        let weeklyWorst = max(kinds[2].1.max, kinds[3].1.max)
        let datedWorst = calendarKinds.enumerated().filter { $0.offset != 2 && $0.offset != 3 }.map(\.element.1.max).max() ?? 0
        let verdict = !equal ? "STAYS WHOLE (not proven equal)"
            : worst + readInputs.median < 2 ? "PASS" : "FAIL on cost, proven equal"
        return ["conflicts [\(label)]: \(verdict) (\(sampleMismatch) sampled mismatches, first sweep mirror "
                + "\(firstEqual ? "equal" : "UNEQUAL"); worst dated change \(String(format: "%.3f", datedWorst)) ms, worst weekly "
                + "rule \(String(format: "%.3f", weeklyWorst)) ms, each plus \(String(format: "%.3f", readInputs.median)) ms "
                + "reading inputs, against 2 ms per calendar change)"]
    }

    // MARK: the closing read

    private func closingReadBlock(label: String, ctx: ModelContext, now: Date) {
        let rows = StoreRows.fetch(from: ctx)
        for p in rows.prospects { _ = p.recipients.count }
        let whole = Phase0.median5 {
            _ = DueReading.derive(prospects: rows.prospects, inquiries: rows.inquiries, now: now, replyRunAlive: false)
        }
        let replied = Phase0.median5 { _ = rows.prospects.filter(ReconcileScheduler.hasNewReply) }
        let booked = Phase0.median5 { _ = rows.prospects.filter { $0.outcome == .booked } }
        let counts = Phase0.median5 {
            _ = DueWork.counts(prospects: rows.prospects, inquiries: rows.inquiries, now: now, replyRunAlive: false)
        }
        let next = Phase0.median5 { _ = DueWork.nextChange(prospects: rows.prospects, now: now, replyRunAlive: false) }
        var totals = Phase0cClosingTotals(now: now)
        let byPID = Dictionary(rows.prospects.map { ($0.persistentModelID, $0) }, uniquingKeysWith: { a, _ in a })
        let cold = Phase0.median5 {
            totals = Phase0cClosingTotals(now: now)
            for p in rows.prospects { totals.update(p.persistentModelID, p) }
        }
        let read = Phase0.median5 { _ = totals.read(inquiries: rows.inquiries, replyRunAlive: false) }
        var perRow: [Double] = []
        for p in rows.prospects {
            let pid = p.persistentModelID
            perRow.append(Phase0cTickLaps.median3 { totals.update(pid, p) })
        }
        var mismatches = 0, comparisons = 0, refreshed: [Int] = []
        var detail: [String] = []
        for k in 0..<50 {
            let instant = now.addingTimeInterval(Double(k) * 13 * 3600 + Double(k % 7) * 611)
            refreshed.append(totals.advance(to: instant) { byPID[$0] })
            for alive in [false, true] where k % 5 == 0 || !alive {
                comparisons += 1
                let patched = totals.read(inquiries: rows.inquiries, replyRunAlive: alive)
                let today = DueReading.derive(prospects: rows.prospects, inquiries: rows.inquiries, now: instant,
                                              replyRunAlive: alive)
                if patched.due != today.due || patched.replied != Set(today.replied.map(\.key))
                    || patched.booked != Set(today.booked.map(\.key)) {
                    mismatches += 1
                    if detail.count < 3 { detail.append("instant \(k) alive \(alive): patched \(patched.due.total) against \(today.due.total)") }
                }
            }
        }
        let rowSpread = Phase0cTickLaps.Spread(samples: perRow)
        Phase0cTickLaps.say("""
            closing read [\(label)] \(rows.prospects.count) shows, \(rows.inquiries.count) inquiries, \(Phase0.load())
              today's DueReading.derive on main                     \(whole.text)
                of which: replied filter                            \(replied.text)
                          booked filter                             \(booked.text)
                          DueWork.counts                            \(counts.text)
                          DueWork.nextChange                        \(next.text)
              patched totals: cold build                            \(cold.text)
                              the read (lists, counts, inquiries)   \(read.text)
                              per row change                        \(rowSpread.text)
              patched read against derive at 50 instants (13 h apart, 10 with a reply run alive): \(mismatches) of \(comparisons) differ; \
            rows re-derived per instant median \(refreshed.sorted()[refreshed.count / 2]), max \(refreshed.max() ?? 0)
              \(detail.joined(separator: "\n  "))
            """)
    }
}
