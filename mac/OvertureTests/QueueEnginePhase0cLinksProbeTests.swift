import Testing
import Foundation
import SwiftData

// #4106 plan v7, Phase 0c probes 0c.1 (T1 ShowLink) and 0c.2 (T2 ContradictedCancellation, T3 feed
// breaks). TEST CODE ONLY: nothing in the app changes.
//
// Two halves, and they run differently on purpose.
//
// 1. PROPERTY tests over committed synthetic fixtures of 60 and 300 rows (invented, containment-rich names,
//    example.org nothing because no row here carries an address; venuetix URLs carry invented tokens).
//    Seeded operation sequences from each term's plan section 7 op mix; after EVERY operation and every
//    undo the prototype's outputs must equal the canonical oracle's (Step T0), and T2's must also equal the
//    row-by-row brute force (`liveTwin`). These run by DEFAULT at small CI settings, because they are the
//    guard each prototype's named mutation must turn red (L1). Deep settings are opt in:
//      TEST_RUNNER_MEASURE_4106_PHASE0C_LINKS_DEEP=1 (20 seeds by 500 operations, both fixtures).
// 2. COST arms over EVERY real key of each kind (plan section 4) on a `LiveStoreClone` copy of the live
//    store and the fourfold corpus built from it, opt in for the two reasons Phase 0 gave (it clones Dan's
//    store, and a stopwatch on a shared Mac measures the Mac, L224). Without the variable each prints one
//    line saying it did not run (L98):
//      TEST_RUNNER_MEASURE_4106_PHASE0C_LINKS=1 mac/scripts/run-tests-locked.sh \
//        -only-testing:OvertureTests/QueueEnginePhase0cLinksProbeTests
//
// PRIVACY. Counts, durations and 8 hex digit hashes only (L222). A failure names seed, step, operation and
// the hashes of both renderings, never a title or a venue.
//
// Every timing is the Debug build the runner builds, with the load average beside each block (L356) and
// today's code timed five times as the noise floor (L395).

enum Phase0cLinks {
    nonisolated static var enabled: Bool {
        ProcessInfo.processInfo.environment["MEASURE_4106_PHASE0C_LINKS"] != nil
    }

    nonisolated static var deep: Bool {
        ProcessInfo.processInfo.environment["MEASURE_4106_PHASE0C_LINKS_DEEP"] != nil
    }

    nonisolated static func say(_ line: String) { print("phase0c-links " + line) }

    /// The one minute load average, waited on until it is under `below` or ten minutes pass (a bounded wait,
    /// L110). `under` false means the replays that follow ran on a busy Mac and cannot score a PASS.
    nonisolated static func waitForLoad(below: Double, deadline seconds: Double = 600)
        -> (under: Bool, text: String) {
        func one() -> Double {
            var l = [Double](repeating: 0, count: 3)
            getloadavg(&l, 3)
            return l[0]
        }
        let start = Phase0.now()
        var waited = 0.0
        while one() >= below && waited < seconds {
            Thread.sleep(forTimeInterval: 10)
            waited = Phase0.ms(since: start) / 1000
        }
        let load = one()
        let verdict = load < below ? "yes" : "NO"
        return (load < below, String(format: "one minute load %.2f (under %.0f: ", load, below) + verdict
                    + String(format: ", waited %.0f s)", waited))
    }

    /// "yyyy-MM-dd" plus `days`, in plain calendar arithmetic (UTC, so no DST can move a day).
    nonisolated static func addDays(_ day: String, _ days: Int) -> String {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return day }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
        guard let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              let moved = calendar.date(byAdding: .day, value: days, to: date) else { return day }
        let c = calendar.dateComponents([.year, .month, .day], from: moved)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

/// Max, p99 and median over every sample of one operation kind.
struct Phase0cStats {
    private(set) var samples: [Double] = []

    mutating func add(_ ms: Double) { samples.append(ms) }

    mutating func merge(_ other: Phase0cStats) { samples += other.samples }

    var count: Int { samples.count }
    var max: Double { samples.max() ?? 0 }
    var median: Double { samples.isEmpty ? 0 : samples.sorted()[samples.count / 2] }
    var p99: Double {
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted()
        return sorted[Swift.max(0, Int((Double(sorted.count) * 0.99).rounded(.up)) - 1)]
    }

    var text: String {
        count == 0 ? "n 0 (no key of this kind)"
            : String(format: "n %d  max %.3f  p99 %.3f  median %.3f ms", count, max, p99, median)
    }
}

// MARK: - The synthetic fixtures

/// Every field a probe operation can change, so an undo restores exactly what the operation overwrote.
struct Phase0cSnapshot {
    var naturalKey: String
    var groupName: String
    var venue: String?
    var performanceDate: String?
    var runEndDate: String?
    var runNights: [String]
    var droppedRunNights: [String]
    var sourceListingURL: String?
    var runSourceURLs: [String]
    var missedScoutCount: Int
    var statusRaw: String
    var scoutGroupName: String?
    var scoutVenue: String?

    init(naturalKey: String, groupName: String, venue: String?, performanceDate: String?,
         runEndDate: String? = nil, runNights: [String] = [], droppedRunNights: [String] = [],
         sourceListingURL: String? = nil, runSourceURLs: [String] = [], missedScoutCount: Int = 0,
         statusRaw: String = ReviewStatus.approved.rawValue, scoutGroupName: String? = nil,
         scoutVenue: String? = nil) {
        self.naturalKey = naturalKey
        self.groupName = groupName
        self.venue = venue
        self.performanceDate = performanceDate
        self.runEndDate = runEndDate
        self.runNights = runNights
        self.droppedRunNights = droppedRunNights
        self.sourceListingURL = sourceListingURL
        self.runSourceURLs = runSourceURLs
        self.missedScoutCount = missedScoutCount
        self.statusRaw = statusRaw
        self.scoutGroupName = scoutGroupName
        self.scoutVenue = scoutVenue
    }

    init(_ p: Prospect) {
        self.init(naturalKey: p.naturalKey, groupName: p.groupName, venue: p.venue,
                  performanceDate: p.performanceDate, runEndDate: p.runEndDate, runNights: p.runNights,
                  droppedRunNights: p.droppedRunNights, sourceListingURL: p.sourceListingURL,
                  runSourceURLs: p.runSourceURLs, missedScoutCount: p.missedScoutCount,
                  statusRaw: p.statusRaw, scoutGroupName: p.scoutGroupName, scoutVenue: p.scoutVenue)
    }

    func apply(to p: Prospect) {
        if p.naturalKey != naturalKey { p.naturalKey = naturalKey }
        p.groupName = groupName
        p.venue = venue
        p.performanceDate = performanceDate
        p.runEndDate = runEndDate
        p.runNights = runNights
        p.droppedRunNights = droppedRunNights
        p.sourceListingURL = sourceListingURL
        p.runSourceURLs = runSourceURLs
        p.missedScoutCount = missedScoutCount
        p.statusRaw = statusRaw
        p.scoutGroupName = scoutGroupName
        p.scoutVenue = scoutVenue
    }

    func makeProspect() -> Prospect {
        let p = Prospect(naturalKey: naturalKey, groupName: groupName, discipline: "choral", venue: venue,
                         performanceDate: performanceDate, sourceListingURL: sourceListingURL,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .approved, ingestedAt: Date(timeIntervalSince1970: 1_800_000_000))
        apply(to: p)
        return p
    }
}

/// The committed synthetic fixtures: generated from a seed and these invented lists, so every run of a
/// given size and seed builds the same rows (L339). Containment rich on purpose: titles contain one
/// another, rooms are respelled in ways the fold does and does not merge, and venuetix tokens are shared
/// across titles so the poison rule has something to discard.
enum Phase0cFixture {
    static let titles = ["Lantern", "Lantern Revue", "Glass Lantern", "Glass Lantern Revue", "Harbor Lights",
                         "Harbor Lights Encore", "Harbor Lights: Encore", "Cedar Strings", "Cedar Strings Trio",
                         "Willow Song Cycle", "Willow Song Cycle: Part Two", "Quarry Nocturnes",
                         "The Quarry Nocturnes", "Marble Choir", "Marble Choir Festival"]
    static let venues: [String?] = ["Harbor Hall", "HARBOR HALL", "Harbor Hall Annex", "Quarry Hall",
                                    "The Quarry Hall", "Willow Barn", "Cedar Room", nil, "", "  "]
    static let tokens = (1...9).map { "tkqz\($0)w" }
    static let firstDay = "2027-02-01"
    static let asOf = "2027-03-01"

    static func url(_ token: String) -> String { "https://www.venuetix.com/showdetails/\(token)/seats" }

