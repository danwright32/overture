import Testing
import Foundation
import SwiftData

// #4106 plan v7, Phase 0c probes 0c.3 (T4, ProducerTables with witness counts) and 0c.4 (T5, the org answer
// ledger, and T6, EngagementLink under both chain rules).
//
// TEST CODE ONLY. Three test-only PROTOTYPES of plan section 7's patchable values, each proven equal to its
// canonical oracle after every operation and every undo, and then timed over every real key of its kind on
// a throwaway clone of the live store and its fourfold copy. Nothing under `mac/Overture/` changes, and
// none of these prototypes is the product type Phase 4b builds.
//
// TWO HALVES, deliberately run differently (plan section 4):
//
//   The PROPERTY HARNESSES run on every suite run. They read no store: each builds a committed synthetic
//   fixture of 60 and 300 rows from invented, containment-rich names (no real person, show or venue; every
//   address is under the reserved .example TLD, which the domain guard accepts) through a seeded generator, so a failure names a seed that reproduces it.
//   Their CI settings are small on purpose (plan section 4's 90 s budget); the deep settings are opt in:
//
//     TEST_RUNNER_MEASURE_4106_PHASE0C_PRODUCERS_DEEP=1 mac/scripts/run-tests-locked.sh \
//       -only-testing:OvertureTests/QueueEnginePhase0cProducersProbeTests
//
//   The COST PROBES clone Dan's store and run a stopwatch, so they are opt in and say they did not run
//   rather than passing silently when the variable is absent (L98):
//
//     TEST_RUNNER_MEASURE_4106_PHASE0C_PRODUCERS=1 mac/scripts/run-tests-locked.sh \
//       -only-testing:OvertureTests/QueueEnginePhase0cProducersProbeTests
//
// PRIVACY. Counts, durations and 8 hex digit hashes only: never a show name, presenter, venue or address
// (L222). A failure prints the seed, the step, the operation and a hash.
//
// Timings are in the Debug build the runner builds, the build every earlier #4106 figure was taken in, with
// the load average beside each block and a five-run spread of today's unchanged function as the noise floor.
// Every cost claim is over EVERY real key of its kind (plan section 4, L147), never the worst of a few
// chosen operations.
//
// THE PID. Every prototype is keyed by an Int standing for the row's persistentModelID: on the clone it is
// the row's index in one fetch, mapped once and never re-derived; in the fixtures it is the row's slot.
// Never the natural key, which a re-key changes (the fixtures re-key rows on purpose), and never a
// recipient id, which is a shared email.

enum Phase0cProducers {
    nonisolated static var enabled: Bool {
        ProcessInfo.processInfo.environment["MEASURE_4106_PHASE0C_PRODUCERS"] != nil
    }

    nonisolated static var deep: Bool {
        ProcessInfo.processInfo.environment["MEASURE_4106_PHASE0C_PRODUCERS_DEEP"] != nil
    }

    /// Seeds and operations per seed for each property harness: CI settings by default, plan section 4's
    /// deep settings (20 seeds by 500 operations) behind the variable. The CI settings are sized from this
    /// suite's own measured wall time (probe 0c.11's input): at 3 seeds by 60 operations the four harnesses
    /// took 120 s together in Debug, 64 s of it T4 at 300 rows, whose oracle and brute force both walk
    /// presenters against venues through `containsAsWords`. Plan section 4 gives ALL harnesses 90 s, so
    /// these take a few seconds each and the 300 row fixture runs one short seed; the per-op comparison
    /// is never what gets cut.
    nonisolated static func harness(size: Int) -> (seeds: Int, ops: Int) {
        if deep { return (20, 500) }
        return size <= 60 ? (2, 40) : (1, 25)
    }

    nonisolated static func say(_ line: String) { print("phase0c-producers " + line) }

    nonisolated static func hash8(_ s: String) -> String { Phase0b.hash8(s) }

    /// A distribution of per-operation timings: the true maximum over every sample, p99 and median.
    struct Dist {
        let sorted: [Double]
        init(_ xs: [Double]) { sorted = xs.sorted() }
        var count: Int { sorted.count }
        var max: Double { sorted.last ?? 0 }
        var median: Double { sorted.isEmpty ? 0 : sorted[sorted.count / 2] }
        var p99: Double {
            guard !sorted.isEmpty else { return 0 }
            let rank = Int((0.99 * Double(sorted.count)).rounded(.up))
            return sorted[Swift.max(0, Swift.min(sorted.count - 1, rank - 1))]
        }
        var text: String {
            String(format: "max %.3f  p99 %.3f  median %.3f ms  (n %d)", max, p99, median, count)
        }
    }

    /// Integer sizes (a group size, a fan-out): the same three figures.
    nonisolated static func sizes(_ xs: [Int]) -> String {
        let s = xs.sorted()
        guard !s.isEmpty else { return "none" }
        let p99 = s[Swift.max(0, Swift.min(s.count - 1, Int((0.99 * Double(s.count)).rounded(.up)) - 1))]
        return "count \(s.count), max \(s.last!), p99 \(p99), median \(s[s.count / 2])"
    }

    nonisolated static func pad(_ s: String, _ n: Int) -> String { Phase0b.pad(s, n) }

    /// Runs `ops` seeded operations per seed over a world value, with undo: a quarter of the steps pop the
    /// last operation off a stack and move the world straight back (one transition however many steps the
    /// operation took, so a multi-row undo is exercised too). `move` applies a transition to the prototype
    /// and returns every failure it found, already free of names.
    static func drive<W>(seeds: Int, ops: Int, seedBase: UInt64,
                         initial: (inout SeededGenerator) -> W,
                         cold: (W) -> [String],
                         step: (W, inout SeededGenerator) -> (kind: String, worlds: [W]),
                         move: (W, W, String) -> [String],
                         end: (W, String) -> [String] = { _, _ in [] })
        -> (transitions: Int, failures: [String], kinds: [String: Int]) {
        var transitions = 0
        var failures: [String] = []
        var kinds: [String: Int] = [:]
        for s in 0..<seeds {
            let seed = seedBase + UInt64(s)
            var g = SeededGenerator(seed: seed)
            var world = initial(&g)
            failures += cold(world).map { "seed \(seed) cold build: \($0)" }
            var stack: [W] = []
            for i in 0..<ops {
                if !stack.isEmpty && g.next() % 4 == 0 {
                    let prior = stack.removeLast()
                    failures += move(world, prior, "seed \(seed) step \(i) undo")
                    transitions += 1
                    kinds["undo", default: 0] += 1
                    world = prior
                    continue
                }
                let (kind, worlds) = step(world, &g)
                kinds[kind, default: 0] += 1
                var current = world
                for (j, next) in worlds.enumerated() {
                    failures += move(current, next, "seed \(seed) step \(i) op \(kind) part \(j)")
                    transitions += 1
                    current = next
                }
                stack.append(world)
                world = current
            }
            failures += end(world, "seed \(seed) end")
        }
        return (transitions, failures, kinds)
    }

    // MARK: - Invented, containment-rich vocabulary (no real names, L155, L222)

    static let stems = ["Lantern", "Harborlight", "Brightwater", "Copperleaf", "Juniperhill", "Marlowe",
                        "Quillfeather", "Saltmarsh", "Thistledown", "Wrenfield", "Ashgrove", "Bellwether"]
    static let rooms = ["Theatre", "Hall", "Playhouse", "Studio", "Arts Center", "Opera House", "Black Box"]
    static let troupes = ["Company", "Players", "Ensemble", "Collective", "Dance Theatre", "Chamber Opera",
                          "Productions"]
    static let titles = ["The Glass Orchard", "Winter Lanterns", "A Map of Salt", "Nine Quiet Rooms",
                         "The Copper Tide", "Small Hours", "Paper Moons Rising", "The Long Table"]

    static func pick<T>(_ xs: [T], _ g: inout SeededGenerator) -> T { xs[Int(g.next() % UInt64(xs.count))] }
    static func chance(_ percent: UInt64, _ g: inout SeededGenerator) -> Bool { g.next() % 100 < percent }

    /// A venue spelling: several fold to one key, and several contain another venue or a presenter as words.
    static func venue(stem: String, room: String, _ g: inout SeededGenerator) -> String {
        switch g.next() % 9 {
        case 0: return "The \(stem) \(room)"
        case 1: return "\(stem) \(room) Main Stage"
        case 2: return "\(stem) \(room) (Upstairs)"
        case 3: return "Studio B at \(stem) \(room)"
        case 4: return "\(stem) \(room) Company"
        case 5: return room
        default: return "\(stem) \(room)"
        }
    }

    /// A presenter spelling, including the shapes that make ProducerGate and OrgKey fold differently
    /// (an embedded address, a bracket, a leading article) and every containment direction.
    static func presenter(stem: String, troupe: String, room: String, _ g: inout SeededGenerator) -> String {
        switch g.next() % 10 {
        case 0: return "The \(stem) \(troupe)"
        case 1: return "\(stem) \(room) \(troupe)"
        case 2: return "\(stem) \(room)"
        case 3: return "\(stem) \(troupe), 12 Harbor Street"
        case 4: return "\(stem) \(troupe) (NYC)"
        case 5: return stem
        case 6: return "\(stem) \(room) Main Stage"
        default: return "\(stem) \(troupe)"
        }
    }

    static func dateString(_ dayOffset: Int) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let base = cal.date(from: DateComponents(year: 2026, month: 10, day: 1))!
        let d = cal.date(byAdding: .day, value: dayOffset, to: base)!
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
}

// MARK: - T4: ProducerTables with witness counts

/// A TEST-ONLY prototype of plan v7 T4: 0b.1's `Phase0bPatchTables` plus WITNESS sets. `witnesses[p]` is
/// every venue key that names the same room as presenter key `p` (`isVenueBrand`'s third arm, existential
/// over venue keys), and `witnessedBy[v]` its inverse. So a venue key that APPEARS is tested once against
/// each presenter sharing a word with it, and a venue key that LEAVES is struck from its witnesses' sets
/// with no test at all, which is what removes 0b.1's 108.1 ms tail: that sample re-asked `isVenueBrand`
/// for 172 presenter keys against every candidate venue each.
///
/// The rule is restated from ProducerGate's public pieces (`key`, `containsAsWords`) because the rule's own
/// helper is private, so it is checked against today's `QueueModel.ProducerTables` AND a brute force over
/// the definition with no word prefilter (`phase0bBruteBrand`), and a word-splitting fault here shows in
/// both. `apply` returns the presenter keys whose output (present, brand, room, venue count, qualifies)
/// changed: T5 consumes it.
struct Phase0cProducerTables {
    struct Pair: Equatable {
        let pk: String?
        let vk: String?
    }

    struct Out: Equatable {
        let brand: Bool
        let room: Bool
        let count: Int
        let qualifies: Bool
    }

    private(set) var overrides: ProducerOverrides
    private(set) var pairs: [Int: Pair] = [:]
    private(set) var presenterRef: [String: Int] = [:]
    private(set) var venueRef: [String: Int] = [:]
    private(set) var venuesByPresenter: [String: [String: Int]] = [:]
    private var venueWordSet: [String: Set<String>] = [:]
    private var presenterWordSet: [String: Set<String>] = [:]
    private var venueWords: [String: Set<String>] = [:]
    private var presenterWords: [String: Set<String>] = [:]
    private(set) var witnesses: [String: Set<String>] = [:]
    private(set) var witnessedBy: [String: Set<String>] = [:]
    private(set) var brand: Set<String> = []
    private(set) var room: Set<String> = []
    /// Presenter-against-venue tests the last `apply` (or the cold build) made.
    private(set) var lastTests = 0
    /// Presenter keys the last `apply` re-derived a verdict for.
    private(set) var lastReasked = 0

    init(rows: [Int: ProducerGate.Show], overrides: ProducerOverrides) {
        self.overrides = overrides
        var folded: [String: String?] = [:]
        func fold(_ raw: String?) -> String? {
            guard let raw else { return nil }
            if let hit = folded[raw] { return hit }
            let k = ProducerGate.key(raw)
            folded[raw] = k
            return k
        }
        for (pid, show) in rows {
            let p = Pair(pk: fold(show.presenter), vk: fold(show.venue))
            pairs[pid] = p
            count(p, 1)
        }
        for v in venueRef.keys { addVenueWords(v) }
        for p in presenterRef.keys { addPresenterWords(p) }
        var tests = 0
        for p in presenterRef.keys {
            let found = findWitnesses(p, tests: &tests)
            guard !found.isEmpty else { continue }
            witnesses[p] = found
            for v in found { witnessedBy[v, default: []].insert(p) }
        }
        lastTests = tests
        for p in presenterRef.keys { settle(p) }
    }

    var presenterKeys: Set<String> { Set(presenterRef.keys) }
    var venueKeys: Set<String> { Set(venueRef.keys) }

    func distinctVenueCount(_ pk: String) -> Int { venuesByPresenter[pk]?.count ?? 0 }

    func output(_ pk: String) -> Out? {
        guard presenterRef[pk] != nil else { return nil }
        let b = brand.contains(pk)
        let c = distinctVenueCount(pk)
        return Out(brand: b, room: room.contains(pk), count: c,
                   qualifies: !b && (overrides.promoted.contains(pk) || c >= 2))
    }