    static func snapshots(size: Int, seed: UInt64) -> [Phase0cSnapshot] {
        var rng = SeededGenerator(seed: seed)
        func roll(_ n: Int) -> Int { Int(rng.next() % UInt64(n)) }
        let chain = size >= 300 ? 15 : 5
        var out: [Phase0cSnapshot] = []
        // The chain bucket: one folded title and room, each row's nights overlapping the next, so the
        // whole bucket is one cluster only through its middle rows (the Infinite Wrench shape, 15 at 300).
        for j in 0..<chain {
            let day = Phase0cLinks.addDays(firstDay, 40 + j)
            out.append(Phase0cSnapshot(naturalKey: "fx-\(seed)-chain-\(j)", groupName: "Infinite Lantern Hour",
                                       venue: j % 2 == 0 ? "Harbor Hall" : "HARBOR HALL", performanceDate: day,
                                       runNights: [day, Phase0cLinks.addDays(day, 1)],
                                       missedScoutCount: j == 0 ? 1 : 0))
        }
        // A feed break: four flagged future rows at one room on one count, one of them with a live twin.
        for j in 0..<4 {
            out.append(Phase0cSnapshot(naturalKey: "fx-\(seed)-break-\(j)", groupName: "Willow Night \(j)",
                                       venue: j == 1 ? "WILLOW BARN" : "Willow Barn",
                                       performanceDate: Phase0cLinks.addDays(firstDay, 60 + j),
                                       missedScoutCount: 3))
        }
        out.append(Phase0cSnapshot(naturalKey: "fx-\(seed)-twin-0", groupName: "Willow Night 0",
                                   venue: "Willow Barn", performanceDate: Phase0cLinks.addDays(firstDay, 60)))
        var i = 0
        while out.count < size {
            let title = titles[roll(titles.count)]
            let venue = venues[roll(venues.count)]
            var s = Phase0cSnapshot(naturalKey: "fx-\(seed)-\(i)", groupName: title, venue: venue,
                                    performanceDate: nil)
            i += 1
            if roll(10) != 0 {
                let day = Phase0cLinks.addDays(firstDay, roll(120))
                s.performanceDate = day
                if roll(4) == 0 {
                    s.runEndDate = Phase0cLinks.addDays(day, 1 + roll(10))
                } else if roll(5) == 0 {
                    s.runNights = (0..<(2 + roll(3))).map { Phase0cLinks.addDays(day, 2 * $0) }
                    if roll(3) == 0, let last = s.runNights.popLast() {
                        s.droppedRunNights = [DroppedNight(night: last, reason: .duplicate,
                                                           at: Date(timeIntervalSince1970: 1_800_000_000)).stored]
                    }
                }
            }
            if roll(10) < 3 {
                let own = tokens[(titles.firstIndex(of: title) ?? 0) % tokens.count]
                let token = roll(5) == 0 ? tokens[roll(tokens.count)] : own
                if roll(2) == 0 { s.sourceListingURL = url(token) } else { s.runSourceURLs = [url(token)] }
            }
            let miss = roll(20)
            s.missedScoutCount = miss < 11 ? 0 : (miss < 13 ? 1 : 2 + roll(3))
            if roll(7) == 0 { s.statusRaw = ReviewStatus.dismissed.rawValue }
            if roll(10) == 0 { s.scoutGroupName = titles[roll(titles.count)] }
            if roll(20) == 0 { s.scoutVenue = venues[roll(venues.count)] ?? "Cedar Room" }
            out.append(s)
        }
        return out
    }
}

enum Phase0cOp: String, CaseIterable {
    // T1's op mix (plan section 7).
    case scoutRenameInto = "scout rename into a bucket"
    case scoutRenameOut = "scout rename out of a bucket"
    case venueRespellSame = "venue respelled, same fold"
    case venueRespellOther = "venue respelled, other fold"
    case bridgeNight = "night bridging A and C through B, then removed"
    case dropNight = "night dropped"
    case poisonToken = "token shared across two titles at one venue, then removed"
    case feedMiss = "missedScoutCount 0 to 1 and back"
    case dismissFront = "front dismissed or undismissed"
    case deleteFront = "front deleted"
    case merge = "merge"
    case insertNoDate = "insert with no date"
    case rekey = "re-key"
    // T2's and T3's.
    case flagAcross = "flag or unflag across goneThreshold"
    case roomRespell = "room respelled"
    case dateMove = "date moved in or out of overlap"
    case titleChange = "title change across isSameShowTitle"
    case deleteTwin = "live twin deleted"
    case venueless = "row made venueless"
    case thirdMemberJoin = "third member joining, then leaving"
    case accrualAll = "scout accrual, every flagged row up one"
    case accrualDown = "scout accrual reversed, every row above goneThreshold down one (stays flagged)"
    case twinAppear = "twin appearing"
    case flaggedEdit = "contradicted row counted up one with its room, title or dates changed (stays flagged)"
    case rollover = "clock rollover"

    static let t1: [Phase0cOp] = [.scoutRenameInto, .scoutRenameOut, .venueRespellSame, .venueRespellOther,
                                  .bridgeNight, .dropNight, .poisonToken, .feedMiss, .dismissFront,
                                  .deleteFront, .merge, .insertNoDate, .rekey]
    static let t2t3: [Phase0cOp] = [.flagAcross, .roomRespell, .dateMove, .titleChange, .deleteTwin, .venueless,
                                    .thirdMemberJoin, .accrualAll, .accrualDown, .flaggedEdit, .twinAppear, .rollover, .rekey,
                                    .merge]

    /// Operations whose plan wording includes their own reversal ("then removed", "and back", "leaving").
    var alwaysUndone: Bool { [.bridgeNight, .poisonToken, .thirdMemberJoin].contains(self) }
}

struct Phase0cEdit {
    var modified: [(model: Prospect, before: Phase0cSnapshot)] = []
    var inserted: [Prospect] = []
    var deleted: [(pid: PersistentIdentifier, snapshot: Phase0cSnapshot)] = []
    var asOfBefore: String?
}

/// One synthetic store: an in-memory container, the rows, the clock, and the seeded generator.
@MainActor
final class Phase0cWorld {
    let container: ModelContainer
    let context: ModelContext
    var asOf = Phase0cFixture.asOf
    private var rng: SeededGenerator
    private var serial = 0

    init(size: Int, seed: UInt64) throws {
        container = try TestModelContainer.inMemory([Prospect.self, Recipient.self])
        context = container.mainContext
        rng = SeededGenerator(seed: seed &* 2_654_435_761 &+ 4106)
        for s in Phase0cFixture.snapshots(size: size, seed: seed) { context.insert(s.makeProspect()) }
        try context.save()
    }

    func rows() throws -> [Prospect] { try context.fetch(FetchDescriptor<Prospect>()) }

    func roll(_ n: Int) -> Int { n <= 1 ? 0 : Int(rng.next() % UInt64(n)) }

    func pick(_ rows: [Prospect], _ ok: (Prospect) -> Bool = { _ in true }) -> Prospect? {
        let found = rows.filter(ok)
        return found.isEmpty ? nil : found[roll(found.count)]
    }

    private func next() -> Int { serial += 1; return serial }

    private func modify(_ p: Prospect, _ edit: inout Phase0cEdit, _ change: (Prospect) -> Void) {
        if !edit.modified.contains(where: { $0.model.persistentModelID == p.persistentModelID }) {
            edit.modified.append((p, Phase0cSnapshot(p)))
        }
        change(p)
    }

    private func insert(_ s: Phase0cSnapshot, _ edit: inout Phase0cEdit) {
        let p = s.makeProspect()
        context.insert(p)
        edit.inserted.append(p)
    }

    private func delete(_ p: Prospect, _ edit: inout Phase0cEdit) {
        edit.deleted.append((p.persistentModelID, Phase0cSnapshot(p)))
        context.delete(p)
    }

    private static func showFold(_ p: Prospect) -> String {
        ShowLink.foldedTitle(p.scoutGroupName ?? p.groupName) + "|" + ShowLink.foldedVenue(p.scoutVenue ?? p.venue)
    }

    private static func lastNight(_ p: Prospect) -> String { max(p.performanceDate ?? "", p.runEndDate ?? "") }

    private static func same(_ a: Prospect, _ b: Prospect) -> Bool { a.persistentModelID == b.persistentModelID }

    /// Half the time, a CONTRADICTED row (by the oracle), else nil. A room or date change on a row that stays
    /// flagged is exactly what T2's accrual skip must NOT swallow, and a random pick rarely lands on a flagged
    /// row that has a twin to lose: measured 2026-09-28, the skip with its room or date condition removed
    /// SURVIVED the harness until the moves were aimed here (#4106 0c.2 re-probe).
    private func aimedAtContradicted(_ rows: [Prospect], _ ok: (Prospect) -> Bool = { _ in true }) -> Prospect? {
        guard roll(2) == 0 else { return nil }
        let hot = ContradictedCancellation.contradictedKeys(among: rows)
        return pick(rows, { hot.contains($0.naturalKey) && ok($0) })
    }

    /// Performs one operation, unsaved. Nil when the store holds nothing the operation can act on.
    func perform(_ op: Phase0cOp, rows: [Prospect], fronts: Set<String>) -> Phase0cEdit? {
        var edit = Phase0cEdit()
        switch op {
        case .scoutRenameInto:
            guard let r = pick(rows) else { return nil }
            let room = ShowLink.foldedVenue(r.scoutVenue ?? r.venue)
            guard let donor = pick(rows, { !Self.same($0, r) && ShowLink.foldedVenue($0.scoutVenue ?? $0.venue) == room
                                           && Self.showFold($0) != Self.showFold(r) }) ?? pick(rows, { !Self.same($0, r) })
            else { return nil }
            modify(r, &edit) {
                $0.scoutGroupName = donor.scoutGroupName ?? donor.groupName
                $0.scoutVenue = donor.scoutVenue ?? donor.venue
            }
        case .scoutRenameOut:
            guard let r = pick(rows) else { return nil }
            let title = "Invented Solo Bill \(next())"
            modify(r, &edit) { $0.scoutGroupName = title }
        case .venueRespellSame:
            guard let r = pick(rows, { !(($0.scoutVenue ?? $0.venue) ?? "").trimmingCharacters(in: .whitespaces).isEmpty })
            else { return nil }
            let current = (r.scoutVenue ?? r.venue) ?? ""
            let respelled = current == current.uppercased() ? current.lowercased() : current.uppercased()
            modify(r, &edit) { if $0.scoutVenue != nil { $0.scoutVenue = respelled } else { $0.venue = respelled } }
        case .venueRespellOther:
            guard let r = pick(rows) else { return nil }
            let other = Phase0cFixture.venues[roll(Phase0cFixture.venues.count)]
            modify(r, &edit) { if $0.scoutVenue != nil { $0.scoutVenue = other ?? "Cedar Room" } else { $0.venue = other } }
        case .bridgeNight:
            guard let a = pick(rows, { $0.performanceDate != nil }),
                  let c = pick(rows, { !Self.same($0, a) && $0.performanceDate != nil
                                      && Self.showFold($0) == Self.showFold(a) && $0.performanceDate != a.performanceDate }),
                  let b = pick(rows, { !Self.same($0, a) && !Self.same($0, c) && Self.showFold($0) == Self.showFold(a) })
                    ?? pick(rows, { !Self.same($0, a) && !Self.same($0, c) }),
                  let nightA = a.performanceDate, let nightC = c.performanceDate else { return nil }
            modify(b, &edit) {
                $0.scoutGroupName = a.scoutGroupName ?? a.groupName
                $0.scoutVenue = a.scoutVenue ?? a.venue
                $0.runNights = [nightA, nightC].sorted()
            }
        case .dropNight:
            guard let r = pick(rows, { $0.runNights.count >= 2 }) else { return nil }
            modify(r, &edit) {
                guard let night = $0.runNights.popLast() else { return }
                $0.droppedRunNights.append(DroppedNight(night: night, reason: .duplicate,
                                                        at: Date(timeIntervalSince1970: 1_800_000_000)).stored)
            }
        case .poisonToken:
            guard let r = pick(rows, { !ShowLink.Row($0).sourceURLs.compactMap(ProductionToken.inURL).isEmpty }),
                  let token = ShowLink.Row(r).sourceURLs.compactMap(ProductionToken.inURL).first else { return nil }
            insert(Phase0cSnapshot(naturalKey: "ins-\(next())", groupName: "Invented Poison Bill \(serial)",
                                   venue: r.scoutVenue ?? r.venue, performanceDate: r.performanceDate,
                                   sourceListingURL: Phase0cFixture.url(token)), &edit)
        case .feedMiss:
            guard let r = pick(rows) else { return nil }
            modify(r, &edit) { $0.missedScoutCount = $0.missedScoutCount == 0 ? 1 : 0 }
        case .dismissFront:
            guard let r = pick(rows, { fronts.contains($0.naturalKey) || $0.statusRaw == ReviewStatus.dismissed.rawValue })
            else { return nil }
            modify(r, &edit) {
                $0.statusRaw = $0.statusRaw == ReviewStatus.dismissed.rawValue
                    ? ReviewStatus.approved.rawValue : ReviewStatus.dismissed.rawValue
            }
        case .deleteFront:
            guard let r = pick(rows, { fronts.contains($0.naturalKey) }) ?? pick(rows) else { return nil }
            delete(r, &edit)
        case .merge:
            guard let a = pick(rows),
                  let b = pick(rows, { !Self.same($0, a) && Self.showFold($0) == Self.showFold(a) })
                    ?? pick(rows, { !Self.same($0, a) }) else { return nil }
            let nights = Set(a.runNights + b.runNights + [a.performanceDate, b.performanceDate].compactMap { $0 })
            modify(a, &edit) { $0.runNights = nights.sorted() }
            delete(b, &edit)
        case .insertNoDate:
            let title = Phase0cFixture.titles[roll(Phase0cFixture.titles.count)]
            let venue = Phase0cFixture.venues[roll(Phase0cFixture.venues.count)]
            insert(Phase0cSnapshot(naturalKey: "ins-\(next())", groupName: title, venue: venue, performanceDate: nil,
                                   missedScoutCount: roll(2) == 0 ? 0 : 2), &edit)
        case .rekey:
            guard let r = pick(rows) else { return nil }
            let key = "rk-\(next())"
            modify(r, &edit) { $0.naturalKey = key }
        case .flagAcross:
            // Half the time aimed at a row whose flag the contradiction rule actually reads: a contradicted row
            // or the live twin of a flagged one. A flag crossing the threshold must re-judge its room, and a
            // random row rarely has anything in that room to re-judge (#4106 0c.2 re-probe).
            let aimed: Prospect? = roll(2) == 0 ? {
                let hot = ContradictedCancellation.contradictedKeys(among: rows)
                let twins = Set(rows.filter(\.disappearedFromFeed)
                    .compactMap { ContradictedCancellation.liveTwin(of: $0, among: rows)?.persistentModelID })
                return pick(rows, { hot.contains($0.naturalKey) || twins.contains($0.persistentModelID) })
            }() : nil
            guard let r = aimed ?? pick(rows) else { return nil }
            let target = r.missedScoutCount >= FeedReconcile.goneThreshold ? (roll(2) == 0 ? 1 : 0) : 2
            modify(r, &edit) { $0.missedScoutCount = target }
        case .roomRespell:
            guard let r = aimedAtContradicted(rows) ?? pick(rows) else { return nil }
            let choice = roll(3)
            let other = Phase0cFixture.venues[roll(Phase0cFixture.venues.count)]
            modify(r, &edit) {
                switch choice {
                case 0: $0.venue = $0.venue.map { $0 == $0.uppercased() ? $0.lowercased() : $0.uppercased() }
                case 1: $0.venue = other
                default: $0.venue = $0.venue.map { "The " + $0 }
                }
            }
        case .dateMove:
            guard let r = aimedAtContradicted(rows, { $0.performanceDate != nil })
                    ?? pick(rows, { $0.performanceDate != nil }) else { return nil }
            let shift = roll(21) - 10
            let span = roll(4)
            modify(r, &edit) {
                guard let day = $0.performanceDate else { return }
                $0.performanceDate = Phase0cLinks.addDays(day, shift)
                if span == 0 { $0.runEndDate = nil } else if span == 1 {
                    $0.runEndDate = Phase0cLinks.addDays(day, shift + 5)
                } else { $0.runEndDate = $0.runEndDate.map { Phase0cLinks.addDays($0, shift) } }
            }
        case .titleChange:
            guard let r = pick(rows) else { return nil }
            let donor = pick(rows, { $0.disappearedFromFeed })
            let choice = roll(3)
            let invented = "Invented Other Bill \(next())"
            modify(r, &edit) {
                switch choice {
                case 0: $0.groupName = $0.groupName + ": Encore Evening"
                case 1: $0.groupName = invented
                default: $0.groupName = donor?.groupName ?? invented
                }
            }
        case .deleteTwin:
            // Up to ten flagged rows tried at random rather than every one asked: `liveTwin` is a whole
            // store walk per row, and asking it of every flagged row each step was most of the runtime.
            let flagged = rows.filter(\.disappearedFromFeed)
            var victim: Prospect?
            for _ in 0..<min(10, flagged.count) where victim == nil {
                victim = ContradictedCancellation.liveTwin(of: flagged[roll(flagged.count)], among: rows)
            }
            guard let victim else { return nil }
            delete(victim, &edit)
        case .venueless:
            guard let r = pick(rows) else { return nil }
            let blank: String? = roll(2) == 0 ? nil : ""
            modify(r, &edit) { $0.venue = blank }
        case .thirdMemberJoin:
            guard let f = pick(rows, { $0.disappearedFromFeed && Self.lastNight($0) >= asOf }),
                  let r = pick(rows, { !Self.same($0, f) && !$0.disappearedFromFeed }) else { return nil }
            let day = Phase0cLinks.addDays(asOf, 5 + roll(20))
            modify(r, &edit) {
                $0.venue = f.venue
                $0.missedScoutCount = f.missedScoutCount
                if Self.lastNight($0) < asOf { $0.performanceDate = day; $0.runEndDate = nil }
            }
        case .accrualAll:
            let flagged = rows.filter(\.disappearedFromFeed)
            guard !flagged.isEmpty else { return nil }
            for f in flagged { modify(f, &edit) { $0.missedScoutCount += 1 } }
        case .accrualDown:
            // Only rows that stay flagged move: a count inside the flagged range changing, which is exactly
            // the change T2's skip (#4106 0c.2 re-probe) re-tests nothing for.
            let above = rows.filter { $0.missedScoutCount > FeedReconcile.goneThreshold }
            guard !above.isEmpty else { return nil }
            for f in above { modify(f, &edit) { $0.missedScoutCount -= 1 } }
        case .flaggedEdit:
            // The exact boundary of T2's accrual skip: a row that stays flagged and ALSO moves one of the four
            // facts the skip must not ignore. One field per edit, cycled by serial rather than rolled, so a
            // skip missing any single condition is met within three edits (#4106 0c.2 re-probe: a random mix
            // let one condition's mutation survive a whole CI run).
            let hot = ContradictedCancellation.contradictedKeys(among: rows)
            guard let r = pick(rows, { hot.contains($0.naturalKey) }) ?? pick(rows, { $0.disappearedFromFeed })
            else { return nil }
            let field = next() % 3
            let invented = "Invented Moved Bill \(serial)"
            typealias Room = Phase0cContradictionPatch<Phase0cKey>.Facts
            let other = Phase0cFixture.venues.compactMap { $0 }
                .first { Room.room($0) != Room.room(r.venue) } ?? "Invented Far Room"
            modify(r, &edit) {
                $0.missedScoutCount += 1
                switch field {
                case 0: $0.venue = other
                case 1: $0.groupName = invented
                default:
                    $0.performanceDate = $0.performanceDate.map { Phase0cLinks.addDays($0, 30) } ?? "2027-06-01"
                    $0.runEndDate = nil
                }
            }
        case .twinAppear:
            guard let f = pick(rows, { $0.disappearedFromFeed && $0.performanceDate != nil }) else { return nil }
            insert(Phase0cSnapshot(naturalKey: "ins-\(next())", groupName: f.groupName, venue: f.venue,
                                   performanceDate: f.performanceDate, runEndDate: f.runEndDate), &edit)
        case .rollover:
            edit.asOfBefore = asOf
            asOf = Phase0cLinks.addDays(asOf, 1 + roll(14))
        }
        return edit
    }