    func qualifies(_ pk: String?) -> Bool {
        guard let pk else { return false }
        return output(pk)?.qualifies ?? false
    }

    private func isBrand(_ pk: String) -> Bool {
        if venueRef[pk] != nil { return true }
        if overrides.demoted.contains(pk) { return true }
        if overrides.promoted.contains(pk) { return false }
        return !(witnesses[pk]?.isEmpty ?? true)
    }

    private mutating func settle(_ pk: String) {
        if isBrand(pk) { brand.insert(pk) } else { brand.remove(pk) }
        if brand.contains(pk) && venueRef[pk] != nil { room.insert(pk) } else { room.remove(pk) }
    }

    private static func wordSet(_ key: String) -> Set<String> {
        Set(key.split(separator: " ").map(String.init))
    }

    /// `containsAsWords` in either direction, behind the necessary condition that the needle's words are a
    /// subset of the haystack's (an occurrence bounded by spaces holds every word of the needle).
    private static func sameRoom(_ p: String, _ pw: Set<String>, _ v: String, _ vw: Set<String>) -> Bool {
        (vw.isSubset(of: pw) && ProducerGate.containsAsWords(p, v))
            || (pw.isSubset(of: vw) && ProducerGate.containsAsWords(v, p))
    }

    private func findWitnesses(_ p: String, tests: inout Int) -> Set<String> {
        guard let pw = presenterWordSet[p] else { return [] }
        var candidates = Set<String>()
        for w in pw { if let hits = venueWords[w] { candidates.formUnion(hits) } }
        var found = Set<String>()
        for v in candidates {
            tests += 1
            if Self.sameRoom(p, pw, v, venueWordSet[v]!) { found.insert(v) }
        }
        return found
    }

    private mutating func addVenueWords(_ v: String) {
        let ws = Self.wordSet(v)
        venueWordSet[v] = ws
        for w in ws { venueWords[w, default: []].insert(v) }
    }

    private mutating func removeVenueWords(_ v: String) {
        for w in venueWordSet[v] ?? [] {
            venueWords[w]?.remove(v)
            if venueWords[w]?.isEmpty == true { venueWords[w] = nil }
        }
        venueWordSet[v] = nil
    }

    private mutating func addPresenterWords(_ p: String) {
        let ws = Self.wordSet(p)
        presenterWordSet[p] = ws
        for w in ws { presenterWords[w, default: []].insert(p) }
    }

    private mutating func removePresenterWords(_ p: String) {
        for w in presenterWordSet[p] ?? [] {
            presenterWords[w]?.remove(p)
            if presenterWords[w]?.isEmpty == true { presenterWords[w] = nil }
        }
        presenterWordSet[p] = nil
    }

    private mutating func count(_ p: Pair, _ d: Int) {
        if let vk = p.vk {
            let n = (venueRef[vk] ?? 0) + d
            venueRef[vk] = n == 0 ? nil : n
        }
        guard let pk = p.pk else { return }
        let n = (presenterRef[pk] ?? 0) + d
        presenterRef[pk] = n == 0 ? nil : n
        guard let vk = p.vk else { return }
        var rooms = venuesByPresenter[pk] ?? [:]
        let m = (rooms[vk] ?? 0) + d
        rooms[vk] = m == 0 ? nil : m
        venuesByPresenter[pk] = rooms.isEmpty ? nil : rooms
    }

    /// Applies each changed row's new (presenter, venue), nil for a deleted row, and the overrides as they
    /// now stand; returns the presenter keys whose output changed.
    @discardableResult
    mutating func apply(_ changes: [(pid: Int, show: ProducerGate.Show?)], overrides new: ProducerOverrides) -> Set<String> {
        let incoming: [(pid: Int, pair: Pair?)] = changes.map { c in
            (c.pid, c.show.map { Pair(pk: ProducerGate.key($0.presenter), vk: ProducerGate.key($0.venue)) })
        }
        let overrideDiff = overrides.promoted.symmetricDifference(new.promoted)
            .union(overrides.demoted.symmetricDifference(new.demoted))
        var presentersTouched = Set<String>()
        var venuesTouched = Set<String>()
        for c in incoming {
            for p in [pairs[c.pid], c.pair] {
                if let pk = p?.pk { presentersTouched.insert(pk) }
                if let vk = p?.vk { venuesTouched.insert(vk) }
            }
        }
        var before: [String: Out?] = [:]
        for pk in presentersTouched.union(overrideDiff) { before.updateValue(output(pk), forKey: pk) }
        let venueWasPresent = Set(venuesTouched.filter { venueRef[$0] != nil })
        let presenterWasPresent = Set(presentersTouched.filter { presenterRef[$0] != nil })

        for c in incoming {
            if let old = pairs[c.pid] { count(old, -1) }
            pairs[c.pid] = c.pair
            if let now = c.pair { count(now, 1) }
        }
        overrides = new

        var reask = overrideDiff.union(presentersTouched)
        let goneVenues = venuesTouched.filter { venueWasPresent.contains($0) && venueRef[$0] == nil }
        let newVenues = venuesTouched.filter { !venueWasPresent.contains($0) && venueRef[$0] != nil }
        let gonePresenters = presentersTouched.filter { presenterWasPresent.contains($0) && presenterRef[$0] == nil }
        let newPresenters = presentersTouched.filter { !presenterWasPresent.contains($0) && presenterRef[$0] != nil }
        var tests = 0

        // A venue key that LEAVES is struck from every witness set holding it, with no test.
        for v in goneVenues {
            removeVenueWords(v)
            for p in witnessedBy[v] ?? [] {
                witnesses[p]?.remove(v)
                if witnesses[p]?.isEmpty == true { witnesses[p] = nil }
                reask.insert(p)
            }
            witnessedBy[v] = nil
            reask.insert(v)
        }
        for p in gonePresenters {
            removePresenterWords(p)
            for v in witnesses[p] ?? [] {
                witnessedBy[v]?.remove(p)
                if witnessedBy[v]?.isEmpty == true { witnessedBy[v] = nil }
            }
            witnesses[p] = nil
            brand.remove(p)
            room.remove(p)
        }
        for v in newVenues {
            addVenueWords(v)
            reask.insert(v)
        }
        // A presenter key that APPEARS is tested against every venue sharing a word, new venues included.
        for p in newPresenters {
            addPresenterWords(p)
            let found = findWitnesses(p, tests: &tests)
            if !found.isEmpty { witnesses[p] = found }
            for v in found { witnessedBy[v, default: []].insert(p) }
        }
        // A venue key that APPEARS is tested ONCE against each presenter sharing a word with it.
        for v in newVenues {
            let vw = venueWordSet[v]!
            var candidates = Set<String>()
            for w in vw { if let hits = presenterWords[w] { candidates.formUnion(hits) } }
            for p in candidates where !newPresenters.contains(p) {
                tests += 1
                guard Self.sameRoom(p, presenterWordSet[p]!, v, vw) else { continue }
                witnesses[p, default: []].insert(v)
                witnessedBy[v, default: []].insert(p)
                reask.insert(p)
            }
        }
        lastTests = tests

        var changed = Set<String>()
        var reasked = 0
        for pk in reask {
            let old: Out? = before.keys.contains(pk) ? before[pk]! : output(pk)
            if presenterRef[pk] != nil {
                settle(pk)
                reasked += 1
            }
            if output(pk) != old { changed.insert(pk) }
        }
        lastReasked = reasked
        return changed
    }
}

enum Phase0cT4Check {
    /// Today's tables' answer per presenter key, through a raw spelling that folds to it, so the oracle is
    /// asked exactly as the pass asks it (`VenueBrands.contains` folds a raw presenter).
    static func oracleOutputs(_ shows: [ProducerGate.Show],
                              overrides: ProducerOverrides) -> [String: Phase0cProducerTables.Out] {
        let oracle = QueueModel.ProducerTables(shows: shows, overrides: overrides)
        var out: [String: Phase0cProducerTables.Out] = [:]
        for raw in shows.compactMap(\.presenter) {
            guard let pk = ProducerGate.key(raw), out[pk] == nil else { continue }
            out[pk] = Phase0cProducerTables.Out(
                brand: oracle.venueBrands.contains(raw), room: oracle.venueBrands.isRoomName(raw),
                count: oracle.corpus.distinctVenueCount(pk),
                qualifies: ProducerGate.qualifies(raw, in: oracle.corpus, overrides: overrides))
        }
        return out
    }

    /// Every disagreement between the prototype, today's code and (when asked) the brute force.
    static func compare(_ proto: Phase0cProducerTables, shows: [ProducerGate.Show],
                        overrides: ProducerOverrides, brute: Bool) -> [String] {
        var bad: [String] = []
        let oracle = QueueModel.ProducerTables(shows: shows, overrides: overrides)
        let venueKeys = oracle.corpus.venues.keys
        if Set(oracle.corpus.presenterKeys) != proto.presenterKeys {
            bad.append("presenter key sets differ (\(oracle.corpus.presenterKeys.count) against \(proto.presenterKeys.count))")
        }
        if venueKeys != proto.venueKeys {
            bad.append("venue key sets differ (\(venueKeys.count) against \(proto.venueKeys.count))")
        }
        let outputs = oracleOutputs(shows, overrides: overrides)
        for (pk, want) in outputs {
            let got = proto.output(pk)
            if got != want {
                bad.append("presenter \(Phase0cProducers.hash8(pk)) oracle \(want) prototype \(String(describing: got))")
            }
            if brute {
                let bf = phase0bBruteBrand(pk, venueKeys: venueKeys, overrides: overrides)
                if bf != want.brand {
                    bad.append("presenter \(Phase0cProducers.hash8(pk)) brute force brand \(bf) oracle \(want.brand)")
                }
            }
        }
        return bad
    }

    /// The presenter keys whose output really changed between two corpora, for checking ChangedKeys.
    static func changedKeys(_ a: [String: Phase0cProducerTables.Out],
                            _ b: [String: Phase0cProducerTables.Out]) -> Set<String> {
        Set(a.keys).union(b.keys).filter { a[$0] != b[$0] }
    }
}

// MARK: - T5: the ledger (inheritedAnswers), decision 7(a) folded in

/// A TEST-ONLY prototype of plan v7 T5. It holds T4 inside it, so a row change reaches T4 first and T4's
/// changed presenter keys re-judge every row carrying one of them (fact 2), in the same change. Decision
/// 7(a) is folded in: the verdict is per PRESENTER key, never memoised per orgKey, so it cannot depend on
/// which row of an organisation happened to come first.
///
/// Neighbourhood per change: (a) the changed row; (b) every row whose producer key T4 reports changed;
/// (c) every row of an orgKey whose answer changed; (d) every row of an orgKey a refusal struck or lifted;
/// (e) every row whose natural key was held or released; (f) every row of an orgKey whose answer crossed
/// `probedAt + probeFreshness` when the clock moved. Each row in it is re-judged whole, so the answer never
/// depends on having remembered the row's previous orgKey.
struct Phase0cLedger {
    struct Row: Equatable {
        var key: String
        var presenter: String?
        var venue: String?
        var ownAnswer: Bool
    }

    struct Answer: Equatable {
        var result: Reachability.ProbeResult
        var probedAt: Date
        var presenterName: String
        var emails: [String]
    }

    struct Slice {
        let row: Row
        let orgKey: String?
        let producerKey: String?
    }

    struct World {
        var rows: [Int: Row]
        var answers: [String: Answer]
        var refusals: Set<ContactRefusal.Ledger.Row>
        var held: Set<String>
        var overrides: ProducerOverrides
        var now: Date
        var nextPid: Int
    }

    struct Changes {
        var rows: [(pid: Int, row: Row?)] = []
        var answers: [(orgKey: String, answer: Answer?)] = []
        var struck: [ContactRefusal.Ledger.Row] = []
        var lifted: [ContactRefusal.Ledger.Row] = []
        var heldAdded: Set<String> = []
        var heldRemoved: Set<String> = []
        var overrides: ProducerOverrides? = nil
        var now: Date? = nil

        static func diff(from a: World, to b: World) -> Changes {
            var c = Changes()
            for pid in Set(a.rows.keys).union(b.rows.keys) where a.rows[pid] != b.rows[pid] {
                c.rows.append((pid, b.rows[pid]))
            }
            for o in Set(a.answers.keys).union(b.answers.keys) where a.answers[o] != b.answers[o] {
                c.answers.append((o, b.answers[o]))
            }
            c.struck = Array(b.refusals.subtracting(a.refusals))
            c.lifted = Array(a.refusals.subtracting(b.refusals))
            c.heldAdded = b.held.subtracting(a.held)
            c.heldRemoved = a.held.subtracting(b.held)
            if a.overrides != b.overrides { c.overrides = b.overrides }
            if a.now != b.now { c.now = b.now }
            return c
        }
    }

    private(set) var tables: Phase0cProducerTables
    private(set) var slices: [Int: Slice] = [:]
    private(set) var byOrg: [String: Set<Int>] = [:]
    private(set) var byProducer: [String: Set<Int>] = [:]
    private(set) var byKey: [String: Set<Int>] = [:]
    private(set) var answers: [String: Answer]
    private(set) var refused: [String: Set<String>] = [:]
    private(set) var usable: [String: Answer] = [:]
    private var expiries: [(at: Date, orgKey: String)] = []
    private(set) var held: Set<String>
    private(set) var now: Date
    private(set) var inherited: [Int: OrgAnswerLedger.Inherited] = [:]
    private(set) var lastReevaluated = 0