    /// Saves the edit and returns every key it changed, inserted or deleted.
    func commit(_ edit: Phase0cEdit) throws -> Set<PersistentIdentifier> {
        try context.save()
        var changed = Set(edit.modified.map { $0.model.persistentModelID })
        changed.formUnion(edit.inserted.map(\.persistentModelID))
        changed.formUnion(edit.deleted.map { $0.pid })
        return changed
    }

    /// Reverses an edit: restores what it overwrote, removes what it inserted, and re-inserts (as new rows)
    /// what it deleted.
    func undo(_ edit: Phase0cEdit) throws -> Set<PersistentIdentifier> {
        var changed: Set<PersistentIdentifier> = []
        for (model, before) in edit.modified.reversed() {
            before.apply(to: model)
            changed.insert(model.persistentModelID)
        }
        for model in edit.inserted {
            changed.insert(model.persistentModelID)
            context.delete(model)
        }
        var restored: [Prospect] = []
        for gone in edit.deleted {
            let p = gone.snapshot.makeProspect()
            context.insert(p)
            restored.append(p)
        }
        if let before = edit.asOfBefore { asOf = before }
        try context.save()
        changed.formUnion(restored.map(\.persistentModelID))
        return changed
    }
}

// MARK: - The property harness

enum Phase0cTerm: String { case t1 = "T1", t2 = "T2", t3 = "T3" }

@MainActor
struct Phase0cHarness {
    typealias T1 = Phase0cShowLinkPatch<Phase0cKey>
    typealias T2 = Phase0cContradictionPatch<Phase0cKey>
    typealias T3 = Phase0cFeedBreakPatch<Phase0cKey>

    struct Outcome {
        var checks = 0
        var skipped = 0
        var applied: [Phase0cOp: Int] = [:]
        var failures: [String] = []
        var permutationChecks = 0
        var bruteChecks = 0
        var accrualPasses = 0
    }

    static func t1Facts(_ p: Prospect) -> T1.Facts {
        T1.Facts(ShowLink.Row(p), drawn: p.statusRaw != ReviewStatus.dismissed.rawValue)
    }

    /// One seed: build the world, build each prototype cold, then `ops` operations, checking after each
    /// operation and each undo.
    static func run(terms: Set<Phase0cTerm>, ops kinds: [Phase0cOp], size: Int, seed: UInt64,
                    steps: Int, outcome: inout Outcome) throws {
        let world = try Phase0cWorld(size: size, seed: seed)
        var rows = try world.rows()
        var t1 = T1()
        var t2 = T2()
        var t3 = T3(asOf: world.asOf)
        _ = t1.apply(rows.map { (Phase0cKey.row($0.persistentModelID), t1Facts($0)) })
        _ = t2.apply(rows.map { (Phase0cKey.row($0.persistentModelID), T2.Facts($0)) })
        t3.apply(rows.map { (Phase0cKey.row($0.persistentModelID), T3.Facts($0)) },
                 coveredFlips: Dictionary(uniqueKeysWithValues: t2.contradicted.map { ($0, true) }))

        func feed(_ changed: Set<PersistentIdentifier>) {
            let byPID = Dictionary(rows.map { ($0.persistentModelID, $0) }, uniquingKeysWith: { first, _ in first })
            let keys = changed.map { ($0, Phase0cKey.row($0)) }
            _ = t1.apply(keys.map { ($0.1, byPID[$0.0].map(t1Facts)) })
            let r2 = t2.apply(keys.map { ($0.1, byPID[$0.0].map(T2.Facts.init)) })
            let flips = Dictionary(uniqueKeysWithValues: r2.flips.map { ($0, t2.contradicted.contains($0)) })
            t3.apply(keys.map { ($0.1, byPID[$0.0].map(T3.Facts.init)) }, coveredFlips: flips)
            t3.advance(to: world.asOf)
        }

        // The brute force is a whole store walk per flagged row, so on the 300 row fixture it runs at the
        // sampled steps and the end; on the 60 row fixture, after every operation and undo.
        let sampled = Set((0..<10).map { steps * $0 / 10 })
        var bruteNow = true
        func check(_ step: Int, _ op: String) {
            outcome.checks += 1
            let place = "seed \(seed) size \(size) step \(step) op \(op)"
            if terms.contains(.t1) {
                let showRows = rows.map(ShowLink.Row.init)
                let drawn = Set(rows.filter { $0.statusRaw != ReviewStatus.dismissed.rawValue }.map(\.naturalKey))
                let og = OracleRendering.keyed(CanonicalOracle.showLinkGroup(showRows))
                let pg = OracleRendering.keyed(t1.group)
                if og != pg {
                    outcome.failures.append("\(place): T1 group prototype \(Phase0b.hash8(pg)) oracle \(Phase0b.hash8(og))")
                }
                let oc = OracleRendering.collapse(CanonicalOracle.showLinkCollapse(showRows, drawn: drawn))
                let pc = OracleRendering.collapse((t1.fronts, t1.hidden))
                if oc != pc {
                    outcome.failures.append("\(place): T1 collapse prototype \(Phase0b.hash8(pc)) oracle \(Phase0b.hash8(oc))")
                }
            }
            if terms.contains(.t2) {
                let oracle = ContradictedCancellation.contradictedKeys(among: rows.sorted(by: CanonicalOracle.byNaturalKey))
                let brute = bruteNow
                    ? Set(rows.filter { ContradictedCancellation.liveTwin(of: $0, among: rows) != nil }.map(\.naturalKey))
                    : oracle
                if bruteNow { outcome.bruteChecks += 1 }
                let proto = t2.contradictedIDs
                if proto != oracle || proto != brute {
                    let text = { (s: Set<String>) in Phase0b.hash8(s.sorted().joined(separator: ",")) }
                    outcome.failures.append("\(place): T2 prototype \(text(proto)) (\(proto.count)) oracle \(text(oracle)) (\(oracle.count)) brute \(text(brute)) (\(brute.count))")
                }
            }
            if terms.contains(.t3) {
                let oracle = OracleRendering.feedBreaks(T3.ordered(CanonicalOracle.feedBreakEvents(rows, asOf: world.asOf)))
                let proto = OracleRendering.feedBreaks(t3.output)
                if oracle != proto {
                    outcome.failures.append("\(place): T3 prototype \(Phase0b.hash8(proto)) oracle \(Phase0b.hash8(oracle))")
                }
            }
        }

        // The canonical wrappers must give one answer over reversed and shuffled rows (plan section 4); at
        // ten sampled steps and the end, never after every operation, to bound runtime (L298).
        func permutationCheck(_ step: Int) {
            outcome.permutationChecks += 1
            let orders = [Array(rows.reversed())] + CanonicalOracle.permutations(rows, count: 1, seed: seed &+ UInt64(step))
            let base = rows.map(ShowLink.Row.init)
            let drawn = Set(rows.filter { $0.statusRaw != ReviewStatus.dismissed.rawValue }.map(\.naturalKey))
            let want1 = OracleRendering.collapse(CanonicalOracle.showLinkCollapse(base, drawn: drawn))
                + OracleRendering.keyed(CanonicalOracle.showLinkGroup(base))
            let want3 = OracleRendering.feedBreaks(T3.ordered(CanonicalOracle.feedBreakEvents(rows, asOf: world.asOf)))
            for order in orders {
                let shown = order.map(ShowLink.Row.init)
                let got1 = OracleRendering.collapse(CanonicalOracle.showLinkCollapse(shown, drawn: drawn))
                    + OracleRendering.keyed(CanonicalOracle.showLinkGroup(shown))
                let got3 = OracleRendering.feedBreaks(T3.ordered(CanonicalOracle.feedBreakEvents(order, asOf: world.asOf)))
                if got1 != want1 || got3 != want3 {
                    outcome.failures.append("seed \(seed) size \(size) step \(step): the canonical oracle moved with input order")
                }
            }
        }

        check(-1, "cold build")
        for step in 0..<steps {
            bruteNow = size <= 60 || sampled.contains(step)
            let op = kinds[world.roll(kinds.count)]
            let fronts = Set(t1.fronts.keys)
            guard let edit = world.perform(op, rows: rows, fronts: fronts) else {
                outcome.skipped += 1
                continue
            }
            outcome.applied[op, default: 0] += 1
            let changed = try world.commit(edit)
            rows = try world.rows()
            feed(changed)
            check(step, op.rawValue)
            if op.alwaysUndone || world.roll(2) == 0 {
                let undone = try world.undo(edit)
                rows = try world.rows()
                feed(undone)
                check(step, op.rawValue + " (undo)")
            }
            // #4106 0c.2 re-probe: an accrual after EVERY operation (up one, or down one where the row stays
            // flagged), checked and undone, so T2's skip for a count change inside the flagged range is
            // judged in every state the op mix reaches rather than only where the mix happens to draw it.
            if terms.contains(.t2) {
                let accrual: Phase0cOp = world.roll(2) == 0 ? .accrualAll : .accrualDown
                if let pass = world.perform(accrual, rows: rows, fronts: Set(t1.fronts.keys)) {
                    outcome.accrualPasses += 1
                    let changed = try world.commit(pass)
                    rows = try world.rows()
                    feed(changed)
                    check(step, op.rawValue + " then " + accrual.rawValue)
                    let undone = try world.undo(pass)
                    rows = try world.rows()
                    feed(undone)
                    check(step, op.rawValue + " then " + accrual.rawValue + " (undo)")
                }
            }
            if sampled.contains(step) { permutationCheck(step) }
        }
        bruteNow = true
        check(steps, "end")
        permutationCheck(steps)
    }

    /// Every seed at the given settings, both fixture sizes; CI settings unless the deep variable is set.
    static func runAll(terms: Set<Phase0cTerm>, ops: [Phase0cOp]) throws -> (outcome: Outcome, settings: String, ms: Double) {
        let deep = Phase0cLinks.deep
        let plan: [(size: Int, seeds: Int, steps: Int)] = deep
            ? [(60, 20, 500), (300, 20, 500)]
            : (terms.contains(.t2) ? [(60, 3, 20), (300, 1, 8)] : [(60, 3, 40), (300, 1, 20)])
        var outcome = Outcome()
        let start = Phase0.now()
        for leg in plan {
            for s in 0..<leg.seeds {
                try run(terms: terms, ops: ops, size: leg.size, seed: 4106_0600 + UInt64(leg.size * 100 + s),
                        steps: leg.steps, outcome: &outcome)
            }
        }
        let settings = plan.map { "\($0.size) rows x \($0.seeds) seeds x \($0.steps) ops" }.joined(separator: ", ")
        return (outcome, (deep ? "DEEP " : "CI ") + settings, Phase0.ms(since: start))
    }

    static func report(_ name: String, _ result: (outcome: Outcome, settings: String, ms: Double)) {
        let o = result.outcome
        let applied = o.applied.sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.rawValue) \($0.value)" }.joined(separator: "; ")
        Phase0cLinks.say("""
            \(name) property harness [\(result.settings)] \(String(format: "%.1f", result.ms / 1000)) s wall: \
            \(o.checks) oracle comparisons (\(o.bruteChecks) also against the brute force), \(o.permutationChecks) permutation checks, \(o.skipped) ops skipped \
            (nothing to act on), \(o.accrualPasses) accrual passes after an op, mismatches \(o.failures.count)
              ops applied: \(applied)
            """)
        if !o.failures.isEmpty {
            Phase0cLinks.say("\(name) FAILURES\n  " + o.failures.prefix(30).joined(separator: "\n  "))
        }
    }
}

// MARK: - The suite

@MainActor
@Suite("#4106 Phase 0c probes 0c.1 and 0c.2 (property tests by default, cost arms opt in)")
struct QueueEnginePhase0cLinksProbeTests {

    private let sandboxes = TemporarySandboxes()

    private func skip(_ probe: String) -> Bool {
        guard Phase0cLinks.enabled else {
            print("phase0c-links \(probe): not measured. Set TEST_RUNNER_MEASURE_4106_PHASE0C_LINKS=1 to run it.")
            return true
        }
        return false
    }

    private func corpora(_ name: String) throws -> [(label: String, url: URL)] {
        let dir = try sandboxes.make(named: name)
        guard let base = try LiveStoreClone.makeClone(in: dir) else {
            throw LiveStoreClone.Refusal.backupFailed("no live store on this machine")
        }
        return [("live clone", base), ("4x", try Phase0.scaledCopy(of: base, factor: 4, in: dir))]
    }

    // MARK: property tests (default)

    @Test func showLinkPrototypeEqualsTheCanonicalOracleAfterEveryOperation() throws {
        let result = try Phase0cHarness.runAll(terms: [.t1], ops: Phase0cOp.t1)
        Phase0cHarness.report("0c.1 T1", result)
        #expect(result.outcome.failures.isEmpty, "0c.1: the ShowLink prototype disagreed with the canonical oracle")
        #expect(result.outcome.checks > 100, "0c.1: the harness compared too little to mean anything")
    }

    @Test func contradictionAndFeedBreakPrototypesEqualTheirOraclesAfterEveryOperation() throws {
        let result = try Phase0cHarness.runAll(terms: [.t2, .t3], ops: Phase0cOp.t2t3)
        Phase0cHarness.report("0c.2 T2+T3", result)
        #expect(result.outcome.failures.isEmpty, "0c.2: a prototype disagreed with its oracle or the brute force")
        #expect(result.outcome.checks > 100, "0c.2: the harness compared too little to mean anything")
    }