    init(_ w: World) {
        tables = Phase0cProducerTables(rows: w.rows.mapValues { ProducerGate.Show(presenter: $0.presenter, venue: $0.venue) },
                                       overrides: w.overrides)
        answers = w.answers
        held = w.held
        now = w.now
        for (pid, row) in w.rows { index(pid, Self.slice(row)) }
        for r in w.refusals where r.scopeRaw == ContactRefusal.Scope.organisationRaw {
            refused[r.scopeId, default: []].insert(r.handleKey)
        }
        for o in answers.keys {
            usable[o] = usableAnswer(o)
            insertExpiry(o)
        }
        for pid in slices.keys { inherited[pid] = judge(pid) }
    }

    static func slice(_ row: Row) -> Slice {
        Slice(row: row, orgKey: OrgKey.stored(for: row.presenter), producerKey: ProducerGate.key(row.presenter))
    }

    private static func insert(_ pid: Int, _ key: String?, _ into: inout [String: Set<Int>]) {
        guard let key else { return }
        into[key, default: []].insert(pid)
    }

    private static func remove(_ pid: Int, _ key: String?, _ from: inout [String: Set<Int>]) {
        guard let key else { return }
        from[key]?.remove(pid)
        if from[key]?.isEmpty == true { from[key] = nil }
    }

    private mutating func index(_ pid: Int, _ s: Slice) {
        slices[pid] = s
        Self.insert(pid, s.orgKey, &byOrg)
        Self.insert(pid, s.producerKey, &byProducer)
        Self.insert(pid, s.row.key, &byKey)
    }

    private mutating func unindex(_ pid: Int, _ s: Slice) {
        Self.remove(pid, s.orgKey, &byOrg)
        Self.remove(pid, s.producerKey, &byProducer)
        Self.remove(pid, s.row.key, &byKey)
        slices[pid] = nil
    }

    /// The answer an organisation can lend right now: a positive, fresh, with an address left after refusals.
    private func usableAnswer(_ o: String) -> Answer? {
        guard var a = answers[o], a.result == .emailFound else { return nil }
        if let struck = refused[o], !struck.isEmpty {
            a.emails = a.emails.filter { e in ContactRefusal.key(for: e).map { !struck.contains($0) } ?? true }
        }
        guard !a.emails.isEmpty, !Reachability.probeIsStale(probedAt: a.probedAt, now: now) else { return nil }
        return a
    }

    private mutating func insertExpiry(_ o: String) {
        guard let a = answers[o] else { return }
        let at = a.probedAt.addingTimeInterval(Reachability.probeFreshness)
        let i = expiries.firstIndex { $0.at > at } ?? expiries.count
        expiries.insert((at, o), at: i)
    }

    private mutating func removeExpiry(_ o: String) {
        expiries.removeAll { $0.orgKey == o }
    }

    private func judge(_ pid: Int) -> OrgAnswerLedger.Inherited? {
        guard let s = slices[pid], !s.row.ownAnswer, !held.contains(s.row.key), s.row.presenter != nil,
              let o = s.orgKey, let u = usable[o], tables.qualifies(s.producerKey) else { return nil }
        return OrgAnswerLedger.Inherited(result: u.result, probedAt: u.probedAt, organisation: u.presenterName,
                                         emails: u.emails)
    }

    private mutating func reUsable(_ o: String, _ affected: inout Set<Int>) {
        let u = usableAnswer(o)
        guard u != usable[o] else { return }
        usable[o] = u
        affected.formUnion(byOrg[o] ?? [])
    }

    /// Applies one change; returns the pids whose inherited answer changed.
    @discardableResult
    mutating func apply(_ c: Changes) -> Set<Int> {
        var affected = Set<Int>()

        // T4 first, so every verdict this change moves is current before any row is judged.
        let showChanges: [(pid: Int, show: ProducerGate.Show?)] = c.rows.compactMap { change in
            let old = slices[change.pid]?.row
            let same = old?.presenter == change.row?.presenter && old?.venue == change.row?.venue
                && (old == nil) == (change.row == nil)
            return same ? nil : (change.pid, change.row.map { ProducerGate.Show(presenter: $0.presenter, venue: $0.venue) })
        }
        if !showChanges.isEmpty || c.overrides != nil {
            let producerChanged = tables.apply(showChanges, overrides: c.overrides ?? tables.overrides)
            for pk in producerChanged { affected.formUnion(byProducer[pk] ?? []) }
        }

        // The clock, before any answer is re-judged, so a change arriving with a new instant is judged at it.
        if let t = c.now, t != now {
            let lo = min(now, t).addingTimeInterval(-1), hi = max(now, t).addingTimeInterval(1)
            now = t
            for e in expiries where e.at >= lo && e.at <= hi { reUsable(e.orgKey, &affected) }
        }

        for change in c.rows {
            if let old = slices[change.pid] { unindex(change.pid, old) }
            if let row = change.row { index(change.pid, Self.slice(row)) }
            affected.insert(change.pid)
        }

        for a in c.answers {
            answers[a.orgKey] = a.answer
            removeExpiry(a.orgKey)
            insertExpiry(a.orgKey)
            reUsable(a.orgKey, &affected)
        }

        var refusedOrgs = Set<String>()
        for r in c.struck where r.scopeRaw == ContactRefusal.Scope.organisationRaw {
            refused[r.scopeId, default: []].insert(r.handleKey)
            refusedOrgs.insert(r.scopeId)
        }
        for r in c.lifted where r.scopeRaw == ContactRefusal.Scope.organisationRaw {
            refused[r.scopeId]?.remove(r.handleKey)
            if refused[r.scopeId]?.isEmpty == true { refused[r.scopeId] = nil }
            refusedOrgs.insert(r.scopeId)
        }
        for o in refusedOrgs { reUsable(o, &affected) }

        for k in c.heldAdded { held.insert(k); affected.formUnion(byKey[k] ?? []) }
        for k in c.heldRemoved { held.remove(k); affected.formUnion(byKey[k] ?? []) }

        var changed = Set<Int>()
        for pid in affected {
            let next = judge(pid)
            if next != inherited[pid] { changed.insert(pid) }
            inherited[pid] = next
        }
        lastReevaluated = affected.count
        return changed
    }

    /// The prototype's own indexes against their definition, rebuilt from the slices. The output check
    /// cannot see a stale index entry (a row left in its OLD orgKey is re-judged from its current fields
    /// and comes out right), so this is what makes an index fault visible before it becomes a cost leak.
    func indexesMatchTheirDefinition() -> Bool {
        var org: [String: Set<Int>] = [:], producer: [String: Set<Int>] = [:], key: [String: Set<Int>] = [:]
        for (pid, s) in slices {
            Self.insert(pid, s.orgKey, &org)
            Self.insert(pid, s.producerKey, &producer)
            Self.insert(pid, s.row.key, &key)
        }
        return org == byOrg && producer == byProducer && key == byKey
    }

    /// The prototype's output keyed by natural key, as the oracle keys it.
    var byNaturalKey: [String: OrgAnswerLedger.Inherited] {
        var out: [String: OrgAnswerLedger.Inherited] = [:]
        for (pid, i) in inherited { if let s = slices[pid] { out[s.row.key] = i } }
        return out
    }
}

enum Phase0cT5Check {
    /// Today's function through the canonical wrapper, over SwiftData values built from the world.
    static func oracle(_ w: Phase0cLedger.World) -> [String: OrgAnswerLedger.Inherited] {
        let corpus: [Prospect] = w.rows.values.map { r in
            let p = Prospect(naturalKey: r.key, groupName: "Invented", discipline: "", venue: r.venue,
                             performanceDate: nil, sourceListingURL: nil, priorRelationship: "", production: "",
                             profile: "", coverage: "", fitScore: 0, tier: "", fitReason: "",
                             matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                             ingestedAt: w.now)
            p.presenter = r.presenter
            p.reachabilityProbedAt = r.ownAnswer ? w.now : nil
            return p
        }
        let answers = w.answers.map { o, a in
            OrgReachabilityAnswer(orgKey: o, result: a.result, probedAt: a.probedAt, sourceNaturalKey: "",
                                  sourceGroupName: "", presenterName: a.presenterName, foundEmails: a.emails)
        }
        return CanonicalOracle.inheritedAnswers(answers, corpus: corpus, overrides: w.overrides,
                                                refusals: ContactRefusal.Ledger(rows: Array(w.refusals)),
                                                heldKeys: w.held, now: w.now)
    }

    /// A brute force of decision 7(a)'s rule, row by row from scratch with no memo at all: every row asks
    /// today's `ProducerGate.qualifies` itself, and refusals are applied by hand.
    static func brute(_ w: Phase0cLedger.World) -> [String: OrgAnswerLedger.Inherited] {
        let corpus = ProducerGate.Corpus(w.rows.values.map { ProducerGate.Show(presenter: $0.presenter, venue: $0.venue) })
        var out: [String: OrgAnswerLedger.Inherited] = [:]
        for r in w.rows.values {
            guard !r.ownAnswer, !w.held.contains(r.key), let presenter = r.presenter,
                  let o = OrgKey.stored(for: presenter), let a = w.answers[o], a.result == .emailFound else { continue }
            let kept = a.emails.filter { e in
                guard let h = ContactRefusal.key(for: e) else { return true }
                return !w.refusals.contains(ContactRefusal.Ledger.Row(
                    scopeRaw: ContactRefusal.Scope.organisationRaw, scopeId: o, handleKey: h))
            }
            guard !kept.isEmpty, !Reachability.probeIsStale(probedAt: a.probedAt, now: w.now),
                  ProducerGate.qualifies(presenter, in: corpus, overrides: w.overrides) else { continue }
            out[r.key] = OrgAnswerLedger.Inherited(result: a.result, probedAt: a.probedAt,
                                                   organisation: a.presenterName, emails: kept)
        }
        return out
    }

    /// Rows whose orgKey holds, among the rows today's memo could meet, two producer keys that disagree on
    /// `qualifies`: the only rows where decision 7(a) is allowed to differ from today's oracle.
    static func sevenADivergentOrgs(_ w: Phase0cLedger.World) -> Set<String> {
        let corpus = ProducerGate.Corpus(w.rows.values.map { ProducerGate.Show(presenter: $0.presenter, venue: $0.venue) })
        var verdicts: [String: Set<Bool>] = [:]
        for r in w.rows.values {
            guard !r.ownAnswer, !w.held.contains(r.key), let presenter = r.presenter,
                  let o = OrgKey.stored(for: presenter) else { continue }
            verdicts[o, default: []].insert(ProducerGate.qualifies(presenter, in: corpus, overrides: w.overrides))
        }
        return Set(verdicts.filter { $0.value.count > 1 }.keys)
    }

    /// Every disagreement: against the 7(a) brute force always; against today's oracle except on rows of an
    /// orgKey where 7(a) is allowed to differ, which are counted instead.
    static func compare(_ proto: Phase0cLedger, _ w: Phase0cLedger.World,
                        brute precomputed: [String: OrgAnswerLedger.Inherited]? = nil,
                        oracleToo: Bool = true) -> (bad: [String], sevenA: Int) {
        var bad: [String] = []
        let got = proto.byNaturalKey
        let want = precomputed ?? brute(w)
        for k in Set(got.keys).union(want.keys) where got[k] != want[k] {
            bad.append("row \(Phase0cProducers.hash8(k)) differs from the 7(a) brute force")
        }
        if !proto.indexesMatchTheirDefinition() { bad.append("an index differs from its definition") }
        var sevenA = 0
        if oracleToo {
            let today = oracle(w)
            let differing = Set(got.keys).union(today.keys).filter { got[$0] != today[$0] }
            let divergent = differing.isEmpty ? [] : sevenADivergentOrgs(w)
            let orgOf = Dictionary(w.rows.values.map { ($0.key, OrgKey.stored(for: $0.presenter)) },
                                   uniquingKeysWith: { a, _ in a })
            for k in differing {
                if let o = orgOf[k] ?? nil, divergent.contains(o) { sevenA += 1; continue }
                bad.append("row \(Phase0cProducers.hash8(k)) differs from today's canonical oracle")
            }
        }
        return (bad, sevenA)
    }
}

// MARK: - T6: EngagementLink over drawn rows, under both chain rules

/// A TEST-ONLY prototype of plan v7 T6: `titleKey -> Set<PID>` over drawn, dated rows, re-clustering only
/// the titles a change touches (its old and its new), under either chain rule of decision 18:
/// (a) today's, a row joins when within `RunGrouping.gapDays` of the last night of the row appended LAST;
/// (b) the answered one, measured from the cluster's LATEST last night so far.
/// Rows sort by (date, natural key), which is the canonical wrapper's order. Dates are pre-folded to day
/// ordinals once per row, so a rebuild does no calendar work.
struct Phase0cEngagement {
    enum Rule: String, CaseIterable {
        case lastAppended = "(a) last appended"
        case clusterLatest = "(b) cluster latest"
    }

    struct Slice: Equatable {
        let key: String
        let title: String
        let venue: String?
        let venueCanon: String
        let date: String?
        let dateOrd: Int?
        let lastOrd: Int?
        let drawn: Bool
    }

    struct Source: Equatable {
        var key: String
        var groupName: String
        var venue: String?
        var date: String?
        var runEnd: String?
        var drawn: Bool

        var linkRow: EngagementLink.Row {
            EngagementLink.Row(id: key, groupName: groupName, venue: venue, performanceDate: date, runEndDate: runEnd)
        }
    }

    static let anchor = "2000-01-01"

    static func slice(_ s: Source) -> Slice {
        let last = EasternDate.runLastNight(runEndDate: s.runEnd, performanceDate: s.date)
        return Slice(key: s.key, title: GroupNameMatch.normalize(s.groupName), venue: s.venue,
                     venueCanon: (s.venue ?? "").lowercased().trimmingCharacters(in: .whitespaces),
                     date: s.date, dateOrd: s.date.flatMap { EasternDate.daysUntil(from: anchor, to: $0) },
                     lastOrd: last.flatMap { EasternDate.daysUntil(from: anchor, to: $0) }, drawn: s.drawn)
    }

    let rule: Rule
    private(set) var rows: [Int: Slice] = [:]
    private(set) var byTitle: [String: Set<Int>] = [:]
    private(set) var out: [Int: [EngagementLink.Member]] = [:]
    private(set) var lastRebuilt = 0

    init(rule: Rule, rows: [Int: Slice]) {
        self.rule = rule
        self.rows = rows
        for (pid, s) in rows where Self.linked(s) { byTitle[s.title, default: []].insert(pid) }
        for t in byTitle.keys {
            for (pid, members) in clusterOutputs(t) { out[pid] = members }
        }
    }

    private static func linked(_ s: Slice) -> Bool { s.drawn && s.date != nil }

    /// Each row's cluster, as its members' pids, for one title (used to count membership differences).
    func clusters(_ title: String) -> [[Int]] {
        let members = (byTitle[title] ?? []).map { ($0, rows[$0]!) }
            .sorted { ($0.1.date!, $0.1.key) < ($1.1.date!, $1.1.key) }
        var clusters: [[(Int, Slice)]] = []
        var latest: Int? = nil
        for m in members {
            var join = false
            if let current = clusters.last, let d = m.1.dateOrd {
                switch rule {
                case .lastAppended:
                    if let prevLast = current.last!.1.lastOrd { join = d - prevLast <= RunGrouping.gapDays }
                case .clusterLatest:
                    if let l = latest { join = d - l <= RunGrouping.gapDays }
                }
            }
            if join {
                clusters[clusters.count - 1].append(m)
                if let lo = m.1.lastOrd { latest = max(latest ?? lo, lo) }
            } else {
                clusters.append([m])
                latest = m.1.lastOrd
            }
        }
        return clusters.map { $0.map(\.0) }
    }

    private func clusterOutputs(_ title: String) -> [Int: [EngagementLink.Member]] {
        var result: [Int: [EngagementLink.Member]] = [:]
        for cluster in clusters(title) {
            guard Set(cluster.map { rows[$0]!.venueCanon }).count > 1 else { continue }
            for pid in cluster {
                result[pid] = cluster.filter { $0 != pid }
                    .map { EngagementLink.Member(venue: rows[$0]!.venue, date: rows[$0]!.date!) }
            }
        }
        return result
    }

    /// Applies each changed row's new slice, nil for a deleted row; returns the pids whose output changed.
    @discardableResult
    mutating func apply(_ changes: [(pid: Int, slice: Slice?)]) -> Set<Int> {
        var titles = Set<String>()
        for c in changes {
            if let old = rows[c.pid], Self.linked(old) {
                titles.insert(old.title)
            }
            if let s = c.slice, Self.linked(s) { titles.insert(s.title) }
        }
        var previous: [String: Set<Int>] = [:]
        for t in titles { previous[t] = byTitle[t] ?? [] }
        for c in changes {
            if let old = rows[c.pid], Self.linked(old) {
                byTitle[old.title]?.remove(c.pid)
                if byTitle[old.title]?.isEmpty == true { byTitle[old.title] = nil }
            }
            rows[c.pid] = c.slice
            if let s = c.slice, Self.linked(s) { byTitle[s.title, default: []].insert(c.pid) }
        }
        // Every touched title is re-clustered BEFORE any output is written, because a row that moved title
        // is a member of both, and writing title by title would let its old title's pass (where it is no
        // longer a member) overwrite what its new title just computed, in set iteration order.
        var fresh: [Int: [EngagementLink.Member]] = [:]
        var members = Set<Int>()
        for t in titles {
            fresh.merge(clusterOutputs(t)) { first, _ in first }
            members.formUnion(previous[t]!)
            members.formUnion(byTitle[t] ?? [])
        }
        var changed = Set<Int>()
        for pid in members where fresh[pid] != out[pid] {
            changed.insert(pid)
            out[pid] = fresh[pid]
        }
        let rebuilt = members.count
        lastRebuilt = rebuilt
        return changed
    }

    var byNaturalKey: [String: [EngagementLink.Member]] {
        var result: [String: [EngagementLink.Member]] = [:]
        for (pid, members) in out { if let s = rows[pid] { result[s.key] = members } }
        return result
    }
}

enum Phase0cT6Check {
    /// A brute force of rule (b), written apart from the prototype: every row is compared with EVERY row
    /// already in its cluster (no running maximum), through EasternDate's own day arithmetic and the
    /// production normalisation, over the whole list each time.
    static func bruteClusterLatest(_ rows: [EngagementLink.Row]) -> [String: [EngagementLink.Member]] {
        func canon(_ s: String?) -> String { (s ?? "").lowercased().trimmingCharacters(in: .whitespaces) }
        func lastNight(_ r: EngagementLink.Row) -> String? {
            guard let l = EasternDate.runLastNight(runEndDate: r.runEndDate, performanceDate: r.performanceDate),
                  EasternDate.daysUntil(from: l, to: l) != nil else { return nil }
            return l
        }
        let dated = rows.filter { $0.performanceDate != nil }
        var out: [String: [EngagementLink.Member]] = [:]
        for title in Set(dated.map { GroupNameMatch.normalize($0.groupName) }) {
            let ordered = dated.filter { GroupNameMatch.normalize($0.groupName) == title }
                .sorted { ($0.performanceDate!, $0.id) < ($1.performanceDate!, $1.id) }
            var clusters: [[EngagementLink.Row]] = []
            for r in ordered {
                let latest = clusters.last?.compactMap(lastNight).max()
                if let latest, let gap = EasternDate.daysUntil(from: latest, to: r.performanceDate!),
                   gap <= RunGrouping.gapDays {
                    clusters[clusters.count - 1].append(r)
                } else {
                    clusters.append([r])
                }
            }
            for cluster in clusters where Set(cluster.map { canon($0.venue) }).count > 1 {
                for r in cluster {
                    out[r.id] = cluster.filter { $0.id != r.id }
                        .map { EngagementLink.Member(venue: $0.venue, date: $0.performanceDate!) }
                }
            }
        }
        return out
    }

    static func truth(_ rule: Phase0cEngagement.Rule, _ drawn: [EngagementLink.Row]) -> [String: [EngagementLink.Member]] {
        switch rule {
        case .lastAppended: return CanonicalOracle.engagementLink(drawn)
        case .clusterLatest: return bruteClusterLatest(drawn)
        }
    }

    static func drawnRows(_ w: [Int: Phase0cEngagement.Source]) -> [EngagementLink.Row] {
        w.values.filter(\.drawn).map(\.linkRow)
    }

    static func compare(_ proto: Phase0cEngagement, _ want: [String: [EngagementLink.Member]]) -> [String] {
        let got = proto.byNaturalKey
        return Set(got.keys).union(want.keys).filter { got[$0] != want[$0] }
            .map { "row \(Phase0cProducers.hash8($0)) differs" }
    }
}

// MARK: - Fixtures (synthetic, seeded, containment rich)

enum Phase0cFixtures {
    typealias F = Phase0cProducers

    static func stemsFor(size: Int) -> [String] { Array(F.stems.prefix(size <= 60 ? 4 : F.stems.count)) }

    static func randomShow(_ stems: [String], _ g: inout SeededGenerator) -> ProducerGate.Show {
        let stem = F.pick(stems, &g)
        let room = F.pick(F.rooms, &g)
        let venueStem = F.chance(60, &g) ? stem : F.pick(stems, &g)
        let presenter: String? = F.chance(5, &g) ? nil
            : F.presenter(stem: stem, troupe: F.pick(F.troupes, &g), room: room, &g)
        let venue: String? = F.chance(4, &g) ? nil : F.venue(stem: venueStem, room: F.pick(F.rooms, &g), &g)
        return ProducerGate.Show(presenter: presenter, venue: venue)
    }

    // T4

    struct T4World {
        var shows: [Int: ProducerGate.Show]
        var overrides: ProducerOverrides
        var nextPid: Int
        var list: [ProducerGate.Show] { shows.keys.sorted().map { shows[$0]! } }
    }

    static func t4World(size: Int, _ g: inout SeededGenerator) -> T4World {
        let stems = stemsFor(size: size)
        var shows: [Int: ProducerGate.Show] = [:]
        for i in 0..<size { shows[i] = randomShow(stems, &g) }
        return T4World(shows: shows, overrides: .none, nextPid: size)
    }

    /// 0b.1's ten kinds plus plan v7 T4's four.
    static func t4Step(_ w: T4World, size: Int, _ g: inout SeededGenerator) -> (kind: String, worlds: [T4World]) {
        let stems = stemsFor(size: size)
        var next = w
        let pids = w.shows.keys.sorted()
        func anyPid() -> Int { F.pick(pids, &g) }
        func withPresenter() -> Int? { pids.filter { w.shows[$0]!.presenter != nil }.randomElement(using: &g) }
        switch g.next() % 14 {
        case 0:
            next.shows[next.nextPid] = ProducerGate.Show(presenter: "Zephyr Invented Ensemble \(g.next() % 7)",
                                                         venue: w.shows[anyPid()]!.venue)
            next.nextPid += 1
            return ("insert, new presenter", [next])
        case 1:
            next.shows[next.nextPid] = ProducerGate.Show(presenter: w.shows[anyPid()]!.presenter,
                                                         venue: "Invented Room Number \(g.next() % 7)")
            next.nextPid += 1
            return ("insert, new venue", [next])
        case 2:
            next.shows[next.nextPid] = w.shows[anyPid()]!
            next.nextPid += 1
            return ("insert, existing pair", [next])
        case 3:
            guard pids.count > 2 else { return ("delete (skipped)", []) }
            next.shows[anyPid()] = nil
            return ("delete", [next])
        case 4:
            let p = anyPid()
            next.shows[p] = ProducerGate.Show(presenter: w.shows[anyPid()]!.presenter, venue: w.shows[p]!.venue)
            return ("presenter edit", [next])
        case 5:
            guard let p = withPresenter() else { return ("venue edit (skipped)", []) }
            next.shows[p] = ProducerGate.Show(presenter: w.shows[p]!.presenter, venue: "\(w.shows[p]!.presenter!) Theatre")
            return ("venue edit to '<presenter> Theatre'", [next])
        case 6:
            let p = anyPid()
            next.shows[p] = ProducerGate.Show(presenter: w.shows[p]!.presenter, venue: "Theatre")
            return ("venue edit to 'Theatre'", [next])
        case 7:
            guard pids.count > 3 else { return ("merge (skipped)", []) }
            let a = anyPid(), b = anyPid()
            guard a != b else { return ("merge (skipped)", []) }
            next.shows[a] = ProducerGate.Show(presenter: w.shows[a]!.presenter, venue: w.shows[b]!.venue)
            next.shows[b] = nil
            return ("merge (two rows into one)", [next])
        case 8, 9:
            guard let p = withPresenter(), let k = ProducerGate.key(w.shows[p]!.presenter) else { return ("override (skipped)", []) }
            if g.next() % 2 == 0 {
                next.overrides.promoted.insert(k); next.overrides.demoted.remove(k)
                return ("promote", [next])
            }
            next.overrides.demoted.insert(k); next.overrides.promoted.remove(k)
            return ("demote", [next])
        case 10:
            // A venue spelled from the corpus's commonest words, so it shares a word with nearly everyone.
            var freq: [String: Int] = [:]
            for s in w.shows.values { for word in (ProducerGate.key(s.venue) ?? "").split(separator: " ") { freq[String(word), default: 0] += 1 } }
            let common = freq.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(5).map(\.key)
            next.shows[next.nextPid] = ProducerGate.Show(presenter: w.shows[anyPid()]!.presenter,
                                                         venue: common.joined(separator: " "))
            next.nextPid += 1
            return ("adversarial venue of the commonest words", [next])
        case 11:
            // One venue key added and removed three times running.
            let v = "\(F.pick(stems, &g)) Invented Annex"
            var worlds: [T4World] = []
            var cur = w
            for _ in 0..<3 {
                var on = cur
                on.shows[on.nextPid] = ProducerGate.Show(presenter: w.shows[anyPid()]!.presenter, venue: v)
                worlds.append(on)
                var off = on
                off.shows[on.nextPid] = nil
                off.nextPid += 1
                worlds.append(off)
                cur = off
            }
            return ("repeated add and remove of one venue key", worlds)
        case 12:
            // A presenter spelled exactly as an existing venue.
            guard let venue = w.shows.values.compactMap(\.venue).randomElement(using: &g) else { return ("presenter is a venue (skipped)", []) }
            next.shows[next.nextPid] = ProducerGate.Show(presenter: venue, venue: w.shows[anyPid()]!.venue)
            next.nextPid += 1
            return ("presenter key that is also a venue key", [next])
        default:
            // A venue-only edit taking a presenter from one venue to two.
            var rowsByPresenter: [String: [Int]] = [:]
            for p in pids { if let k = ProducerGate.key(w.shows[p]!.presenter) { rowsByPresenter[k, default: []].append(p) } }
            let oneVenue = rowsByPresenter.filter { k, rows in
                rows.count >= 2 && Set(rows.compactMap { ProducerGate.key(w.shows[$0]!.venue) }).count == 1
            }.keys.sorted()
            guard !oneVenue.isEmpty else {
                let p = anyPid()
                next.shows[next.nextPid] = w.shows[p]!
                next.nextPid += 1
                return ("venue-only edit, one to two (seeded a second row)", [next])
            }
            let k = F.pick(oneVenue, &g)
            let p = rowsByPresenter[k]![0]
            let other = F.venue(stem: F.pick(stems, &g), room: F.pick(F.rooms, &g), &g)
            next.shows[p] = ProducerGate.Show(presenter: w.shows[p]!.presenter, venue: other)
            return ("venue-only edit, one venue to two", [next])
        }
    }