    // Positive controls, in the same fixture the harness uses (L159): each fixture must actually hold what
    // the op mix is supposed to exercise, or a green harness proves nothing about it.
    @Test func theFixturesHoldEveryShapeTheOpMixNeeds() throws {
        for size in [60, 300] {
            let world = try Phase0cWorld(size: size, seed: 4106_0600 + UInt64(size * 100))
            let rows = try world.rows()
            var t1 = Phase0cHarness.T1()
            _ = t1.apply(rows.map { (Phase0cKey.row($0.persistentModelID), Phase0cHarness.t1Facts($0)) })
            var t2 = Phase0cHarness.T2()
            _ = t2.apply(rows.map { (Phase0cKey.row($0.persistentModelID), Phase0cHarness.T2.Facts($0)) })
            let largest = t1.bucketKeys.values.map(\.count).max() ?? 0
            let poisoned = t1.allTokens.filter { t1.isPoisoned($0) }.count
            let events = FeedBreakEvent.events(among: rows, asOf: world.asOf)
            #expect(largest >= (size >= 300 ? 15 : 5), "fixture \(size): the chain bucket is missing")
            #expect(!t1.hidden.isEmpty, "fixture \(size): nothing collapses, so the collapse is never exercised")
            #expect(poisoned > 0, "fixture \(size): no token is poisoned, so the discard is never exercised")
            #expect(!t2.contradicted.isEmpty, "fixture \(size): nothing is contradicted")
            // The accrual passes move counts inside the flagged range, and T2 skips those; the skip is only
            // exercised where a CONTRADICTED row sits above the threshold, so it can move down and stay flagged.
            #expect(t2.contradicted.contains { (t2.facts[$0]?.missed ?? 0) > FeedReconcile.goneThreshold },
                    "fixture \(size): no contradicted row sits above goneThreshold, so the accrual skip is never judged")
            #expect(t2.rooms.contains(""), "fixture \(size): no venueless room")
            #expect(!events.isEmpty, "fixture \(size): no feed break event")
        }
    }

    // MARK: 0c.1 cost arm (opt in)

    @Test(.enabled(if: Phase0.liveStoreExists, "no live store on this machine"))
    func probe0c1ShowLinkCost() throws {
        if skip("0c.1") { return }
        let property = try Phase0cHarness.runAll(terms: [.t1], ops: Phase0cOp.t1)
        Phase0cHarness.report("0c.1 T1", property)
        var failures = property.outcome.failures
        var maxAt4x = 0.0
        for (label, url) in try corpora("phase0c-1") {
            let all = try showLinkCost(label: label, url: url, failures: &failures)
            if label == "4x" { maxAt4x = all.max }
        }
        let verdict = failures.isEmpty && maxAt4x <= 10 ? "PASS" : "FAIL"
        Phase0cLinks.say("0c.1 VERDICT \(verdict): mismatches \(failures.count), max per change at 4x \(String(format: "%.3f", maxAt4x)) ms (stop rule: any mismatch, or max over 10 ms at 5,376)")
        if !failures.isEmpty { Phase0cLinks.say("0c.1 FAILURES\n  " + failures.prefix(30).joined(separator: "\n  ")) }
        #expect(failures.isEmpty, "0c.1: the ShowLink prototype disagreed with the canonical oracle")
    }

    private func showLinkCost(label: String, url: URL, failures: inout [String]) throws -> Phase0cStats {
        typealias Patch = Phase0cShowLinkPatch<Phase0cKey>
        let ctx = ModelContext(try Phase0.openContainer(at: url))
        let models = try ctx.fetch(FetchDescriptor<Prospect>())
        var rows: [Phase0cKey: ShowLink.Row] = [:]
        var drawn: [Phase0cKey: Bool] = [:]
        for p in models {
            rows[.row(p.persistentModelID)] = ShowLink.Row(p)
            drawn[.row(p.persistentModelID)] = p.statusRaw != ReviewStatus.dismissed.rawValue
        }
        func facts(_ key: Phase0cKey) -> Patch.Facts? { rows[key].map { Patch.Facts($0, drawn: drawn[key] ?? true) } }
        let load = Phase0.load()
        let everyRow = Array(rows.values)
        let drawnIDs = Set(rows.filter { drawn[$0.key] ?? true }.map { $0.value.id })
        let today = Phase0.median5 {
            _ = CanonicalOracle.showLinkGroup(everyRow)
            _ = CanonicalOracle.showLinkCollapse(everyRow, drawn: drawnIDs)
        }
        var extracted: [(key: Phase0cKey, facts: Patch.Facts?)] = []
        let extraction = Phase0.median5 { extracted = rows.keys.map { ($0, facts($0)) } }
        var patch = Patch()
        let cold = Phase0.median5 {
            patch = Patch()
            _ = patch.apply(extracted)
        }
        var mismatches = 0
        var checks = 0
        func verify(_ what: String) {
            checks += 1
            let current = Array(rows.values)
            let ids = Set(rows.filter { drawn[$0.key] ?? true }.map { $0.value.id })
            let og = OracleRendering.keyed(CanonicalOracle.showLinkGroup(current))
            let oc = OracleRendering.collapse(CanonicalOracle.showLinkCollapse(current, drawn: ids))
            let pg = OracleRendering.keyed(patch.group)
            let pc = OracleRendering.collapse((patch.fronts, patch.hidden))
            if og != pg || oc != pc {
                mismatches += 1
                failures.append("\(label) \(what): group prototype \(Phase0b.hash8(pg)) oracle \(Phase0b.hash8(og)), collapse prototype \(Phase0b.hash8(pc)) oracle \(Phase0b.hash8(oc))")
            }
        }
        verify("cold build")

        var lines: [String] = []
        var all = Phase0cStats()
        func timed(_ changes: [(key: Phase0cKey, facts: Patch.Facts?)], into stats: inout Phase0cStats,
                   rebuilt: inout Int) -> Patch.Result {
            var result = Patch.Result()
            let ms = Phase0.time { result = patch.apply(changes) }
            stats.add(ms)
            rebuilt = max(rebuilt, result.rowsReevaluated)
            return result
        }
        func stride(_ n: Int) -> Int { max(1, n / 6) }

        let buckets = patch.bucketKeys
        let bucketList = buckets.keys.sorted()
        let sizes = buckets.values.map(\.count).sorted(by: >)
        let multi = Set(patch.group.keys).count
        let tokens = patch.allTokens.sorted()
        let alreadyPoisoned = tokens.filter { patch.isPoisoned($0) }.count
        let idToKey = Dictionary(rows.map { ($0.value.id, $0.key) }, uniquingKeysWith: { first, _ in first })

        // A: every bucket, rebuilt once (a touch of its first member).
        var touch = Phase0cStats(), touchRows = 0
        for (i, bucket) in bucketList.enumerated() {
            guard let key = buckets[bucket]?.min(by: { (rows[$0]?.id ?? "") < (rows[$1]?.id ?? "") }) else { continue }
            _ = timed([(key, facts(key))], into: &touch, rebuilt: &touchRows)
            if i % stride(bucketList.count) == 0 { verify("bucket touch \(i)") }
        }
        lines.append("every bucket rebuilt (\(bucketList.count) buckets)          \(touch.text), most rows re-evaluated \(touchRows)")
        all.merge(touch)

        // B: every poisonable token: plant a row under another title at a holder's venue, then remove it.
        var poisonOn = Phase0cStats(), poisonOff = Phase0cStats(), poisonRows = 0, flips = 0
        for (i, token) in tokens.enumerated() {
            guard let holder = patch.holdersOf(token).min(by: { (rows[$0]?.id ?? "") < (rows[$1]?.id ?? "") }),
                  let base = rows[holder] else { continue }
            let key = Phase0cKey.probe(i)
            rows[key] = ShowLink.Row(id: "phase0c-poison-\(i)", groupName: "Phase Zero C Invented Poison Bill \(i)",
                                     venue: base.venue, performanceDate: base.performanceDate,
                                     sourceURLs: [Phase0cFixture.url(token)])
            drawn[key] = true
            let was = patch.isPoisoned(token)
            _ = timed([(key, facts(key))], into: &poisonOn, rebuilt: &poisonRows)
            if !was && patch.isPoisoned(token) { flips += 1 }
            if i % stride(tokens.count) == 0 { verify("poison on \(i)") }
            rows[key] = nil
            drawn[key] = nil
            _ = timed([(key, nil)], into: &poisonOff, rebuilt: &poisonRows)
        }
        verify("after every poison flip")
        lines.append("poison a token (\(tokens.count) tokens, \(flips) flipped)      \(poisonOn.text), most rows re-evaluated \(poisonRows)")
        lines.append("unpoison it                                  \(poisonOff.text)")
        all.merge(poisonOn)
        all.merge(poisonOff)

        // C: every row of the five largest buckets moved out, and back.
        var moveOut = Phase0cStats(), moveBack = Phase0cStats(), moveRows = 0
        let largest = buckets.sorted { $0.value.count > $1.value.count }.prefix(5)
        var moved = 0
        for (_, keys) in largest {
            for key in keys.sorted(by: { (rows[$0]?.id ?? "") < (rows[$1]?.id ?? "") }) {
                guard let original = rows[key] else { continue }
                var out = original
                out.groupName = "Phase Zero C Moved Bill \(moved)"
                rows[key] = out
                _ = timed([(key, facts(key))], into: &moveOut, rebuilt: &moveRows)
                if moved % 7 == 0 { verify("move out \(moved)") }
                rows[key] = original
                _ = timed([(key, facts(key))], into: &moveBack, rebuilt: &moveRows)
                moved += 1
            }
        }
        verify("after the largest buckets moved and back")
        lines.append("move out of the 5 largest buckets (\(moved) rows)   \(moveOut.text), most rows re-evaluated \(moveRows)")
        lines.append("move back                                    \(moveBack.text)")
        all.merge(moveOut)
        all.merge(moveBack)

        // D: every front dismissed (drawn off) and restored.
        var dismiss = Phase0cStats(), undismiss = Phase0cStats(), frontRows = 0, hiddenFlips = 0
        let frontIDs = patch.fronts.keys.sorted()
        for (i, id) in frontIDs.enumerated() {
            guard let key = idToKey[id] else { continue }
            drawn[key] = false
            hiddenFlips = max(hiddenFlips, timed([(key, facts(key))], into: &dismiss, rebuilt: &frontRows).hiddenFlips.count)
            if i % stride(frontIDs.count) == 0 { verify("front dismissed \(i)") }
            drawn[key] = true
            _ = timed([(key, facts(key))], into: &undismiss, rebuilt: &frontRows)
        }
        verify("after every front dismissed and back")
        lines.append("front dismissed (\(frontIDs.count) fronts)                 \(dismiss.text), most hidden flips \(hiddenFlips)")
        lines.append("front undismissed                            \(undismiss.text)")
        all.merge(dismiss)
        all.merge(undismiss)

        // E: every member of a multi-row cluster leaves the feed (0 to 1) and returns.
        var miss = Phase0cStats(), missRows = 0
        let members = patch.group.keys.sorted()
        for (i, id) in members.enumerated() {
            guard let key = idToKey[id], let original = rows[key] else { continue }
            var out = original
            out.isStillInFeed.toggle()
            rows[key] = out
            _ = timed([(key, facts(key))], into: &miss, rebuilt: &missRows)
            if i % stride(members.count) == 0 { verify("feed miss \(i)") }
            rows[key] = original
            _ = timed([(key, facts(key))], into: &miss, rebuilt: &missRows)
        }
        verify("after every clustered member's feed flip")
        lines.append("feed miss flip and back (\(members.count) members)       \(miss.text)")
        all.merge(miss)

        Phase0cLinks.say("""
            0c.1 [\(label)] \(rows.count) rows, \(bucketList.count) buckets (largest \(sizes.prefix(5).map(String.init).joined(separator: ", "))), \
            \(multi) rows in multi-row clusters, \(tokens.count) distinct tokens (\(alreadyPoisoned) already poisoned), \(load)
              today's ShowLink.group plus collapse, canonical (noise floor)  \(today.text)
              prototype extraction of every row                          \(extraction.text)
              prototype cold build                                       \(cold.text)
              \(lines.joined(separator: "\n  "))
              ALL operations                                              \(all.text)
              oracle comparisons \(checks), mismatches \(mismatches)
            """)
        return all
    }

    // MARK: 0c.2 cost arm (opt in)

    @Test(.enabled(if: Phase0.liveStoreExists, "no live store on this machine"))
    func probe0c2ContradictionAndFeedBreakCost() throws {
        if skip("0c.2") { return }
        let property = try Phase0cHarness.runAll(terms: [.t2, .t3], ops: Phase0cOp.t2t3)
        Phase0cHarness.report("0c.2 T2+T3", property)
        var failures = property.outcome.failures
        var single = 0.0, replayed = 0.0, settled = true
        // One pinned instant for the whole probe (L130): today's Eastern day at the moment it started.
        let asOf = EasternDate.today(Date())
        for (label, url) in try corpora("phase0c-2") {
            let cost = try contradictionCost(label: label, url: url, asOf: asOf, failures: &failures)
            single = max(single, cost.all.max)
            replayed = max(replayed, cost.replayed)
            settled = settled && cost.settled
        }
        // Scored under Gate 0c's replay rule (#4106 comment 5860086027): the max is the median of five
        // replays of each kind's slowest key with load under 8. A single sample is printed and decides
        // nothing; a replay taken with load at or over 8 cannot score a PASS, only a FAIL.
        let verdict = !failures.isEmpty || replayed > 5 ? "FAIL" : (settled ? "PASS" : "UNMEASURED")
        Phase0cLinks.say("0c.2 VERDICT \(verdict): mismatches \(failures.count), replayed max over both sizes \(String(format: "%.3f", replayed)) ms, single sample max \(String(format: "%.3f", single)) ms (stop rule: mismatch, or max over 5 ms)")
        if !failures.isEmpty { Phase0cLinks.say("0c.2 FAILURES\n  " + failures.prefix(30).joined(separator: "\n  ")) }
        #expect(failures.isEmpty, "0c.2: a prototype disagreed with its oracle or the brute force")
    }

    private func contradictionCost(label: String, url: URL, asOf startAsOf: String,
                                   failures: inout [String]) throws -> (all: Phase0cStats, replayed: Double, settled: Bool) {
        typealias T2 = Phase0cContradictionPatch<Phase0cKey>
        typealias T3 = Phase0cFeedBreakPatch<Phase0cKey>
        let ctx = ModelContext(try Phase0.openContainer(at: url))
        let models = try ctx.fetch(FetchDescriptor<Prospect>())
        var byKey: [Phase0cKey: Prospect] = [:]
        for p in models { byKey[.row(p.persistentModelID)] = p }
        var asOf = startAsOf
        let load = Phase0.load()
        let todayT2 = Phase0.median5 { _ = ContradictedCancellation.contradictedKeys(among: models) }
        let todayT3 = Phase0.median5 { _ = FeedBreakEvent.events(among: models, asOf: asOf) }
        var t2 = T2()
        var t3 = T3(asOf: asOf)
        let cold = Phase0.median5 {
            t2 = T2()
            t3 = T3(asOf: asOf)
            _ = t2.apply(byKey.map { ($0.key, T2.Facts($0.value)) })
            t3.apply(byKey.map { ($0.key, T3.Facts($0.value)) },
                     coveredFlips: Dictionary(uniqueKeysWithValues: t2.contradicted.map { ($0, true) }))
        }
        var mismatches = 0
        var checks = 0
        func verify(_ what: String, brute: Bool = false) {
            checks += 1
            let current = Array(byKey.values)
            let oracle = ContradictedCancellation.contradictedKeys(among: current)
            let proto = t2.contradictedIDs
            let text = { (s: Set<String>) in Phase0b.hash8(s.sorted().joined(separator: ",")) }
            if proto != oracle {
                mismatches += 1
                failures.append("\(label) \(what): T2 prototype \(text(proto)) (\(proto.count)) oracle \(text(oracle)) (\(oracle.count))")
            }
            if brute {
                let bf = Set(current.filter { ContradictedCancellation.liveTwin(of: $0, among: current) != nil }.map(\.naturalKey))
                if bf != oracle {
                    mismatches += 1
                    failures.append("\(label) \(what): T2 brute force \(text(bf)) (\(bf.count)) disagrees with the oracle \(text(oracle))")
                }
            }
            let o3 = OracleRendering.feedBreaks(T3.ordered(CanonicalOracle.feedBreakEvents(current, asOf: asOf)))
            let p3 = OracleRendering.feedBreaks(t3.output)
            if o3 != p3 {
                mismatches += 1
                failures.append("\(label) \(what): T3 prototype \(Phase0b.hash8(p3)) oracle \(Phase0b.hash8(o3))")
            }
        }
        verify("cold build", brute: true)

        // One change through T2 and on into T3, timed together, the way the engine would run them.
        var testsMax = 0
        var lastSplit: (t2: Double, t3: Double, tests: Int) = (0, 0, 0)
        func splitText() -> String {
            String(format: "(T2 %.3f ms over %d pair tests, T3 %.3f ms)", lastSplit.t2, lastSplit.tests, lastSplit.t3)
        }
        func run(_ keys: [Phase0cKey]) -> Double {
            let c2 = keys.map { ($0, byKey[$0].map(T2.Facts.init)) }
            let c3 = keys.map { ($0, byKey[$0].map(T3.Facts.init)) }
            var tests = 0
            var flips: [Phase0cKey: Bool] = [:]
            let t2ms = Phase0.time {
                let r = t2.apply(c2)
                tests = r.tests
                flips = Dictionary(uniqueKeysWithValues: r.flips.map { ($0, t2.contradicted.contains($0)) })
            }
            let t3ms = Phase0.time { t3.apply(c3, coveredFlips: flips) }
            lastSplit = (t2ms, t3ms, tests)
            testsMax = max(testsMax, tests)
            return t2ms + t3ms
        }

        // Gate 0c's scoring rule (Dan, 2026-09-27, #4106 comment 5860086027): a single sample decides
        // nothing, because on a shared Mac it measures other agents' builds. Each operation kind keeps its
        // SLOWEST key with a closure that replays exactly that change from the unchanged state and puts the
        // state back, and the kind's max is the median of five replays taken with load under 8.
        var slowest: [String: (ms: Double, replay: () -> Double)] = [:]
        var kindOrder: [String] = []
        func record(_ kind: String, _ ms: Double, _ replay: @escaping () -> Double) {
            if slowest[kind] == nil { kindOrder.append(kind) }
            if ms > (slowest[kind]?.ms ?? -1) { slowest[kind] = (ms, replay) }
        }
        func touch(_ kind: String, _ keys: [Phase0cKey], into stats: inout Phase0cStats) -> Double {
            let ms = run(keys)
            stats.add(ms)
            record(kind, ms) { run(keys) }
            return ms
        }
        // A change and its reversal, each timed and each replayable on its own.
        func pair(_ kind: String, _ backKind: String, _ keys: [Phase0cKey],
                  into forward: inout Phase0cStats, _ back: inout Phase0cStats,
                  change: @escaping () -> Void, revert: @escaping () -> Void,
                  between: () -> Void = {}) -> (Double, Double) {
            change()
            let there = run(keys)
            forward.add(there)
            record(kind, there) { change(); let ms = run(keys); revert(); _ = run(keys); return ms }
            between()
            revert()
            let home = run(keys)
            back.add(home)
            record(backKind, home) { change(); _ = run(keys); revert(); return run(keys) }
            return (there, home)
        }
        func stride(_ n: Int) -> Int { max(1, n / 6) }
        func firstByID(_ keys: Set<Phase0cKey>) -> Phase0cKey? {
            keys.min { (byKey[$0]?.naturalKey ?? "") < (byKey[$1]?.naturalKey ?? "") }
        }
        func plant(_ key: Phase0cKey, _ s: Phase0cSnapshot) {
            let p = s.makeProspect()
            ctx.insert(p)
            byKey[key] = p
        }
        func unplant(_ key: Phase0cKey) {
            if let p = byKey[key] { ctx.delete(p) }
            byKey[key] = nil
        }
        var probeSerial = 0
        func nextProbe() -> Phase0cKey { probeSerial += 1; return .probe(probeSerial) }

        let rooms = t2.rooms.sorted()
        let roomSizes = rooms.map { (room: $0, live: t2.live[$0]?.count ?? 0, flagged: t2.flagged[$0]?.count ?? 0) }
        var lines: [String] = []
        var all = Phase0cStats()
        var liveTouch = Phase0cStats(), flagOn = Phase0cStats(), flagOff = Phase0cStats()
        var flaggedTouch = Phase0cStats(), moveOut = Phase0cStats(), moveBack = Phase0cStats()
        var blank = Phase0cStats()
        for (i, room) in rooms.enumerated() {
            var here = Phase0cStats()
            if let l = firstByID(t2.live[room] ?? []), let p = byKey[l] {
                here.add(touch("T2 live row touch", [l], into: &liveTouch))
                let old = p.missedScoutCount
                let flag = pair("T2 flag a live row", "T2 unflag it", [l], into: &flagOn, &flagOff,
                                change: { p.missedScoutCount = FeedReconcile.goneThreshold },
                                revert: { p.missedScoutCount = old },
                                between: { if i % stride(rooms.count) == 0 { verify("room \(i) live row flagged") } })
                here.add(flag.0); here.add(flag.1)
                let venue = p.venue
                let elsewhere: String? = room.isEmpty ? "Phase Zero C Invented Room" : nil
                let move = pair("T2 live row to another room", "T2 and back", [l], into: &moveOut, &moveBack,
                                change: { p.venue = elsewhere }, revert: { p.venue = venue },
                                between: { if i % stride(rooms.count) == 1 { verify("room \(i) live row moved") } })
                here.add(move.0); here.add(move.1)
            }
            if let f = firstByID(t2.flagged[room] ?? []) {
                here.add(touch("T2 flagged row touch", [f], into: &flaggedTouch))
            }
            if room.isEmpty { blank = here }
        }
        verify("after every room")
        lines.append("T2 live row touch (tests every flagged row in its room)   \(liveTouch.text)")
        lines.append("T2 flag a live row (tests every live row in its room)     \(flagOn.text)")
        lines.append("T2 unflag it                                              \(flagOff.text)")
        lines.append("T2 flagged row touch                                      \(flaggedTouch.text)")
        lines.append("T2 live row to another room (old and new room)            \(moveOut.text)")
        lines.append("T2 and back                                               \(moveBack.text)")
        lines.append("T2 the \"\" (venueless) room alone                          \(blank.text)")
        for s in [liveTouch, flagOn, flagOff, flaggedTouch, moveOut, moveBack] { all.merge(s) }

        // T3: every real bucket of flagged future rows gains a member at its count, which then leaves.
        var join = Phase0cStats(), leave = Phase0cStats()
        let futureBuckets = t3.futureBuckets
        let bucketList = futureBuckets.keys.sorted()
        for (i, bucket) in bucketList.enumerated() {
            guard let member = futureBuckets[bucket]?.min(by: { (byKey[$0]?.naturalKey ?? "") < (byKey[$1]?.naturalKey ?? "") }),
                  let m = byKey[member] else { continue }
            let key = nextProbe()
            let joiner = Phase0cSnapshot(naturalKey: "phase0c-joiner-\(i)", groupName: "Phase Zero C Joiner \(i)",
                                         venue: m.venue, performanceDate: Phase0cLinks.addDays(asOf, 30),
                                         missedScoutCount: m.missedScoutCount)
            _ = pair("T3 third member joining", "T3 and leaving", [key], into: &join, &leave,
                     change: { plant(key, joiner) }, revert: { unplant(key) },
                     between: { if i % stride(bucketList.count) == 0 { verify("bucket \(i) joined") } })
        }
        verify("after every bucket joined and left")
        lines.append("T3 third member joining (\(bucketList.count) buckets)                 \(join.text)")
        lines.append("T3 and leaving                                            \(leave.text)")
        all.merge(join)
        all.merge(leave)

        // T2 into T3: a twin appears for every flagged future row, then goes.
        var appear = Phase0cStats(), vanish = Phase0cStats()
        let flaggedFuture = futureBuckets.values.flatMap { $0 }
            .sorted { (byKey[$0]?.naturalKey ?? "") < (byKey[$1]?.naturalKey ?? "") }
        for (i, f) in flaggedFuture.enumerated() {
            guard let p = byKey[f] else { continue }
            let key = nextProbe()
            let twin = Phase0cSnapshot(naturalKey: "phase0c-twin-\(i)", groupName: p.groupName, venue: p.venue,
                                       performanceDate: p.performanceDate, runEndDate: p.runEndDate)
            _ = pair("T2 to T3 twin appearing", "T2 to T3 and going", [key], into: &appear, &vanish,
                     change: { plant(key, twin) }, revert: { unplant(key) },
                     between: { if i % stride(flaggedFuture.count) == 0 { verify("twin \(i) appeared") } })
        }
        verify("after every twin appeared and went")
        lines.append("T2 to T3 twin appearing (\(flaggedFuture.count) flagged future rows)      \(appear.text)")
        lines.append("T2 to T3 and going                                        \(vanish.text)")
        all.merge(appear)
        all.merge(vanish)

        // The bulk op the first run of this probe failed on (#4292): one scout accrual moving every flagged
        // row up one bucket, and back. Then its mirror, every row ABOVE goneThreshold down one, which keeps
        // every one of them flagged, and back. Neither crosses the threshold, so T2 should re-test nothing.
        var accrual = Phase0cStats(), accrualBack = Phase0cStats()
        let flaggedAll = byKey.filter { $0.value.disappearedFromFeed }.map { $0.key }
        var upSplit = "", backSplit = ""
        _ = pair("T3 scout accrual, every flagged row up one", "T3 accrual undone", flaggedAll,
                 into: &accrual, &accrualBack,
                 change: { for key in flaggedAll { byKey[key]?.missedScoutCount += 1 } },
                 revert: { for key in flaggedAll { byKey[key]?.missedScoutCount -= 1 } },
                 between: { upSplit = splitText(); verify("accrual") })
        backSplit = splitText()
        verify("accrual undone")
        lines.append("T3 scout accrual, every flagged row (\(flaggedAll.count) rows) up one      \(accrual.text) \(upSplit)")
        lines.append("T3 and back                                               \(accrualBack.text) \(backSplit)")
        all.merge(accrual)
        all.merge(accrualBack)

        var down = Phase0cStats(), downBack = Phase0cStats()
        let above = byKey.filter { $0.value.missedScoutCount > FeedReconcile.goneThreshold }.map { $0.key }
        var downSplit = "", downBackSplit = ""
        if !above.isEmpty {
            _ = pair("T3 accrual down, every row above goneThreshold", "T3 accrual down undone", above,
                     into: &down, &downBack,
                     change: { for key in above { byKey[key]?.missedScoutCount -= 1 } },
                     revert: { for key in above { byKey[key]?.missedScoutCount += 1 } },
                     between: { downSplit = splitText(); verify("accrual down") })
            downBackSplit = splitText()
            verify("accrual down undone")
        }
        lines.append("T3 accrual down, rows above goneThreshold (\(above.count) rows) down one  \(down.text) \(downSplit)")
        lines.append("T3 and back                                               \(downBack.text) \(downBackSplit)")
        all.merge(down)
        all.merge(downBack)

        // T3: the clock rolling past every distinct last night of a flagged future row, and back.
        var roll = Phase0cStats(), rollBack = Phase0cStats()
        let nights = Set(flaggedFuture.compactMap { t3.factsOf($0)?.lastNight }).sorted()
        for (i, night) in nights.enumerated() {
            let past = Phase0cLinks.addDays(night, 1)
            let there = Phase0.time { t3.advance(to: past) }
            roll.add(there)
            record("T3 rollover past a last night", there) {
                let ms = Phase0.time { t3.advance(to: past) }
                t3.advance(to: startAsOf)
                return ms
            }
            asOf = past
            if i % stride(nights.count) == 0 { verify("rollover \(i)") }
            let home = Phase0.time { t3.advance(to: startAsOf) }
            rollBack.add(home)
            record("T3 rollover back", home) {
                t3.advance(to: past)
                return Phase0.time { t3.advance(to: startAsOf) }
            }
            asOf = startAsOf
        }
        verify("after every rollover and back", brute: true)
        lines.append("T3 rollover past each last night (\(nights.count) nights)       \(roll.text)")
        lines.append("T3 and back                                               \(rollBack.text)")
        all.merge(roll)
        all.merge(rollBack)

        // The replays, per kind, of that kind's slowest key.
        let settled = Phase0cLinks.waitForLoad(below: 8)
        var replayLines: [String] = []
        var replayWorst = 0.0
        for kind in kindOrder {
            guard let slow = slowest[kind] else { continue }
            let reading = Phase0.Reading(runs: (0..<5).map { _ in slow.replay() })
            replayWorst = max(replayWorst, reading.median)
            replayLines.append(kind + String(format: ": single sample %.3f ms, replayed %.3f ms (%.3f to %.3f)",
                                             slow.ms, reading.median, reading.low, reading.high))
        }
        verify("after every replay", brute: true)

        let sizesText = roomSizes.sorted { ($0.live + $0.flagged) > ($1.live + $1.flagged) }
            .map { "\($0.live)/\($0.flagged)" }.joined(separator: " ")
        let blankRoom = roomSizes.first { $0.room.isEmpty }
        Phase0cLinks.say("""
            0c.2 [\(label)] \(models.count) rows, asOf \(startAsOf), \(rooms.count) rooms, \
            \(t2.contradicted.count) contradicted, \(bucketList.count) flagged future buckets, \(load), Debug build
              today's contradictedKeys (noise floor)                    \(todayT2.text)
              today's FeedBreakEvent.events, contradicted nil           \(todayT3.text)
              prototypes T2 plus T3 cold build                          \(cold.text)
              \(lines.joined(separator: "\n  "))
              ALL operations                                            \(all.text)
              most pair tests in one change \(testsMax)
              the "" room: \(blankRoom.map { "\($0.live) live, \($0.flagged) flagged" } ?? "absent")
              every room's size, live/flagged, largest first: \(sizesText)
              oracle comparisons \(checks), mismatches \(mismatches)
              REPLAYS, the slowest key of each kind five times, \(settled.text):
                \(replayLines.joined(separator: "\n    "))
              replayed max \(String(format: "%.3f", replayWorst)) ms
            """)
        return (all, replayWorst, settled.under)
    }
}