    // T5

    static func email(_ stem: String, _ box: String) -> String { "\(box)@\(stem.lowercased()).example" }

    static func t5World(size: Int, _ g: inout SeededGenerator) -> Phase0cLedger.World {
        let stems = stemsFor(size: size)
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        var rows: [Int: Phase0cLedger.Row] = [:]
        for i in 0..<size {
            let s = randomShow(stems, &g)
            rows[i] = Phase0cLedger.Row(key: "k\(String(format: "%04d", i))", presenter: s.presenter, venue: s.venue,
                                        ownAnswer: F.chance(10, &g))
        }
        var answers: [String: Phase0cLedger.Answer] = [:]
        var refusals = Set<ContactRefusal.Ledger.Row>()
        for o in Set(rows.values.compactMap { OrgKey.stored(for: $0.presenter) }).sorted() where F.chance(60, &g) {
            let stem = F.pick(stems, &g)
            let emails = F.chance(50, &g) ? [email(stem, "booking"), email(stem, "info")] : [email(stem, "hello")]
            answers[o] = Phase0cLedger.Answer(result: F.chance(85, &g) ? .emailFound : .weakContactOnly,
                                              probedAt: now.addingTimeInterval(-Double(g.next() % 120) * 86_400),
                                              presenterName: "\(stem) Invented Org", emails: emails)
            if F.chance(15, &g), let h = ContactRefusal.key(for: emails[0]) {
                refusals.insert(.init(scopeRaw: ContactRefusal.Scope.organisationRaw, scopeId: o, handleKey: h))
            }
        }
        var held = Set<String>()
        for r in rows.values where F.chance(5, &g) { held.insert(r.key) }
        return Phase0cLedger.World(rows: rows, answers: answers, refusals: refusals, held: held, overrides: .none,
                                   now: now, nextPid: size)
    }

    static func t5Step(_ w: Phase0cLedger.World, size: Int, _ g: inout SeededGenerator) -> (kind: String, worlds: [Phase0cLedger.World]) {
        let stems = stemsFor(size: size)
        var next = w
        let pids = w.rows.keys.sorted()
        let p = F.pick(pids, &g)
        let row = w.rows[p]!
        let orgs = Set(w.rows.values.compactMap { OrgKey.stored(for: $0.presenter) }).sorted()
        switch g.next() % 18 {
        case 0:
            // Respelled within its organisation: an address, a bracket or an article that OrgKey folds away
            // and ProducerGate does not always.
            guard let presenter = row.presenter else { return ("respell within (skipped)", []) }
            let bare = presenter.replacingOccurrences(of: ", 12 Harbor Street", with: "")
                .replacingOccurrences(of: " (NYC)", with: "")
            let variants = [bare, "\(bare), 12 Harbor Street", "\(bare) (NYC)", "The \(bare)"]
            next.rows[p]!.presenter = F.pick(variants, &g)
            return ("presenter respelled within its orgKey", [next])
        case 1:
            next.rows[p]!.presenter = w.rows[F.pick(pids, &g)]!.presenter
            return ("presenter respelled across orgKeys", [next])
        case 2:
            // A venue-only edit taking a presenter from one venue to two (or back).
            let siblings = pids.filter { w.rows[$0]!.presenter == row.presenter && $0 != p }
            guard !siblings.isEmpty, row.presenter != nil else {
                next.rows[next.nextPid] = Phase0cLedger.Row(key: "n\(next.nextPid)", presenter: row.presenter,
                                                            venue: row.venue, ownAnswer: false)
                next.nextPid += 1
                return ("venue-only edit (seeded a sibling row)", [next])
            }
            next.rows[p]!.venue = F.chance(50, &g) ? w.rows[siblings[0]]!.venue
                : F.venue(stem: F.pick(stems, &g), room: F.pick(F.rooms, &g), &g)
            return ("venue-only edit, one venue and two", [next])
        case 3:
            guard let k = ProducerGate.key(row.presenter) else { return ("promote (skipped)", []) }
            if next.overrides.promoted.contains(k) { next.overrides.promoted.remove(k) } else {
                next.overrides.promoted.insert(k); next.overrides.demoted.remove(k)
            }
            return ("promote toggled", [next])
        case 4:
            guard let k = ProducerGate.key(row.presenter) else { return ("demote (skipped)", []) }
            if next.overrides.demoted.contains(k) { next.overrides.demoted.remove(k) } else {
                next.overrides.demoted.insert(k); next.overrides.promoted.remove(k)
            }
            return ("demote toggled", [next])
        case 5:
            guard let o = orgs.filter({ w.answers[$0] == nil }).randomElement(using: &g) else { return ("answer arrives (skipped)", []) }
            let stem = F.pick(stems, &g)
            next.answers[o] = Phase0cLedger.Answer(result: .emailFound, probedAt: w.now.addingTimeInterval(-86_400),
                                                   presenterName: "\(stem) Invented Org",
                                                   emails: [email(stem, "booking"), email(stem, "office")])
            return ("answer arrives", [next])
        case 6:
            // The clock moves past the next answer to expire.
            let fresh = w.answers.values.map { $0.probedAt.addingTimeInterval(Reachability.probeFreshness) }
                .filter { $0 >= w.now }.min()
            next.now = (fresh ?? w.now).addingTimeInterval(3_600)
            return ("an answer expires (clock forward)", [next])
        case 7:
            next.now = w.now.addingTimeInterval(-30 * 86_400)
            return ("clock back thirty days", [next])
        case 8:
            guard let o = w.answers.keys.sorted().randomElement(using: &g) else { return ("replace (skipped)", []) }
            let stem = F.pick(stems, &g)
            next.answers[o]!.emails = [email(stem, "replaced")]
            next.answers[o]!.presenterName = "\(stem) Replacement Org"
            return ("answer replaced at equal probedAt", [next])
        case 9:
            guard let o = w.answers.keys.sorted().randomElement(using: &g) else { return ("remove (skipped)", []) }
            next.answers[o] = nil
            return ("answer removed", [next])
        case 10:
            next.rows[p]!.ownAnswer.toggle()
            return ("row gains or loses its own answer", [next])
        case 11:
            if next.held.contains(row.key) { next.held.remove(row.key) } else { next.held.insert(row.key) }
            return ("held key toggled", [next])
        case 12:
            // Strike one of two addresses, then the last, then lift both: three transitions.
            guard let o = w.answers.keys.sorted().filter({ w.answers[$0]!.emails.count >= 2 }).randomElement(using: &g)
            else { return ("refusal sequence (skipped)", []) }
            let hs = w.answers[o]!.emails.compactMap { ContactRefusal.key(for: $0) }
            let rows = hs.map { ContactRefusal.Ledger.Row(scopeRaw: ContactRefusal.Scope.organisationRaw, scopeId: o, handleKey: $0) }
            var one = w; one.refusals.insert(rows[0])
            var all = one; all.refusals.formUnion(rows)
            var lifted = all; lifted.refusals.subtract(rows)
            return ("refusal strikes one, then the last, then lifted", [one, all, lifted])
        case 13:
            guard let h = ContactRefusal.key(for: email(F.pick(stems, &g), "booking")) else { return ("show refusal (skipped)", []) }
            next.refusals.insert(.init(scopeRaw: ContactRefusal.Scope.showRaw, scopeId: row.key, handleKey: h))
            return ("show-scoped refusal (changes nothing)", [next])
        case 14:
            let s = randomShow(stems, &g)
            next.rows[next.nextPid] = Phase0cLedger.Row(key: "n\(next.nextPid)", presenter: s.presenter, venue: s.venue,
                                                        ownAnswer: false)
            next.nextPid += 1
            return ("insert", [next])
        case 15:
            guard pids.count > 2 else { return ("delete (skipped)", []) }
            next.rows[p] = nil
            return ("delete", [next])
        case 16:
            next.rows[p]!.key = row.key + "r"
            return ("re-key", [next])
        default:
            guard let o = w.answers.keys.sorted().randomElement(using: &g) else { return ("result (skipped)", []) }
            next.answers[o]!.result = w.answers[o]!.result == .emailFound ? .contactFormOnly : .emailFound
            return ("answer result flips", [next])
        }
    }

    // T6

    static func t6World(size: Int, _ g: inout SeededGenerator) -> [Int: Phase0cEngagement.Source] {
        let titles = Array(F.titles.prefix(size <= 60 ? 3 : F.titles.count))
        var rows: [Int: Phase0cEngagement.Source] = [:]
        for i in 0..<size { rows[i] = t6Row(key: "e\(String(format: "%04d", i))", titles: titles, &g) }
        return rows
    }

    static func t6Row(key: String, titles: [String], _ g: inout SeededGenerator) -> Phase0cEngagement.Source {
        let title = F.pick(titles, &g)
        let spelled = F.chance(20, &g) ? title.uppercased() : (F.chance(10, &g) ? "\(title): A New Staging" : title)
        let day = Int(g.next() % 70)
        let runEnd: String? = F.chance(45, &g) ? nil
            : Phase0cProducers.dateString(day + Int(g.next() % 20) - (F.chance(5, &g) ? 3 : 0))
        let date: String? = F.chance(4, &g) ? nil : Phase0cProducers.dateString(day)
        let venue: String? = F.chance(3, &g) ? nil
            : F.venue(stem: F.pick(Array(F.stems.prefix(3)), &g), room: F.pick(F.rooms, &g), &g)
        return Phase0cEngagement.Source(key: key, groupName: spelled, venue: F.chance(10, &g) ? venue?.uppercased() : venue,
                                        date: date, runEnd: runEnd, drawn: F.chance(88, &g))
    }

    static func t6Step(_ w: [Int: Phase0cEngagement.Source], size: Int,
                       _ g: inout SeededGenerator) -> (kind: String, worlds: [[Int: Phase0cEngagement.Source]]) {
        let titles = Array(F.titles.prefix(size <= 60 ? 3 : F.titles.count))
        var next = w
        let pids = w.keys.sorted()
        let p = F.pick(pids, &g)
        let row = w[p]!
        var nextPid = (pids.last ?? 0) + 1
        func add(_ s: Phase0cEngagement.Source, _ into: inout [Int: Phase0cEngagement.Source]) {
            into[nextPid] = s
            nextPid += 1
        }
        switch g.next() % 13 {
        case 0:
            add(t6Row(key: "n\(nextPid)", titles: titles, &g), &next)
            return ("insert", [next])
        case 1:
            guard pids.count > 2 else { return ("delete (skipped)", []) }
            next[p] = nil
            return ("delete", [next])
        case 2:
            next[p]!.date = Phase0cProducers.dateString(Int(g.next() % 70))
            return ("date move", [next])
        case 3:
            next[p]!.runEnd = row.runEnd == nil ? Phase0cProducers.dateString(Int(g.next() % 90)) : nil
            return ("run end change", [next])
        case 4:
            next[p]!.venue = w[F.pick(pids, &g)]!.venue
            return ("venue change", [next])
        case 5:
            next[p]!.groupName = F.pick(titles, &g)
            return ("title change", [next])
        case 6:
            next[p]!.drawn.toggle()
            return (row.drawn ? "dismiss" : "undismiss", [next])
        case 7:
            next[p]!.key = row.key + "r"
            return ("re-key", [next])
        case 8:
            // Equal dates with different run ends, at a second venue.
            guard let d = row.date else { return ("equal dates (skipped)", []) }
            var twin = row
            twin.key = "n\(nextPid)"
            twin.runEnd = Phase0cProducers.dateString(Int(g.next() % 90))
            twin.venue = "Invented Twin Venue"
            twin.drawn = true
            twin.date = d
            add(twin, &next)
            return ("equal dates with different run ends", [next])
        case 9:
            // A short run nested inside a long one, then a row inside the long run's gap: rule (a) splits it
            // off (it is measured from the short run's end) and rule (b) keeps it.
            let title = F.pick(titles, &g)
            let d = Int(g.next() % 40)
            let long = Phase0cEngagement.Source(key: "n\(nextPid)", groupName: title, venue: "Invented Long House",
                                                date: Phase0cProducers.dateString(d), runEnd: Phase0cProducers.dateString(d + 20),
                                                drawn: true)
            add(long, &next)
            let short = Phase0cEngagement.Source(key: "n\(nextPid)", groupName: title, venue: "Invented Short Room",
                                                 date: Phase0cProducers.dateString(d + 1), runEnd: Phase0cProducers.dateString(d + 2),
                                                 drawn: true)
            add(short, &next)
            var third = next
            add(Phase0cEngagement.Source(key: "n\(nextPid)", groupName: title, venue: "Invented Third Stage",
                                         date: Phase0cProducers.dateString(d + 10), runEnd: nil, drawn: true), &third)
            return ("nested short run, then a row in the long run's gap", [next, third])
        case 10:
            // A gap break: the row moves far past every other night of its title.
            next[p]!.date = Phase0cProducers.dateString(200 + Int(g.next() % 10))
            next[p]!.runEnd = nil
            return ("gap break", [next])
        case 11:
            // One venue, then two: a sibling at the same title and night at another venue.
            var sib = row
            sib.key = "n\(nextPid)"
            sib.venue = row.venue == nil ? "Invented Other Venue" : nil
            sib.drawn = true
            add(sib, &next)
            return ("one venue to two", [next])
        default:
            next[p]!.groupName = row.groupName.uppercased() + " "
            return ("title respelled to the same key", [next])
        }
    }
}

/// One operation kind's samples over every real key. Each sample is an operation and its undo, timed
/// separately and reported separately. The slowest sample can be REPLAYED: the same key's operation and
/// undo re-timed five times. That separates a maximum set by the key (slow every time) from one set by
/// the machine (one interrupted sample on a Mac other agents are building on), without changing the
/// verdict, which is always scored on the raw maximum (L224: the replay is an attribution, not a retry).
final class Phase0cKind {
    typealias Run = () -> (doMs: Double, doWork: Int, undoMs: Double, undoWork: Int)
    let name: String
    private(set) var doTimes: [Double] = []
    private(set) var undoTimes: [Double] = []
    private(set) var work: [Int] = []
    private var slowest: (ms: Double, run: Run)? = nil

    init(_ name: String) { self.name = name }

    func sample(_ run: @escaping Run) {
        let r = run()
        doTimes.append(r.doMs)
        undoTimes.append(r.undoMs)
        work += [r.doWork, r.undoWork]
        let worst = max(r.doMs, r.undoMs)
        if worst > (slowest?.ms ?? -1) { slowest = (worst, run) }
    }

    var all: Phase0cProducers.Dist { Phase0cProducers.Dist(doTimes + undoTimes) }
    var worstMedian: Double { max(Phase0cProducers.Dist(doTimes).median, Phase0cProducers.Dist(undoTimes).median) }

    /// The slowest sample's key, re-timed five times; nil when there were no samples.
    func replayWorst() -> Phase0.Reading? {
        guard let slowest else { return nil }
        return Phase0.Reading(runs: (0..<5).map { _ in let r = slowest.run(); return max(r.doMs, r.undoMs) })
    }

    func lines(workLabel: String) -> [String] {
        let replay = replayWorst()
        return [
            Phase0cProducers.pad(name, 70),
            "      do    " + Phase0cProducers.Dist(doTimes).text,
            "      undo  " + Phase0cProducers.Dist(undoTimes).text,
            "      \(workLabel) " + Phase0cProducers.sizes(work)
                + (replay.map { "; slowest key re-timed five times " + $0.text } ?? ""),
        ]
    }
}

// MARK: - The suite

@MainActor
@Suite("#4106 Phase 0c probes 0c.3 and 0c.4 (ProducerTables, ledger, EngagementLink)")
struct QueueEnginePhase0cProducersProbeTests {
    typealias F = Phase0cProducers

    private let sandboxes = TemporarySandboxes()

    // MARK: - Property harnesses (run on every suite run; no store)

    @Test func t4ProducerTablesWitnessPatchMatchesTheOracle() {
        var failures: [String] = []
        for size in [60, 300] {
            var proto = Phase0cProducerTables(rows: [:], overrides: .none)
            // The previous transition's oracle outputs, so each transition builds today's tables once for its
            // ChangedKeys check; the no-prefilter brute force (presenters by venues) runs on the cold build,
            // at every eighth transition and at every undo, which is what keeps the harness inside its budget.
            var lastOutputs: [String: Phase0cProducerTables.Out] = [:]
            var transition = 0
            let started = Phase0.now()
            let run = F.drive(
                seeds: F.harness(size: size).seeds, ops: F.harness(size: size).ops, seedBase: UInt64(4106_300 + size),
                initial: { Phase0cFixtures.t4World(size: size, &$0) },
                cold: { w in
                    proto = Phase0cProducerTables(rows: w.shows, overrides: w.overrides)
                    lastOutputs = Phase0cT4Check.oracleOutputs(w.list, overrides: w.overrides)
                    return Phase0cT4Check.compare(proto, shows: w.list, overrides: w.overrides, brute: true)
                },
                step: { Phase0cFixtures.t4Step($0, size: size, &$1) },
                move: { old, new, at in
                    var changes: [(pid: Int, show: ProducerGate.Show?)] = []
                    for pid in Set(old.shows.keys).union(new.shows.keys) where old.shows[pid] != new.shows[pid] {
                        changes.append((pid, new.shows[pid]))
                    }
                    let changed = proto.apply(changes, overrides: new.overrides)
                    transition += 1
                    var bad = Phase0cT4Check.compare(proto, shows: new.list, overrides: new.overrides,
                                                     brute: transition % 8 == 0 || at.hasSuffix("undo"))
                    let newOutputs = Phase0cT4Check.oracleOutputs(new.list, overrides: new.overrides)
                    let real = Phase0cT4Check.changedKeys(lastOutputs, newOutputs)
                    lastOutputs = newOutputs
                    if real != changed {
                        bad.append("ChangedKeys: reported \(changed.count), real \(real.count), missing \(real.subtracting(changed).count)")
                    }
                    return bad.map { "\(at): \($0)" }
                })
            F.say("0c.3 harness [\(size) rows] \(run.transitions) transitions checked (every op and undo) in "
                  + String(format: "%.0f ms", Phase0.ms(since: started)) + ", failures \(run.failures.count); kinds "
                  + run.kinds.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))
            failures += run.failures.map { "[\(size)] \($0)" }
        }
        if !failures.isEmpty { F.say("0c.3 harness FAILURES\n  " + failures.prefix(30).joined(separator: "\n  ")) }
        #expect(failures.isEmpty, "0c.3: the witness-count ProducerTables prototype disagreed with today's code or the brute force")
    }

    @Test func t5LedgerPatchMatchesTheOracle() {
        var failures: [String] = []
        for size in [60, 300] {
            var proto = Phase0cLedger(Phase0cLedger.World(rows: [:], answers: [:], refusals: [], held: [],
                                                         overrides: .none, now: Date(timeIntervalSince1970: 0), nextPid: 0))
            var sevenA = 0
            var inheritedSeen = 0
            var lastBrute: [String: OrgAnswerLedger.Inherited] = [:]
            let started = Phase0.now()
            let run = F.drive(
                seeds: F.harness(size: size).seeds, ops: F.harness(size: size).ops, seedBase: UInt64(4106_400 + size),
                initial: { Phase0cFixtures.t5World(size: size, &$0) },
                cold: { w in
                    proto = Phase0cLedger(w)
                    lastBrute = Phase0cT5Check.brute(w)
                    let r = Phase0cT5Check.compare(proto, w, brute: lastBrute)
                    sevenA += r.sevenA
                    return r.bad
                },
                step: { Phase0cFixtures.t5Step($0, size: size, &$1) },
                move: { old, new, at in
                    let before = lastBrute
                    let changed = proto.apply(Phase0cLedger.Changes.diff(from: old, to: new))
                    let after = Phase0cT5Check.brute(new)
                    lastBrute = after
                    let r = Phase0cT5Check.compare(proto, new, brute: after)
                    sevenA += r.sevenA
                    var bad = r.bad
                    inheritedSeen += after.count
                    // ChangedKeys, by natural key: every row whose answer really changed must be reported.
                    let keyOf = { (pid: Int) -> String? in new.rows[pid]?.key ?? old.rows[pid]?.key }
                    let reported = Set(changed.compactMap(keyOf))
                    let realKeys = Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }
                    let rekeyed = Set(old.rows.keys).intersection(new.rows.keys).filter { old.rows[$0]!.key != new.rows[$0]!.key }
                    if rekeyed.isEmpty && !realKeys.isSubset(of: reported) {
                        bad.append("ChangedKeys missed \(realKeys.subtracting(reported).count) rows")
                    }
                    return bad.map { "\(at): \($0)" }
                })
            F.say("0c.4 T5 harness [\(size) rows] \(run.transitions) transitions checked in "
                  + String(format: "%.0f ms", Phase0.ms(since: started)) + ", failures \(run.failures.count), "
                  + "rows where decision 7(a) differs from today's memo \(sevenA), inherited answers seen \(inheritedSeen); kinds "
                  + run.kinds.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))
            failures += run.failures.map { "[\(size)] \($0)" }
        }
        if !failures.isEmpty { F.say("0c.4 T5 harness FAILURES\n  " + failures.prefix(30).joined(separator: "\n  ")) }
        #expect(failures.isEmpty, "0c.4: the ledger prototype disagreed with today's canonical oracle or the 7(a) brute force")
    }

    @Test func t6EngagementPatchMatchesBothRules() {
        var failures: [String] = []
        for rule in Phase0cEngagement.Rule.allCases {
            for size in [60, 300] {
                var proto = Phase0cEngagement(rule: rule, rows: [:])
                var differsBetweenRules = 0
                let started = Phase0.now()
                let run = F.drive(
                    seeds: F.harness(size: size).seeds, ops: F.harness(size: size).ops, seedBase: UInt64(4106_600 + size),
                    initial: { Phase0cFixtures.t6World(size: size, &$0) },
                    cold: { w in
                        proto = Phase0cEngagement(rule: rule, rows: w.mapValues(Phase0cEngagement.slice))
                        return Phase0cT6Check.compare(proto, Phase0cT6Check.truth(rule, Phase0cT6Check.drawnRows(w)))
                    },
                    step: { Phase0cFixtures.t6Step($0, size: size, &$1) },
                    move: { old, new, at in
                        var changes: [(pid: Int, slice: Phase0cEngagement.Slice?)] = []
                        for pid in Set(old.keys).union(new.keys) where old[pid] != new[pid] {
                            changes.append((pid, new[pid].map(Phase0cEngagement.slice)))
                        }
                        let before = proto.out
                        let changed = proto.apply(changes)
                        let want = Phase0cT6Check.truth(rule, Phase0cT6Check.drawnRows(new))
                        var bad = Phase0cT6Check.compare(proto, want)
                        let real = Set(before.keys).union(proto.out.keys).filter { before[$0] != proto.out[$0] }
                        if real != changed { bad.append("ChangedKeys: reported \(changed.count), real \(real.count)") }
                        let other: Phase0cEngagement.Rule = rule == .lastAppended ? .clusterLatest : .lastAppended
                        let theirs = Phase0cT6Check.truth(other, Phase0cT6Check.drawnRows(new))
                        differsBetweenRules += Set(want.keys).union(theirs.keys).filter { want[$0] != theirs[$0] }.count
                        return bad.map { "\(at): \($0)" }
                    },
                    end: { w, at in
                        // The canonical oracle is order independent: reversed input gives the same answer.
                        let rows = Phase0cT6Check.drawnRows(w)
                        return Phase0cT6Check.truth(rule, rows) == Phase0cT6Check.truth(rule, rows.reversed())
                            ? [] : ["\(at): the \(rule.rawValue) truth depends on input order"]
                    })
                F.say("0c.4 T6 harness \(rule.rawValue) [\(size) rows] \(run.transitions) transitions checked in "
                      + String(format: "%.0f ms", Phase0.ms(since: started)) + ", failures \(run.failures.count), "
                      + "row-steps where the two rules' outputs differ \(differsBetweenRules); kinds "
                      + run.kinds.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))
                failures += run.failures.map { "\(rule.rawValue) [\(size)] \($0)" }
            }
        }
        if !failures.isEmpty { F.say("0c.4 T6 harness FAILURES\n  " + failures.prefix(30).joined(separator: "\n  ")) }
        #expect(failures.isEmpty, "0c.4: the EngagementLink prototype disagreed with its rule's oracle")
    }

    // MARK: - Cost over every real key (opt in, live store clone and its fourfold copy)

    private func skip(_ probe: String) -> Bool {
        guard F.enabled else {
            print("phase0c-producers \(probe): not measured. Set TEST_RUNNER_MEASURE_4106_PHASE0C_PRODUCERS=1 to run it.")
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

    private func overrides(_ ctx: ModelContext) throws -> ProducerOverrides {
        ProducerOverrides(promotedRows: try ctx.fetch(FetchDescriptor<PromotedProducer>()),
                          demotedRows: try ctx.fetch(FetchDescriptor<DemotedHouse>()))
    }

    @Test(.enabled(if: Phase0.liveStoreExists, "no live store on this machine"))
    func probe0c3ProducerTablesEveryVenueKey() throws {
        if skip("0c.3") { return }
        var verdicts: [String] = []
        var failures: [String] = []
        for (label, url) in try corpora("phase0c-3") {
            let ctx = ModelContext(try Phase0.openContainer(at: url))
            let prospects = try ctx.fetch(FetchDescriptor<Prospect>())
            let current = try overrides(ctx)
            var world: [Int: ProducerGate.Show] = [:]
            for (i, p) in prospects.enumerated() { world[i] = ProducerGate.Show(presenter: p.presenter, venue: p.venue) }
            let list = { (w: [Int: ProducerGate.Show]) in w.keys.sorted().map { w[$0]! } }
            let showList = list(world)

            // The cold arm, interleaved with today's build so both see the same machine (L224, L356).
            var todayCold: [Double] = [], protoCold: [Double] = []
            var proto = Phase0cProducerTables(rows: [:], overrides: current)
            for _ in 0..<5 {
                todayCold.append(Phase0.time { _ = QueueModel.ProducerTables(shows: showList, overrides: current) })
                protoCold.append(Phase0.time { proto = Phase0cProducerTables(rows: world, overrides: current) })
            }
            let coldTests = proto.lastTests
            let today = Phase0b.reading(todayCold), cold = Phase0b.reading(protoCold)
            var mismatches = Phase0cT4Check.compare(proto, shows: showList, overrides: current, brute: true)
            let witnessPresenters = proto.witnesses.count
            let witnessPairs = proto.witnesses.values.reduce(0) { $0 + $1.count }

            // One change applied and undone, each timed, with the presenter-against-venue tests it made.
            func pair(_ doIt: [(pid: Int, show: ProducerGate.Show?)], _ doOverrides: ProducerOverrides,
                      _ undo: [(pid: Int, show: ProducerGate.Show?)], _ undoOverrides: ProducerOverrides)
                -> (doMs: Double, doWork: Int, undoMs: Double, undoWork: Int) {
                let a = Phase0.time { proto.apply(doIt, overrides: doOverrides) }
                let at = proto.lastTests
                let b = Phase0.time { proto.apply(undo, overrides: undoOverrides) }
                return (a, at, b, proto.lastTests)
            }

            var kinds: [Phase0cKind] = []
            var pidsByVenue: [String: [Int]] = [:]
            for (pid, pair) in proto.pairs { if let v = pair.vk { pidsByVenue[v, default: []].append(pid) } }
            let venueKeys = pidsByVenue.keys.sorted()
            let stride = max(1, venueKeys.count / 12)

            // Every real venue key LEAVES (every row at it deleted in one change) and APPEARS again (the
            // rows restored). Checked against the oracle at a stride, while the key is absent, and at the end.
            let leaves = Phase0cKind("every venue key leaves (all its rows deleted), then appears again")
            for (i, v) in venueKeys.enumerated() {
                let pids = pidsByVenue[v]!
                let removed = pids.map { (pid: $0, show: ProducerGate.Show?.none) }
                let restored = pids.map { (pid: $0, show: world[$0]) }
                if i % stride == 0 {
                    proto.apply(removed, overrides: current)
                    var without = world
                    for p in pids { without[p] = nil }
                    mismatches += Phase0cT4Check.compare(proto, shows: list(without), overrides: current, brute: false)
                        .map { "after removing venue \(F.hash8(v)): \($0)" }
                    proto.apply(restored, overrides: current)
                }
                leaves.sample { pair(removed, current, restored, current) }
            }
            kinds.append(leaves)

            // 0b.1's tail kind, for every presenter key: one row's venue edited to '<presenter> Theatre'.
            var firstPidOf: [String: Int] = [:]
            for pid in world.keys.sorted() { if let pk = proto.pairs[pid]?.pk, firstPidOf[pk] == nil { firstPidOf[pk] = pid } }
            let theatre = Phase0cKind("every presenter: one row's venue edited to '<presenter> Theatre', and back")
            for (pk, pid) in firstPidOf.sorted(by: { $0.key < $1.key }) {
                let old = world[pid]!
                let edited = ProducerGate.Show(presenter: old.presenter, venue: "\(old.presenter ?? pk) Theatre")
                theatre.sample { pair([(pid, edited)], current, [(pid, old)], current) }
            }
            kinds.append(theatre)

            // Every venue key spelled as a new row's presenter (a presenter key that is also a venue key).
            let newPid = (world.keys.max() ?? 0) + 1
            let asVenue = Phase0cKind("every venue key as a new row's presenter, added and removed")
            for v in venueKeys {
                let raw = world[pidsByVenue[v]![0]]!.venue
                asVenue.sample { pair([(newPid, ProducerGate.Show(presenter: raw, venue: nil))], current, [(newPid, nil)], current) }
            }
            kinds.append(asVenue)

            // Every presenter at exactly one venue with two or more rows: one row moved to a second venue.
            var byPresenter: [String: [Int]] = [:]
            for (pid, pair) in proto.pairs { if let pk = pair.pk { byPresenter[pk, default: []].append(pid) } }
            let commonest = pidsByVenue.max { $0.value.count != $1.value.count ? $0.value.count < $1.value.count : $0.key > $1.key }!
            let secondVenue = world[commonest.value[0]]!.venue
            let oneToTwo = Phase0cKind("every one-venue presenter: venue-only edit to a second venue, and back")
            for (pk, pids) in byPresenter.sorted(by: { $0.key < $1.key })
            where pids.count >= 2 && proto.distinctVenueCount(pk) == 1 {
                let pid = pids.min()!
                let old = world[pid]!
                oneToTwo.sample { pair([(pid, ProducerGate.Show(presenter: old.presenter, venue: secondVenue))], current, [(pid, old)], current) }
            }
            kinds.append(oneToTwo)

            // The adversarial venue (the corpus's six commonest venue words, weighted by rows), and one venue
            // key added and removed twenty times running.
            var freq: [String: Int] = [:]
            for v in venueKeys { for w in v.split(separator: " ") { freq[String(w), default: 0] += pidsByVenue[v]!.count } }
            let adversarial = freq.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .prefix(6).map(\.key).joined(separator: " ")
            let somePresenter = world[firstPidOf.values.min()!]!.presenter
            let adv = Phase0cKind("adversarial venue of the six commonest words, added and removed")
            for _ in 0..<5 {
                adv.sample { pair([(newPid, ProducerGate.Show(presenter: somePresenter, venue: adversarial))], current, [(newPid, nil)], current) }
            }
            kinds.append(adv)
            let repeated = Phase0cKind("one venue key added and removed twenty times running")
            for _ in 0..<20 {
                repeated.sample { pair([(newPid, ProducerGate.Show(presenter: somePresenter, venue: "Invented Room Number Seven"))], current, [(newPid, nil)], current) }
            }
            kinds.append(repeated)

            // Every presenter key promoted and put back.
            let promote = Phase0cKind("every presenter key promoted, and put back")
            for pk in firstPidOf.keys.sorted() {
                var next = current
                if next.promoted.contains(pk) { next.promoted.remove(pk) } else { next.promoted.insert(pk); next.demoted.remove(pk) }
                promote.sample { pair([], next, [], current) }
            }
            kinds.append(promote)

            var lines: [String] = []
            var worstMedian = 0.0, worstMax = 0.0, worstReplay = 0.0
            for k in kinds {
                worstMedian = max(worstMedian, k.worstMedian)
                worstMax = max(worstMax, k.all.max)
                lines += k.lines(workLabel: "presenter-against-venue tests")
                worstReplay = max(worstReplay, k.replayWorst()?.median ?? 0)
            }
            // Back where it started (every replay undoes itself), so the end state is checked whole.
            mismatches += Phase0cT4Check.compare(proto, shows: showList, overrides: current, brute: true).map { "end: \($0)" }

            let coldRatio = cold.median / max(today.median, 0.001)
            let pass = mismatches.isEmpty && worstMedian <= 5 && worstMax <= 25 && coldRatio <= 1.25
            F.say("""
                0c.3 [\(label)] \(showList.count) shows, \(proto.presenterKeys.count) presenter keys, \(venueKeys.count) venue keys, \(proto.brand.count) brand keys, \(witnessPresenters) presenters with witnesses (\(witnessPairs) witness pairs), Debug build, \(Phase0.load())
                  noise floor: today's ProducerTables cold, five runs   \(today.text)
                  cold arm: prototype with complete witness sets        \(cold.text), \(coldTests) tests, ratio \(String(format: "%.2f", coldRatio)) (stop over 1.25)
                  \(lines.joined(separator: "\n  "))
                  mismatches against today's code and the brute force   \(mismatches.count)
                  worst per-kind median \(String(format: "%.3f", worstMedian)) ms (stop over 5), max \(String(format: "%.3f", worstMax)) ms (stop over 25); worst slowest-key replay median \(String(format: "%.3f", worstReplay)) ms; \(Phase0.load())
                  0c.3 [\(label)] \(pass ? "PASS" : "FAIL")
                """)
            verdicts.append("\(label) \(pass ? "PASS" : "FAIL") (worst median \(String(format: "%.3f", worstMedian)) ms, max \(String(format: "%.3f", worstMax)) ms, slowest key replayed \(String(format: "%.3f", worstReplay)) ms, cold ratio \(String(format: "%.2f", coldRatio)), mismatches \(mismatches.count))")
            failures += mismatches.map { "\(label) \($0)" }
        }
        F.say("0c.3 verdict: " + verdicts.joined(separator: "; "))
        if !failures.isEmpty { F.say("0c.3 MISMATCHES\n  " + failures.prefix(30).joined(separator: "\n  ")) }
        #expect(failures.isEmpty, "0c.3: the prototype disagreed with today's ProducerTables on the clone")
    }

    @Test(.enabled(if: Phase0.liveStoreExists, "no live store on this machine"))
    func probe0c4LedgerAndEngagementEveryRealKey() throws {
        if skip("0c.4") { return }
        var verdicts: [String] = []
        var failures: [String] = []
        for (label, url) in try corpora("phase0c-4") {
            let ctx = ModelContext(try Phase0.openContainer(at: url))
            let prospects = try ctx.fetch(FetchDescriptor<Prospect>())
            let answerRows = try ctx.fetch(FetchDescriptor<OrgReachabilityAnswer>())
            let refusalRows = try ctx.fetch(FetchDescriptor<RefusedContactAddress>())
            let current = try overrides(ctx)
            let now = Date()

            // T5: the world, extracted once.
            var rows: [Int: Phase0cLedger.Row] = [:]
            for (i, p) in prospects.enumerated() {
                rows[i] = Phase0cLedger.Row(key: p.naturalKey, presenter: p.presenter, venue: p.venue,
                                            ownAnswer: p.reachabilityProbedAt != nil)
            }
            var answers: [String: Phase0cLedger.Answer] = [:]
            var unreadable = 0
            for a in answerRows {
                guard let result = a.result else { unreadable += 1; continue }
                answers[a.orgKey] = Phase0cLedger.Answer(result: result, probedAt: a.probedAt,
                                                         presenterName: a.presenterName, emails: a.foundEmails)
            }
            let refusals = Set(refusalRows.map { ContactRefusal.Ledger.Row(scopeRaw: $0.scopeRaw, scopeId: $0.scopeId, handleKey: $0.handleKey) })
            var world = Phase0cLedger.World(rows: rows, answers: answers, refusals: refusals, held: [],
                                            overrides: current, now: now, nextPid: prospects.count)
            let ledgerRefusals = ContactRefusal.ledger(from: refusalRows)
            let floor = Phase0.median5 {
                _ = CanonicalOracle.inheritedAnswers(answerRows, corpus: prospects, overrides: current,
                                                     refusals: ledgerRefusals, heldKeys: [], now: now)
            }
            let onModels = CanonicalOracle.inheritedAnswers(answerRows, corpus: prospects, overrides: current,
                                                            refusals: ledgerRefusals, heldKeys: [], now: now)
            let coldT = Phase0.median5 { _ = Phase0cLedger(world) }
            var proto = Phase0cLedger(world)
            var mismatches: [String] = []
            if Phase0cT5Check.oracle(world) != onModels { mismatches.append("the extracted world's oracle differs from the oracle on the store's own rows") }
            let first = Phase0cT5Check.compare(proto, world)
            mismatches += first.bad
            let sevenAAtStart = first.sevenA

            // The shape plan section 7 asks for: every orgKey group's size, every presenter key's fan-out.
            let groupSizes = proto.byOrg.values.map(\.count)
            var orgsByProducer: [String: Set<String>] = [:]
            var producersByOrg: [String: Set<String>] = [:]
            for s in proto.slices.values {
                guard let pk = s.producerKey, let o = s.orgKey else { continue }
                orgsByProducer[pk, default: []].insert(o)
                producersByOrg[o, default: []].insert(pk)
            }
            let fanOut = orgsByProducer.values.map(\.count)
            let orgsWithTwoProducers = producersByOrg.values.filter { $0.count > 1 }.count

            var checks = 0
            func check(_ at: String) {
                checks += 1
                mismatches += Phase0cT5Check.compare(proto, world).bad.map { "\(at): \($0)" }
            }
            func pair(_ doIt: Phase0cLedger.Changes, _ undo: Phase0cLedger.Changes)
                -> (doMs: Double, doWork: Int, undoMs: Double, undoWork: Int) {
                let a = Phase0.time { proto.apply(doIt) }
                let an = proto.lastReevaluated
                let b = Phase0.time { proto.apply(undo) }
                return (a, an, b, proto.lastReevaluated)
            }
            var kinds: [Phase0cKind] = []

            // Every orgKey: an answer arrives where there is none, or the stored one is removed; then undone.
            let orgs = proto.byOrg.keys.sorted()
            let stride = max(1, orgs.count / 8)
            let orgKind = Phase0cKind("every orgKey: an answer arrives or is removed, and back")
            for (i, o) in orgs.enumerated() {
                let old = world.answers[o]
                let new: Phase0cLedger.Answer? = old == nil
                    ? Phase0cLedger.Answer(result: .emailFound, probedAt: now.addingTimeInterval(-86_400),
                                           presenterName: "Invented Org", emails: ["booking@invented.example"])
                    : nil
                if i % stride == 0 {
                    proto.apply(Phase0cLedger.Changes(answers: [(o, new)]))
                    world.answers[o] = new
                    check("orgKey \(F.hash8(o)) answer toggled")
                    world.answers[o] = old
                    proto.apply(Phase0cLedger.Changes(answers: [(o, old)]))
                }
                orgKind.sample { pair(Phase0cLedger.Changes(answers: [(o, new)]), Phase0cLedger.Changes(answers: [(o, old)])) }
            }
            kinds.append(orgKind)

            // Every presenter key: promoted and put back (T4's verdict reaching T5's rows).
            let producers = proto.byProducer.keys.sorted()
            let pStride = max(1, producers.count / 8)
            let promoteKind = Phase0cKind("every presenter key promoted, and put back")
            for (i, pk) in producers.enumerated() {
                var next = current
                if next.promoted.contains(pk) { next.promoted.remove(pk) } else { next.promoted.insert(pk); next.demoted.remove(pk) }
                if i % pStride == 0 {
                    proto.apply(Phase0cLedger.Changes(overrides: next))
                    world.overrides = next
                    check("presenter \(F.hash8(pk)) promoted")
                    world.overrides = current
                    proto.apply(Phase0cLedger.Changes(overrides: current))
                }
                promoteKind.sample { pair(Phase0cLedger.Changes(overrides: next), Phase0cLedger.Changes(overrides: current)) }
            }
            kinds.append(promoteKind)

            // Every presenter key: one row's venue edited to a venue key nobody has, and back (a venue-only
            // edit moving the presenter's count, the hand-off from T4 to T5).
            let venueKind = Phase0cKind("every presenter key: a venue-only edit to a new venue, and back")
            for (i, pk) in producers.enumerated() {
                let pid = proto.byProducer[pk]!.min()!
                let old = world.rows[pid]!
                var edited = old
                edited.venue = "Invented Room \(i)"
                if i % pStride == 0 {
                    proto.apply(Phase0cLedger.Changes(rows: [(pid, edited)]))
                    world.rows[pid] = edited
                    check("presenter \(F.hash8(pk)) venue edit")
                    world.rows[pid] = old
                    proto.apply(Phase0cLedger.Changes(rows: [(pid, old)]))
                }
                venueKind.sample { pair(Phase0cLedger.Changes(rows: [(pid, edited)]), Phase0cLedger.Changes(rows: [(pid, old)])) }
            }
            kinds.append(venueKind)

            // Every answer with an address: its first address struck, then lifted.
            let strikeKind = Phase0cKind("every answer: its first address struck, then lifted")
            for o in world.answers.keys.sorted() {
                guard let e = world.answers[o]!.emails.first, let h = ContactRefusal.key(for: e) else { continue }
                let r = ContactRefusal.Ledger.Row(scopeRaw: ContactRefusal.Scope.organisationRaw, scopeId: o, handleKey: h)
                guard !world.refusals.contains(r) else { continue }
                strikeKind.sample { pair(Phase0cLedger.Changes(struck: [r]), Phase0cLedger.Changes(lifted: [r])) }
            }
            kinds.append(strikeKind)

            // Every row: held and released.
            let heldKind = Phase0cKind("every row held, and released")
            for r in world.rows.values.sorted(by: { $0.key < $1.key }) {
                heldKind.sample { pair(Phase0cLedger.Changes(heldAdded: [r.key]), Phase0cLedger.Changes(heldRemoved: [r.key])) }
            }
            kinds.append(heldKind)

            // The clock: past every answer's expiry in turn, then back.
            let clockKind = Phase0cKind("the clock moved past each answer's expiry, and back")
            for a in world.answers.values.sorted(by: { $0.probedAt < $1.probedAt }) {
                let t = a.probedAt.addingTimeInterval(Reachability.probeFreshness + 60)
                clockKind.sample { pair(Phase0cLedger.Changes(now: t), Phase0cLedger.Changes(now: now)) }
            }
            kinds.append(clockKind)

            var lines: [String] = []
            var worstMax = 0.0, worstReplay = 0.0
            for k in kinds {
                worstMax = max(worstMax, k.all.max)
                lines += k.lines(workLabel: "rows re-judged")
                worstReplay = max(worstReplay, k.replayWorst()?.median ?? 0)
            }
            check("end")
            let t5Pass = mismatches.isEmpty && worstMax <= 5
            F.say("""
                0c.4 T5 [\(label)] \(prospects.count) shows, \(answerRows.count) answers (\(unreadable) unreadable), \(refusalRows.count) refusals, \(proto.usable.values.count) usable, \(proto.inherited.values.count) rows inheriting, Debug build, \(Phase0.load())
                  noise floor: today's inheritedAnswers (canonical wrapper), five runs   \(floor.text)
                  prototype cold build                                                  \(coldT.text)
                  orgKey group sizes                                                    \(F.sizes(groupSizes))
                  presenter key to orgKey fan-out                                       \(F.sizes(fanOut)), keys reaching two or more orgKeys \(fanOut.filter { $0 > 1 }.count)
                  orgKeys holding two or more presenter keys                            \(orgsWithTwoProducers); rows where decision 7(a) differs from today \(sevenAAtStart)
                  \(lines.joined(separator: "\n  "))
                  oracle checks \(checks + 1), mismatches \(mismatches.count), max \(String(format: "%.3f", worstMax)) ms (stop over 5); worst slowest-key replay median \(String(format: "%.3f", worstReplay)) ms; \(Phase0.load())
                  0c.4 T5 [\(label)] \(t5Pass ? "PASS" : "FAIL")
                """)
            failures += mismatches.map { "\(label) T5 \($0)" }
            let t5Replay = worstReplay

            // T6: EngagementLink over drawn rows, both rules.
            var sources: [Int: Phase0cEngagement.Source] = [:]
            for (i, p) in prospects.enumerated() {
                sources[i] = Phase0cEngagement.Source(key: p.naturalKey, groupName: p.groupName, venue: p.venue,
                                                      date: p.performanceDate, runEnd: p.runEndDate,
                                                      drawn: p.statusRaw != "dismissed")
            }
            let drawn = Phase0cT6Check.drawnRows(sources)
            let t6Floor = Phase0.median5 { _ = CanonicalOracle.engagementLink(drawn) }
            let slices = sources.mapValues(Phase0cEngagement.slice)
            var t6Lines: [String] = []
            var t6Worst = 0.0, t6Replay = 0.0
            var t6Bad: [String] = []
            var protos: [Phase0cEngagement.Rule: Phase0cEngagement] = [:]
            for rule in Phase0cEngagement.Rule.allCases {
                let cold = Phase0.median5 { _ = Phase0cEngagement(rule: rule, rows: slices) }
                var e = Phase0cEngagement(rule: rule, rows: slices)
                let want = Phase0cT6Check.truth(rule, drawn)
                t6Bad += Phase0cT6Check.compare(e, want).map { "\(rule.rawValue) cold: \($0)" }
                // Every title group: its first member (by natural key) dismissed, then undismissed.
                let kind = Phase0cKind("\(rule.rawValue): every title group, a member dismissed and back")
                let titles = e.byTitle.keys.sorted()
                let tStride = max(1, titles.count / 8)
                for (i, t) in titles.enumerated() {
                    let pid = e.byTitle[t]!.min { sources[$0]!.key < sources[$1]!.key }!
                    var dismissed = sources[pid]!
                    dismissed.drawn = false
                    let off = Phase0cEngagement.slice(dismissed), on = slices[pid]!
                    if i % tStride == 0 {
                        e.apply([(pid, off)])
                        var w = sources
                        w[pid] = dismissed
                        t6Bad += Phase0cT6Check.compare(e, Phase0cT6Check.truth(rule, Phase0cT6Check.drawnRows(w)))
                            .map { "\(rule.rawValue) title \(F.hash8(t)) dismissed: \($0)" }
                        e.apply([(pid, on)])
                    }
                    kind.sample {
                        let a = Phase0.time { e.apply([(pid, off)]) }
                        let an = e.lastRebuilt
                        let b = Phase0.time { e.apply([(pid, on)]) }
                        return (a, an, b, e.lastRebuilt)
                    }
                }
                t6Worst = max(t6Worst, kind.all.max)
                t6Lines += kind.lines(workLabel: "rows re-clustered") + ["      cold build " + cold.text]
                t6Replay = max(t6Replay, kind.replayWorst()?.median ?? 0)
                t6Bad += Phase0cT6Check.compare(e, want).map { "\(rule.rawValue) end: \($0)" }
                protos[rule] = e
            }
            // Decision 18's count: drawn rows whose engagement differs between the two rules.
            let a = protos[.lastAppended]!, b = protos[.clusterLatest]!
            var groupOf: [Phase0cEngagement.Rule: [Int: Set<Int>]] = [:]
            for (rule, e) in protos {
                var g: [Int: Set<Int>] = [:]
                for t in e.byTitle.keys {
                    for cluster in e.clusters(t) {
                        let linked = Set(cluster.map { e.rows[$0]!.venueCanon }).count > 1
                        for pid in cluster { g[pid] = linked ? Set(cluster).subtracting([pid]) : [] }
                    }
                }
                groupOf[rule] = g
            }
            let membershipDiffers = Set(groupOf[.lastAppended]!.keys).union(groupOf[.clusterLatest]!.keys)
                .filter { (groupOf[.lastAppended]![$0] ?? []) != (groupOf[.clusterLatest]![$0] ?? []) }.count
            let outputDiffers = Set(a.out.keys).union(b.out.keys).filter { a.out[$0] != b.out[$0] }.count
            // Where the rule could matter at all: title clusters holding a row whose last night lies before
            // an EARLIER-appended row's last night (a nested run).
            var nestedClusters = 0
            for t in b.byTitle.keys {
                for cluster in b.clusters(t) where cluster.count > 1 {
                    var latest = Int.min
                    var nested = false
                    for pid in cluster {
                        let l = b.rows[pid]!.lastOrd ?? Int.min
                        if l < latest { nested = true }
                        latest = max(latest, l)
                    }
                    if nested { nestedClusters += 1 }
                }
            }
            let titleSizes = a.byTitle.values.map(\.count)
            let t6Pass = t6Bad.isEmpty && t6Worst <= 5
            F.say("""
                0c.4 T6 [\(label)] \(drawn.count) drawn rows, \(a.byTitle.count) title groups (\(F.sizes(titleSizes))), linked under (a) \(a.out.count), under (b) \(b.out.count), Debug build, \(Phase0.load())
                  noise floor: today's EngagementLink.group (canonical wrapper), five runs   \(t6Floor.text)
                  \(t6Lines.joined(separator: "\n  "))
                  DECISION 18: drawn rows whose engagement membership differs between (a) and (b) \(membershipDiffers); rows whose linked-engagement output differs \(outputDiffers); rule (b) clusters holding a nested run \(nestedClusters)
                  mismatches \(t6Bad.count), max \(String(format: "%.3f", t6Worst)) ms (stop over 5); worst slowest-key replay median \(String(format: "%.3f", t6Replay)) ms; \(Phase0.load())
                  0c.4 T6 [\(label)] \(t6Pass ? "PASS" : "FAIL")
                """)
            failures += t6Bad.map { "\(label) T6 \($0)" }
            verdicts.append("\(label) T5 \(t5Pass ? "PASS" : "FAIL") (max \(String(format: "%.3f", worstMax)) ms, slowest key replayed \(String(format: "%.3f", t5Replay)) ms, mismatches \(mismatches.count)), T6 \(t6Pass ? "PASS" : "FAIL") (max \(String(format: "%.3f", t6Worst)) ms, slowest key replayed \(String(format: "%.3f", t6Replay)) ms, mismatches \(t6Bad.count), decision 18 membership differs on \(membershipDiffers))")
        }
        F.say("0c.4 verdict: " + verdicts.joined(separator: "; "))
        if !failures.isEmpty { F.say("0c.4 MISMATCHES\n  " + failures.prefix(30).joined(separator: "\n  ")) }
        #expect(failures.isEmpty, "0c.4: a prototype disagreed with its oracle on the clone")
    }
}
