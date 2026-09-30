import Testing
import Foundation
import SwiftData

// #4106 Phase 0b: the probes plan v5 lists (section 6), each with its stop rule, read by Gate 0b.
//
// MEASUREMENT ONLY, and the same contract as Phase 0's probes beside it (`QueueEnginePhase0ProbeTests`):
// every probe reads a throwaway `LiveStoreClone` copy of the live store, the fourfold copy built from it by
// `Phase0.scaledCopy`, or a scratch store of its own. Nothing in the app changes. Each probe is OPT IN, for
// the same two reasons (it clones Dan's store, and a stopwatch on a shared Mac measures the Mac, L224), and
// says it did not run rather than passing silently when the variable is absent (L98):
//
//   TEST_RUNNER_MEASURE_4106_PHASE0B=1 mac/scripts/run-tests-locked.sh \
//     -only-testing:OvertureTests/QueueEnginePhase0bProbeTests
//
// PRIVACY. Counts, durations, field names and 8 hex digit hashes only: never a show name, a presenter, a
// venue, an address or a URL (L222).
//
// Timings are medians of five with their spread, in the Debug build the runner builds (the build every
// earlier #4106 figure was taken in), with the load average printed beside each block (L356). Where a
// probe needs code the plan has not built yet (the value pass, TimeProbe, ContextReader, the Phase 1a
// scout guard), it says UNMEASURED and why, or measures a stand-in and names it as one.

enum Phase0b {
    nonisolated static var enabled: Bool {
        ProcessInfo.processInfo.environment["MEASURE_4106_PHASE0B"] != nil
    }

    nonisolated static func say(_ line: String) { print("phase0b " + line) }

    nonisolated static func pad(_ s: String, _ n: Int) -> String {
        s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
    }

    /// A stable 8 hex digit name for a string (FNV-1a), so a finding can be pointed at without printing it.
    nonisolated static func hash8(_ s: String) -> String {
        var h: UInt32 = 2_166_136_261
        for b in s.utf8 { h = (h ^ UInt32(b)) &* 16_777_619 }
        return String(format: "%08x", h)
    }

    /// A seeded generator, so every sample picks the same targets on every run.
    struct Rand: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    nonisolated static func reading(_ runs: [Double]) -> Phase0.Reading {
        Phase0.Reading(runs: runs.isEmpty ? [0] : runs)
    }

    /// The containment-preserving fourfold variant of a list of (presenter, venue) pairs (plan v5 D3).
    ///
    /// NOT the variant the plan names ("copy marker as a whole word after any leading article"), and the
    /// difference is deliberate: a marker shared by every name of a copy is one WORD every one of them holds,
    /// which puts all of them in one bucket of the word index and turns `isVenueBrand` into the cross product.
    /// That is exactly the corpus defect Phase 0 had to correct (the " x1" copy read ProducerTables at
    /// 1,498.6 ms). This glues the copy's marker onto EVERY word of five or more characters instead, so a
    /// name maps word for word within its copy: containment between two names of one copy is preserved, no
    /// word is shared across a copy that the clone did not already share, and the short words (the street
    /// suffixes `fold` rewrites, "of", "at", a leading "the") are left as the clone has them.
    nonisolated static func containmentCopy(_ raw: String?, copy: Int) -> String? {
        guard let raw else { return nil }
        let glue = "q" + String(UnicodeScalar(UInt8(96 + copy)))
        let tokens = raw.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        return tokens.map { token -> String in
            let letters = token.filter { $0.isLetter || $0.isNumber }.count
            guard letters >= 5, let last = token.lastIndex(where: { $0.isLetter || $0.isNumber }) else {
                return token
            }
            var t = token
            t.insert(contentsOf: glue, at: t.index(after: last))
            return t
        }.joined(separator: " ")
    }
}

// MARK: - 0b.1's prototype: ProducerTables patched in place

/// A TEST-ONLY prototype of plan v5 D3's `PatchableProducerTables`, built to measure what a patch costs and
/// whether it can agree with today's code. It is not the product type (Phase 3 builds that), and it restates
/// `isVenueBrand`'s three arms from ProducerGate's public pieces (`key`, `containsAsWords`) because the rule's
/// own helper is private. Its answers are compared against today's `QueueModel.ProducerTables` AND a brute
/// force over the definition with no word prefilter, so a word-splitting fault in the prototype shows in both.
struct Phase0bPatchTables {
    var overrides: ProducerOverrides
    var presenterRef: [String: Int] = [:]
    var venueRef: [String: Int] = [:]
    var venuesByPresenter: [String: [String: Int]] = [:]
    var venueWords: [String: Set<String>] = [:]
    var presenterWords: [String: Set<String>] = [:]
    var brand: Set<String> = []
    var room: Set<String> = []

    init(shows: [ProducerGate.Show], overrides: ProducerOverrides) {
        self.overrides = overrides
        _ = patch(remove: [], add: shows, overrides: overrides, evaluateAll: true)
    }

    private static func words(_ key: String) -> [String] { key.split(separator: " ").map(String.init) }

    func isBrand(_ p: String) -> Bool {
        if venueRef[p] != nil { return true }
        if overrides.demoted.contains(p) { return true }
        if overrides.promoted.contains(p) { return false }
        var candidates = Set<String>()
        for w in Self.words(p) { if let hits = venueWords[w] { candidates.formUnion(hits) } }
        return candidates.contains { ProducerGate.containsAsWords(p, $0) || ProducerGate.containsAsWords($0, p) }
    }

    func distinctVenueCount(_ p: String) -> Int { venuesByPresenter[p]?.count ?? 0 }

    func qualifies(_ p: String) -> Bool {
        guard !brand.contains(p) else { return false }
        return overrides.promoted.contains(p) || distinctVenueCount(p) >= 2
    }

    /// Applies the removed and added shows and the new overrides; returns how many presenter keys were
    /// re-asked `isVenueBrand` and which keys changed verdict or venue count.
    @discardableResult
    mutating func patch(remove: [ProducerGate.Show], add: [ProducerGate.Show], overrides new: ProducerOverrides,
                        evaluateAll: Bool = false) -> (reevaluated: Int, changed: Set<String>) {
        var touched = Set<String>()
        var changed = Set<String>()
        var venuesMoved = Set<String>()
        for s in remove {
            let vk = ProducerGate.key(s.venue)
            if let vk, let n = venueRef[vk] {
                if n <= 1 {
                    venueRef[vk] = nil
                    venuesMoved.insert(vk)
                    for w in Self.words(vk) {
                        venueWords[w]?.remove(vk)
                        if venueWords[w]?.isEmpty == true { venueWords[w] = nil }
                    }
                } else { venueRef[vk] = n - 1 }
            }
            guard let pk = ProducerGate.key(s.presenter), let pn = presenterRef[pk] else { continue }
            if let vk, let m = venuesByPresenter[pk]?[vk] {
                if m <= 1 { venuesByPresenter[pk]?[vk] = nil; changed.insert(pk) } else { venuesByPresenter[pk]?[vk] = m - 1 }
            }
            if pn <= 1 {
                presenterRef[pk] = nil
                venuesByPresenter[pk] = nil
                for w in Self.words(pk) {
                    presenterWords[w]?.remove(pk)
                    if presenterWords[w]?.isEmpty == true { presenterWords[w] = nil }
                }
                brand.remove(pk)
                room.remove(pk)
                changed.insert(pk)
            } else { presenterRef[pk] = pn - 1 }
        }
        for s in add {
            let vk = ProducerGate.key(s.venue)
            if let vk {
                if let n = venueRef[vk] { venueRef[vk] = n + 1 } else {
                    venueRef[vk] = 1
                    venuesMoved.insert(vk)
                    for w in Self.words(vk) { venueWords[w, default: []].insert(vk) }
                }
            }
            guard let pk = ProducerGate.key(s.presenter) else { continue }
            if let pn = presenterRef[pk] { presenterRef[pk] = pn + 1 } else {
                presenterRef[pk] = 1
                venuesByPresenter[pk] = [:]
                for w in Self.words(pk) { presenterWords[w, default: []].insert(pk) }
                touched.insert(pk)
                changed.insert(pk)
            }
            if let vk {
                let m = venuesByPresenter[pk]?[vk] ?? 0
                venuesByPresenter[pk]?[vk] = m + 1
                if m == 0 { changed.insert(pk) }
            }
        }
        touched.formUnion(overrides.promoted.symmetricDifference(new.promoted))
        touched.formUnion(overrides.demoted.symmetricDifference(new.demoted))
        overrides = new
        for v in venuesMoved {
            for w in Self.words(v) { if let hits = presenterWords[w] { touched.formUnion(hits) } }
        }
        let asked: [String] = evaluateAll ? Array(presenterRef.keys) : touched.filter { presenterRef[$0] != nil }
        for pk in asked {
            let isB = isBrand(pk)
            let wasB = brand.contains(pk)
            if isB { brand.insert(pk) } else { brand.remove(pk) }
            if isB && venueRef[pk] != nil { room.insert(pk) } else { room.remove(pk) }
            if isB != wasB { changed.insert(pk) }
        }
        return (asked.count, changed)
    }
}

/// The brute force over the definition: `isVenueBrand` asked against EVERY venue key, no word prefilter.
func phase0bBruteBrand(_ p: String, venueKeys: Set<String>, overrides: ProducerOverrides) -> Bool {
    if venueKeys.contains(p) { return true }
    if overrides.demoted.contains(p) { return true }
    if overrides.promoted.contains(p) { return false }
    return venueKeys.contains { ProducerGate.containsAsWords(p, $0) || ProducerGate.containsAsWords($0, p) }
}

/// Main thread turn lengths, measured from OFF the main thread: a dedicated thread posts a block to the main
/// queue, waits for it to run (bounded), and records how long it waited. A long wait is a long main turn.
final class Phase0bMainTurnMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var running = true
    private var waits: [Double] = []
    private var abandoned = 0

    func start() {
        let thread = Thread { [self] in
            while self.isRunning {
                let sem = DispatchSemaphore(value: 0)
                let t0 = Phase0.now()
                DispatchQueue.main.async {
                    self.record(Phase0.ms(since: t0))
                    sem.signal()
                }
                if sem.wait(timeout: .now() + 600) == .timedOut { self.markAbandoned() }
                usleep(1000)
            }
        }
        thread.name = "phase0b-main-turn-monitor"
        thread.start()
    }

    private var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    private func record(_ ms: Double) { lock.lock(); waits.append(ms); lock.unlock() }
    private func markAbandoned() { lock.lock(); abandoned += 1; lock.unlock() }

    func stop() -> (worst: Double, samples: Int, over16: Int, over100: Int, abandoned: Int) {
        lock.lock(); defer { lock.unlock() }
        running = false
        return (waits.max() ?? 0, waits.count, waits.filter { $0 > 16 }.count, waits.filter { $0 > 100 }.count,
                abandoned)
    }
}

/// One row's visible output from the queue pass: its row, its card, its stages and whether it is in Reached
/// out. Two instants, two contexts or two input orders are compared through this.
struct Phase0bRowSig: Equatable {
    let row: QueueScopeRow
    let card: QueueItem?
    let focuses: [StageFocus]
    let reachedOut: Bool
    let inAStage: Bool
}

struct Phase0bPassOut {
    let rows: [String: Phase0bRowSig]
    let rowOrder: [String]
    let global: [String: String]
}

@MainActor
@Suite("#4106 Phase 0b probes (opt in, live store clone)")
struct QueueEnginePhase0bProbeTests {

    private let sandboxes = TemporarySandboxes()

    private func skip(_ probe: String) -> Bool {
        guard Phase0b.enabled else {
            print("phase0b \(probe): not measured. Set TEST_RUNNER_MEASURE_4106_PHASE0B=1 to run it.")
            return true
        }
        return false
    }

    private func clone(_ name: String) throws -> URL {
        let dir = try sandboxes.make(named: name)
        guard let url = try LiveStoreClone.makeClone(in: dir) else {
            throw LiveStoreClone.Refusal.backupFailed("no live store on this machine")
        }
        return url
    }

    /// The clone and its fourfold copy, the same pair Phase 0 measured (the corrected corpus).
    private func corpora(_ name: String) throws -> [(label: String, url: URL)] {
        let dir = try sandboxes.make(named: name)
        guard let base = try LiveStoreClone.makeClone(in: dir) else {
            throw LiveStoreClone.Refusal.backupFailed("no live store on this machine")
        }
        return [("live clone", base), ("4x", try Phase0.scaledCopy(of: base, factor: 4, in: dir))]
    }

    private func scratchExport() throws -> URL {
        let dir = try sandboxes.make(named: "phase0b-export")
        let out = dir.appendingPathComponent("downbeat-export.json")
        if FileManager.default.fileExists(atPath: DownbeatBridge.defaultURL.path) {
            try FileManager.default.copyItem(at: DownbeatBridge.defaultURL, to: out)
        }
        return out
    }

    private func settle() async { try? await Task.sleep(for: .milliseconds(150)) }

    // MARK: - The pass inputs, as the app builds them, from one context

    private struct Tables {
        let rows: [Prospect]
        let inquiries: [Inquiry]
        let answers: [OrgReachabilityAnswer]
        let sources: [WatchedSource]
        let refusals: ContactRefusal.Ledger
        let overrides: ProducerOverrides
        let geo: GeoRefusals
        let clients: ClientWindow
    }

    private func tables(_ ctx: ModelContext, export: URL) throws -> Tables {
        let rows = try ctx.fetch(FetchDescriptor<Prospect>())
        for r in rows { _ = r.recipients.count }
        let sources = try ctx.fetch(FetchDescriptor<WatchedSource>())
        let clients = DownbeatBridge.loadWithHealth(from: export, now: Date()).clients
        return Tables(
            rows: rows,
            inquiries: try ctx.fetch(FetchDescriptor<Inquiry>()),
            answers: try ctx.fetch(FetchDescriptor<OrgReachabilityAnswer>()),
            sources: sources,
            refusals: ContactRefusal.ledger(from: try ctx.fetch(FetchDescriptor<RefusedContactAddress>())),
            overrides: ProducerOverrides(promotedRows: try ctx.fetch(FetchDescriptor<PromotedProducer>()),
                                         demotedRows: try ctx.fetch(FetchDescriptor<DemotedHouse>())),
            geo: GeoRefusals(userExcludedTowns: Set(try ctx.fetch(FetchDescriptor<ExcludedTown>()).map(\.town)),
                             allowedSeedTowns: Set(try ctx.fetch(FetchDescriptor<AllowedSeedTown>()).map(\.town))),
            clients: ClientWindow(sources: sources, clients: clients))
    }

    private func inputs(_ t: Tables, rows: [Prospect]? = nil, now: Date, cards: Set<String>?) -> QueueRenderPass.Inputs {
        QueueRenderPass.Inputs(
            allProspects: QueueRenderPass.Corpus(rows ?? t.rows), inquiries: t.inquiries, orgAnswers: t.answers,
            sources: t.sources, refusals: t.refusals, overrides: t.overrides,
            context: StageContext(now: now, geo: t.geo, clients: t.clients),
            focusedStage: .scout, focusedKeys: nil, requestedCardKeys: cards)
    }

    /// The pass's output, per row and for the handful of whole-queue values, so two runs can be compared.
    private func passOut(_ i: QueueRenderPass.Inputs) -> Phase0bPassOut {
        let data = QueueRenderPass.make(i)
        var focusesByKey: [String: [StageFocus]] = [:]
        for focus in StageFocus.allCases {
            for key in StageNavigation.naturalKeys(for: focus, in: data.placement) {
                focusesByKey[key, default: []].append(focus)
            }
        }
        let inAStage = Set(data.visibleRows.map(\.id))
        var rows: [String: Phase0bRowSig] = [:]
        for r in data.rows {
            rows[r.id] = Phase0bRowSig(row: r, card: data.cards.alreadyBuilt(r.id),
                                       focuses: focusesByKey[r.id] ?? [],
                                       reachedOut: data.reachedOutKeys.contains(r.id),
                                       inAStage: inAStage.contains(r.id))
        }
        let global: [String: String] = [
            "stageCounts": data.stageCounts.sorted { $0.key.rawValue < $1.key.rawValue }
                .map { "\($0.key.rawValue)=\($0.value)" }.joined(separator: ","),
            "agentInputs": String(describing: data.agentInputs),
            "reachedOut order": data.reachedOut.map { "\($0.prospect.naturalKey)|\($0.recipient.id)|\($0.next.timeIntervalSince1970)" }.joined(separator: ";"),
            "feedBreaks": data.feedBreaks.map { String(describing: $0) }.joined(separator: ";"),
            "mergeSurvivorsDropped": data.mergeSurvivorsDropped.map { String(describing: $0) }.joined(separator: ";"),
            "fanOutLine": data.fanOutLine ?? "nil",
            "pendingBookings": String(data.pendingBookings),
            "dateGroups": data.dateGroups.map { g in g.items.map(\.id).joined(separator: ",") }.joined(separator: "|"),
            "focusedRows order": data.focusedRows.map(\.id).joined(separator: ","),
            "inquiryRows": data.inquiryRows.map(\.id).map { "\($0)" }.joined(separator: ","),
            "flags": "\(data.gmailConnected) \(data.probeRunning) \(data.checkRunning) \(data.prepRunning) \(String(describing: data.checkRunSince)) \(String(describing: data.checkLookups))",
        ]
        return Phase0bPassOut(rows: rows, rowOrder: data.rows.map(\.id), global: global)
    }

    private func diff(_ a: Phase0bPassOut, _ b: Phase0bPassOut) -> (rows: Set<String>, global: [String]) {
        var changed = Set<String>()
        for key in Set(a.rows.keys).union(b.rows.keys) where a.rows[key] != b.rows[key] { changed.insert(key) }
        let global = a.global.keys.sorted().filter { a.global[$0] != b.global[$0] }
        return (changed, global)
    }

    // MARK: - 0b.1: ProducerTables patched in place, per change kind

    @Test(.enabled(if: Phase0.liveStoreExists, "no live store on this machine"))
    func probe0b1ProducerTablesPatch() throws {
        if skip("0b.1") { return }
        let ctx = ModelContext(try Phase0.openContainer(at: try clone("phase0b-1")))
        let rows = try ctx.fetch(FetchDescriptor<Prospect>())
        let overrides = ProducerOverrides(promotedRows: try ctx.fetch(FetchDescriptor<PromotedProducer>()),
                                          demotedRows: try ctx.fetch(FetchDescriptor<DemotedHouse>()))
        let base = rows.map { ProducerGate.Show(presenter: $0.presenter, venue: $0.venue) }
        var fourfold = base
        for k in 1..<4 {
            fourfold += base.map { ProducerGate.Show(presenter: Phase0b.containmentCopy($0.presenter, copy: k),
                                                     venue: Phase0b.containmentCopy($0.venue, copy: k)) }
        }
        var failures: [String] = []
        for (label, start) in [("live clone", base), ("4x containment-preserving", fourfold)] {
            var shows = start
            var current = overrides
            let oracle0 = QueueModel.ProducerTables(shows: shows, overrides: current)
            var coldRuns: [Double] = []
            var patched = Phase0bPatchTables(shows: [], overrides: current)
            for _ in 0..<5 { coldRuns.append(Phase0.time { patched = Phase0bPatchTables(shows: shows, overrides: current) }) }
            let oracleCold = Phase0.median5 { _ = QueueModel.ProducerTables(shows: shows, overrides: current) }

            // Agreement with today's code and with the brute force, over every presenter in the corpus.
            func compare(_ what: String, brute: Bool = false) -> Int {
                let oracle = QueueModel.ProducerTables(shows: shows, overrides: current)
                let venueKeys = oracle.corpus.venues.keys
                var bad = 0
                if Set(oracle.corpus.presenterKeys) != Set(patched.presenterRef.keys) { bad += 1 }
                if venueKeys != Set(patched.venueRef.keys) { bad += 1 }
                var seen = Set<String>()
                for s in shows {
                    guard let raw = s.presenter, let pk = ProducerGate.key(raw), seen.insert(raw).inserted else { continue }
                    let ob = oracle.venueBrands.contains(raw)
                    let bf = brute ? phase0bBruteBrand(pk, venueKeys: venueKeys, overrides: current) : ob
                    if ob != patched.brand.contains(pk) || bf != ob
                        || oracle.venueBrands.isRoomName(raw) != patched.room.contains(pk)
                        || oracle.corpus.distinctVenueCount(pk) != patched.distinctVenueCount(pk)
                        || ProducerGate.qualifies(raw, in: oracle.corpus, overrides: current) != patched.qualifies(pk) {
                        bad += 1
                        failures.append("\(label) \(what): presenter \(Phase0b.hash8(pk)) oracle brand \(ob) brute \(bf) patched \(patched.brand.contains(pk))")
                    }
                }
                return bad
            }
            let coldBad = compare("cold build", brute: true)
            let brandCount = patched.brand.count

            enum Kind: String, CaseIterable {
                case insertNewPresenter = "insert, new presenter"
                case insertNewVenue = "insert, new venue"
                case insertExistingPair = "insert, existing pair"
                case delete = "delete"
                case presenterEdit = "presenter edit"
                case venueEditTheatre = "venue edit to '<presenter> Theatre'"
                case venueEditBareTheatre = "venue edit to 'Theatre'"
                case merge = "merge (two rows into one)"
                case promote = "promote"
                case demote = "demote"
            }
            var rng = Phase0b.Rand(state: 4106)
            var lines: [String] = []
            var worstMedian = 0.0
            for kind in Kind.allCases {
                var times: [Double] = [], asked: [Int] = [], changedCounts: [Int] = []
                var mismatches = 0
                for sample in 0..<5 {
                    // A target that has a presenter, so every kind has something to act on.
                    var r = Int(rng.next() % UInt64(shows.count))
                    while shows[r].presenter == nil { r = (r + 1) % shows.count }
                    var r2 = Int(rng.next() % UInt64(shows.count))
                    while shows[r2].presenter == nil || r2 == r { r2 = (r2 + 1) % shows.count }
                    let target = shows[r], other = shows[r2]
                    var removed: [ProducerGate.Show] = [], added: [ProducerGate.Show] = []
                    var next = current
                    switch kind {
                    case .insertNewPresenter:
                        added = [ProducerGate.Show(presenter: "Zephyr Invented Ensemble \(sample)", venue: target.venue)]
                    case .insertNewVenue:
                        added = [ProducerGate.Show(presenter: target.presenter, venue: "Invented Room Number \(sample)")]
                    case .insertExistingPair:
                        added = [target]
                    case .delete:
                        removed = [target]
                    case .presenterEdit:
                        removed = [target]; added = [ProducerGate.Show(presenter: other.presenter, venue: target.venue)]
                    case .venueEditTheatre:
                        removed = [target]; added = [ProducerGate.Show(presenter: target.presenter, venue: "\(target.presenter ?? "") Theatre")]
                    case .venueEditBareTheatre:
                        removed = [target]; added = [ProducerGate.Show(presenter: target.presenter, venue: "Theatre")]
                    case .merge:
                        removed = [target, other]; added = [ProducerGate.Show(presenter: target.presenter, venue: other.venue)]
                    case .promote:
                        if let k = ProducerGate.key(target.presenter) { next.promoted.insert(k); next.demoted.remove(k) }
                    case .demote:
                        if let k = ProducerGate.key(target.presenter) { next.demoted.insert(k); next.promoted.remove(k) }
                    }
                    var result: (reevaluated: Int, changed: Set<String>) = (0, [])
                    times.append(Phase0.time { result = patched.patch(remove: removed, add: added, overrides: next) })
                    asked.append(result.reevaluated)
                    changedCounts.append(result.changed.count)
                    // Keep the oracle's list in step: remove one copy of each removed show, append the added.
                    for s in removed { if let i = shows.firstIndex(of: s) { shows.remove(at: i) } }
                    shows += added
                    let prior = current
                    current = next
                    // The brute force (P x V, no prefilter) on the first sample of every kind; today's code on all.
                    mismatches += compare("\(kind.rawValue) sample \(sample)", brute: sample == 0)
                    // Undo, so the next sample starts from the store as it is; the undo is checked too.
                    patched.patch(remove: added, add: removed, overrides: prior)
                    for s in added { if let i = shows.lastIndex(of: s) { shows.remove(at: i) } }
                    shows += removed
                    current = prior
                    mismatches += compare("\(kind.rawValue) undo \(sample)")
                }
                let t = Phase0b.reading(times)
                worstMedian = max(worstMedian, t.median)
                let askedText = asked.sorted()[asked.count / 2]
                lines.append(Phase0b.pad(kind.rawValue, 40) + " \(t.text)  keys re-asked median \(askedText) (max \(asked.max() ?? 0)), keys changed median \(changedCounts.sorted()[changedCounts.count / 2]), mismatches \(mismatches)")
                if mismatches > 0 { failures.append("\(label) \(kind.rawValue): \(mismatches) mismatches") }
            }
            let presenters = oracle0.corpus.presenterKeys.count
            Phase0b.say("""
                0b.1 [\(label)] \(shows.count) shows, \(presenters) presenter keys, \(oracle0.corpus.venues.keys.count) venue keys, \(brandCount) brand keys, \(Phase0.load())
                  today's ProducerTables built cold                 \(oracleCold.text)
                  prototype cold build                              \(Phase0b.reading(coldRuns).text), mismatches against today's code and the brute force \(coldBad)
                  \(lines.joined(separator: "\n  "))
                  worst per-kind patch median                       \(String(format: "%.2f", worstMedian)) ms (stop rule: over 5 ms at 5,376, or any mismatch)
                """)
        }
        if !failures.isEmpty { Phase0b.say("0b.1 FAILURES\n  " + failures.prefix(40).joined(separator: "\n  ")) }
        #expect(failures.isEmpty, "0b.1: the patched tables disagreed with today's code or the brute force")
    }

    // MARK: - 0b.2: the term census, and order determinism of every oracle

    @Test(.enabled(if: Phase0.liveStoreExists, "no live store on this machine"))
    func probe0b2TermCensusAndOrderDeterminism() throws {
        if skip("0b.2") { return }
        let export = try scratchExport()
        for (label, url) in try corpora("phase0b-2") {
            let ctx = ModelContext(try Phase0.openContainer(at: url))
            let t = try tables(ctx, export: export)
            let now = Date()
            let every = t.rows
            let inQueue = QueueRenderPass.Corpus(every).narrowed(QueueModel.queueScope).all
            let baseContext = StageContext(now: now, geo: t.geo, clients: t.clients)
            let resolved = baseContext.resolvingPlaces(of: inQueue)
            _ = QueueRenderPass.make(inputs(t, now: now, cards: []))
            let floor = Phase0.median5 { _ = QueueRenderPass.make(inputs(t, now: now, cards: [])) }
            let geoTerm = Phase0.median5 { _ = baseContext.resolvingPlaces(of: inQueue) }
            let scopeTerm = Phase0.median5 {
                _ = QueueModel.scope(from: inQueue, answers: t.answers, corpus: every, overrides: t.overrides,
                                     sources: t.sources, refusals: t.refusals, clients: resolved.clients,
                                     now: resolved.now, cardKeys: [], today: resolved.today)
            }
            let reachedTerm = Phase0.median5 { _ = ReachedOutQueue.activeWithDates(from: inQueue, now: now) }
            let reachedKeys = Set(ReachedOutQueue.activeWithDates(from: inQueue, now: now).map(\.prospect.naturalKey))
            let placeTerm = Phase0.median5 { _ = StageNavigation.placements(in: inQueue, context: resolved) }
            let placement = StageNavigation.placements(in: inQueue, context: resolved)
            let stageKeysTerm = Phase0.median5 { _ = StageNavigation.queueKeys(in: placement, reachedOutKeys: reachedKeys) }
            let countsTerm = Phase0.median5 { _ = StageNavigation.counts(in: placement) }
            let focusedTerm = Phase0.median5 { _ = Set(StageNavigation.focusedKeys(stage: .scout, leadKeys: [], in: placement)) }
            let fanOutTerm = Phase0.median5 { _ = QueueRenderPass.fanOutWarning(inQueue) }
            let agentTerm = Phase0.median5 {
                _ = AgentInputs.from(prospects: inQueue, allProspects: every, inquiries: t.inquiries, context: resolved,
                                     gmailConnected: false, runInFlight: nil, replyRunAlive: false, placement: placement)
            }
            let today = EasternDate.today(now)
            let feedTerm = Phase0.median5 {
                _ = AppNotices.feedBreaks(FeedBreakEvent.events(among: every, asOf: today), shownInQueue: { _ in true })
            }
            let survivorsTerm = Phase0.median5 {
                _ = every.filter { p in
                    guard p.mergeSurvivorUnseenAt != nil, !p.isClosed else { return false }
                    return EasternDate.runIsLive(lastNight: EasternDate.runLastNight(runEndDate: p.runEndDate,
                                                                                     performanceDate: p.performanceDate),
                                                 today: today)
                }.count
            }
            let inquiryTerm = Phase0.median5 { _ = QueueRenderPass.inquiryRows(t.inquiries, stage: .scout, now: now) }
            let scopeRows = QueueModel.scope(from: inQueue, answers: t.answers, corpus: every, overrides: t.overrides,
                                             sources: t.sources, refusals: t.refusals, clients: resolved.clients,
                                             now: resolved.now, cardKeys: [], today: resolved.today).rows
            let selfBookingTerm = Phase0.median5 { _ = QueueModel.selfBookingIndex(scopeRows) }
            let pendingTerm = Phase0.median5 { _ = QueueModel.pendingBookingCount(scopeRows) }
            let groupTerm = Phase0.median5 { _ = QueueModel.groupByDate(scopeRows) }

            // INSIDE QueueModel.scope, every line of its preamble and its row loop, in the order it runs.
            let shows = every.map { ProducerGate.Show(presenter: $0.presenter, venue: $0.venue) }
            let engagementTerm = Phase0.median5 { _ = EngagementLink.group(inQueue.map(EngagementLink.Row.init)) }
            let tablesTerm = Phase0.median5 { _ = QueueModel.ProducerTables(shows: shows, overrides: t.overrides) }
            let producer = QueueModel.ProducerTables(shows: shows, overrides: t.overrides)
            let inheritedTerm = Phase0.median5 {
                _ = QueueModel.inheritedAnswers(t.answers, corpus: every, overrides: t.overrides, refusals: t.refusals,
                                                heldKeys: [], now: now, producerCorpus: producer.corpus)
            }
            let inherited = QueueModel.inheritedAnswers(t.answers, corpus: every, overrides: t.overrides,
                                                        refusals: t.refusals, heldKeys: [], now: now,
                                                        producerCorpus: producer.corpus)
            let rowCountsTerm = Phase0.median5 { _ = QueueModel.organisationRowCounts(every.map(\.presenter)) }
            let calendarTerm = Phase0.median5 { _ = QueueModel.sourceCalendarIndex(t.sources) }
            let contradictedTerm = Phase0.median5 { _ = ContradictedCancellation.contradictedKeys(among: every) }
            let showLinkTerm = Phase0.median5 { _ = ShowLink.group(every.map(ShowLink.Row.init)) }
            let titlesTerm = Phase0.median5 {
                _ = Dictionary(every.map { ($0.naturalKey, $0.groupName) }, uniquingKeysWith: { a, _ in a }).count
            }
            let collapseTerm = Phase0.median5 {
                _ = ShowLink.collapse(every.map(ShowLink.Row.init), drawn: Set(inQueue.map(\.naturalKey)))
            }
            let lookalikesTerm = Phase0.median5 {
                var by: [String: [Prospect]] = [:]
                for row in every { if let target = row.arrivedLookingLike { by[target, default: []].append(row) } }
                _ = by.mapValues { $0.sorted { ($0.firstSeenAt ?? .distantPast) > ($1.firstSeenAt ?? .distantPast) }.map(\.naturalKey) }
            }
            let nightsTerm = Phase0.median5 {
                _ = Dictionary(every.compactMap { r -> (String, String)? in
                    guard let n = r.performanceDate, !n.isEmpty else { return nil }
                    return (r.naturalKey, n)
                }, uniquingKeysWith: { a, _ in a }).count
            }
            let rowLoopTerm = Phase0.median5 {
                for p in inQueue {
                    let contacts = p.countedRecipients
                    _ = QueueScopeRow(p, facts: RecipientFacts.of(p, contacts: contacts),
                                      inheritedReachability: inherited[p.naturalKey])
                }
            }
            let countedTerm = Phase0.median5 { for p in inQueue { _ = p.countedRecipients } }
            // A card for every row in the queue, built from a retained preamble (the per-row cost the engine
            // would pay per rebuilt row), and its marginal cost per card.
            let store = QueueModel.scope(from: inQueue, answers: t.answers, corpus: every, overrides: t.overrides,
                                         sources: t.sources, refusals: t.refusals, clients: resolved.clients,
                                         now: resolved.now, cardKeys: [], today: resolved.today)
            let cardsTerm = Phase0.time { for r in store.rows { _ = store.cards.card(for: r) } }

            let scopeNamed = [engagementTerm, tablesTerm, inheritedTerm, rowCountsTerm, calendarTerm, contradictedTerm,
                              showLinkTerm, titlesTerm, collapseTerm, lookalikesTerm, nightsTerm, rowLoopTerm]
                .reduce(0) { $0 + $1.median }
            let passNamed = geoTerm.median + scopeTerm.median + reachedTerm.median + placeTerm.median
                + stageKeysTerm.median + countsTerm.median + focusedTerm.median + fanOutTerm.median + agentTerm.median
                + feedTerm.median + survivorsTerm.median + inquiryTerm.median + selfBookingTerm.median
                + pendingTerm.median + groupTerm.median
            let terms: [(String, Phase0.Reading)] = [
                ("geo resolve", geoTerm), ("QueueModel.scope (no cards)", scopeTerm),
                ("  EngagementLink.group", engagementTerm), ("  ProducerTables cold", tablesTerm),
                ("  inheritedAnswers (the ledger)", inheritedTerm), ("  organisationRowCounts", rowCountsTerm),
                ("  sourceCalendarIndex", calendarTerm), ("  ContradictedCancellation", contradictedTerm),
                ("  ShowLink.group", showLinkTerm), ("  titlesByKey", titlesTerm), ("  ShowLink.collapse", collapseTerm),
                ("  laterLookalikes", lookalikesTerm), ("  nightsByKey", nightsTerm),
                ("  row loop (countedRecipients + row)", rowLoopTerm), ("    of which countedRecipients", countedTerm),
                ("ReachedOutQueue.activeWithDates", reachedTerm), ("StageNavigation.placements", placeTerm),
                ("queueKeys", stageKeysTerm), ("stage counts", countsTerm), ("focusedKeys", focusedTerm),
                ("fanOutWarning", fanOutTerm), ("AgentInputs.from", agentTerm), ("feed breaks", feedTerm),
                ("unseen merge survivors", survivorsTerm), ("inquiryRows", inquiryTerm),
                ("selfBookingIndex", selfBookingTerm), ("pendingBookingCount", pendingTerm), ("groupByDate", groupTerm),
            ]
            let costliest = terms.filter { !$0.0.hasPrefix("QueueModel.scope") && !$0.0.hasPrefix("    ") }
                .sorted { $0.1.median > $1.1.median }.prefix(3).map { "\($0.0.trimmingCharacters(in: .whitespaces)) \(String(format: "%.1f", $0.1.median)) ms" }
            Phase0b.say("""
                0b.2 census [\(label)] \(every.count) shows, \(inQueue.count) in the queue scope, \(Phase0.load())
                  today's pass over models, no cards        \(floor.text)
                  \(terms.map { Phase0b.pad($0.0, 40) + " " + $0.1.text }.joined(separator: "\n  "))
                  inside scope: named \(String(format: "%.1f", scopeNamed)) ms of \(String(format: "%.1f", scopeTerm.median)) ms, unattributed \(String(format: "%.1f", scopeTerm.median - scopeNamed)) ms
                  whole pass: named \(String(format: "%.1f", passNamed)) ms of the floor \(String(format: "%.1f", floor.median)) ms, unattributed \(String(format: "%.1f", floor.median - passNamed)) ms
                  a card for every queue row from a retained preamble \(String(format: "%.1f", cardsTerm)) ms for \(store.rows.count) cards (\(String(format: "%.3f", cardsTerm / Double(max(store.rows.count, 1)))) ms a card)
                  the three costliest terms: \(costliest.joined(separator: "; "))
                  value instantiation of those three  UNMEASURED: needs each term rewritten as generic code (Phase 3). Probe 7's measured ratio (2.2x to 5x faster over values) is the only projection available.
                """)

            // Order determinism: the same pass over the fetch order, the reverse, and a seeded shuffle.
            var shuffled = every
            var rng = Phase0b.Rand(state: 97)
            shuffled.shuffle(using: &rng)
            let a = passOut(inputs(t, rows: every, now: now, cards: nil))
            let b = passOut(inputs(t, rows: every.reversed(), now: now, cards: nil))
            let c = passOut(inputs(t, rows: shuffled, now: now, cards: nil))
            let ab = diff(a, b), ac = diff(a, c)
            var lines: [String] = []
            lines.append("whole pass, per-row output: reversed \(ab.rows.count) rows differ, shuffled \(ac.rows.count) rows differ"
                         + (ab.rows.isEmpty && ac.rows.isEmpty ? "" : " (row hashes \(ab.rows.union(ac.rows).sorted().prefix(8).map(Phase0b.hash8).joined(separator: " ")))"))
            lines.append("whole pass, row order: reversed \(a.rowOrder == b.rowOrder ? "same" : "DIFFERS"), shuffled \(a.rowOrder == c.rowOrder ? "same" : "DIFFERS")")
            lines.append("whole pass, whole-queue values differing: reversed \(ab.global.isEmpty ? "none" : ab.global.joined(separator: ", ")); shuffled \(ac.global.isEmpty ? "none" : ac.global.joined(separator: ", "))")
            // Term by term, over the shuffled list.
            func same<T: Equatable>(_ name: String, _ f: ([Prospect]) -> T) {
                let x = f(every), y = f(every.reversed()), z = f(shuffled)
                lines.append("\(name): \(x == y && x == z ? "same" : "DIFFERS (reversed \(x == y ? "same" : "differs"), shuffled \(x == z ? "same" : "differs"))")")
            }
            same("inheritedAnswers (ledger)") { rows in
                QueueModel.inheritedAnswers(t.answers, corpus: rows, overrides: t.overrides, refusals: t.refusals,
                                            heldKeys: [], now: now)
            }
            same("ProducerTables brand verdicts") { rows in
                let tb = QueueModel.ProducerTables(shows: rows.map { ProducerGate.Show(presenter: $0.presenter, venue: $0.venue) },
                                                   overrides: t.overrides)
                return Set(rows.compactMap(\.presenter).filter { tb.venueBrands.contains($0) })
            }
            same("EngagementLink.group") { rows in EngagementLink.group(rows.map(EngagementLink.Row.init)) }
            same("ShowLink.group") { rows in ShowLink.group(rows.map(ShowLink.Row.init)) }
            same("ShowLink.collapse fronts") { rows in ShowLink.collapse(rows.map(ShowLink.Row.init)).fronts }
            same("ShowLink.collapse hidden") { rows in ShowLink.collapse(rows.map(ShowLink.Row.init)).hidden }
            same("ContradictedCancellation") { rows in ContradictedCancellation.contradictedKeys(among: rows) }
            same("FeedBreakEvent.events") { rows in FeedBreakEvent.events(among: rows, asOf: today) }
            same("organisationRowCounts") { rows in QueueModel.organisationRowCounts(rows.map(\.presenter)) }
            same("ReachedOutQueue order") { rows in
                ReachedOutQueue.activeWithDates(from: rows, now: now).map { "\($0.prospect.naturalKey)|\($0.recipient.id)" }
            }
            same("DueWork.counts") { rows in DueWork.counts(prospects: rows, inquiries: t.inquiries, now: now, replyRunAlive: false) }
            same("DueWork.nextChange") { rows in DueWork.nextChange(prospects: rows, now: now, replyRunAlive: false) }
            same("QueueModel.queueScope order") { rows in QueueModel.queueScope(rows).map(\.naturalKey) }
            Phase0b.say("0b.2 order determinism [\(label)]\n  " + lines.joined(separator: "\n  "))
        }
    }

    // MARK: - 0b.3 and 0b.12: keyset launch batches, identifier fetch, Inquiry fill

    @Test(.enabled(if: Phase0.liveStoreExists, "no live store on this machine"))
    func probe0b3KeysetBatchesAnd0b12Identifiers() async throws {
        if skip("0b.3/0b.12") { return }
        for (label, url) in try corpora("phase0b-3") {
            var lines: [String] = []
            let rowCount = try ModelContext(try Phase0.openContainer(at: url)).fetchCount(FetchDescriptor<Prospect>())
            // Two sort comparators, because they are not the same fill. The default SortDescriptor on a String
            // is `.localizedStandard`, while the keyset predicate `naturalKey > cursor` compares the stored bytes,
            // so the two can disagree about which rows lie after the cursor: the first run of this probe
            // returned 1,341 of 1,344 rows at batch 25 and 5,436 of 5,376 at 4x. `.lexical` is the arm D6 needs.
            for (arm, comparator) in [("default (localizedStandard) sort", String.StandardComparator.localizedStandard),
                                      ("lexical sort", String.StandardComparator.lexical)] {
            for size in [25, 50, 100] {
                var totals: [Double] = [], worst: [Double] = []
                var batches = 0, rowsSeen = 0, distinct = 0
                for _ in 0..<5 {
                    let c = try Phase0.openContainer(at: url)
                    var cursor = ""
                    var total = 0.0, largest = 0.0
                    var seen = Set<PersistentIdentifier>()
                    batches = 0; rowsSeen = 0
                    while batches < 10_000 {
                        let after = cursor
                        var d = FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey > after },
                                                          sortBy: [SortDescriptor(\Prospect.naturalKey, comparator: comparator)])
                        d.fetchLimit = size
                        var got: [Prospect] = []
                        let t = Phase0.time {
                            got = (try? c.mainContext.fetch(d)) ?? []
                            phase0ArmTrackers(got, log: Phase0FireLog())
                        }
                        if got.isEmpty { break }
                        total += t
                        largest = max(largest, t)
                        batches += 1
                        rowsSeen += got.count
                        for g in got { seen.insert(g.persistentModelID) }
                        cursor = got.last!.naturalKey
                    }
                    distinct = seen.count
                    totals.append(total)
                    worst.append(largest)
                }
                lines.append("\(arm), keyset batch \(size): \(batches) batches, \(rowsSeen) rows returned, \(distinct) distinct of \(rowCount) (missed \(rowCount - distinct), repeated \(rowsSeen - distinct)), total \(Phase0b.reading(totals).text), largest batch \(Phase0b.reading(worst).text)")
            }
            }
            // 0b.12: the background identifier fetch the shortfall check would run, and the Inquiry fill.
            let c = try Phase0.openContainer(at: url)
            var idRuns: [Double] = []
            var idCount = 0, inquiryIDCount = 0
            for _ in 0..<5 {
                let t0 = Phase0.now()
                let counts: (Int, Int) = await phase0OnThread("phase0b-ids") {
                    let bg = ModelContext(c)
                    let p = (try? bg.fetchIdentifiers(FetchDescriptor<Prospect>())) ?? []
                    let i = (try? bg.fetchIdentifiers(FetchDescriptor<Inquiry>())) ?? []
                    return (p.count, i.count)
                }
                idRuns.append(Phase0.ms(since: t0))
                (idCount, inquiryIDCount) = counts
            }
            let modelIDs = Set(try ModelContext(c).fetch(FetchDescriptor<Prospect>()).map(\.persistentModelID))
            let fetchedIDs = Set(try ModelContext(c).fetchIdentifiers(FetchDescriptor<Prospect>()))
            let inquiryFetch = Phase0.median5 { _ = ((try? ModelContext(c).fetch(FetchDescriptor<Inquiry>())) ?? []).count }
            let inquiryCount = try ModelContext(c).fetchCount(FetchDescriptor<Inquiry>())
            Phase0b.say("""
                0b.3 [\(label)] \(Phase0.load())
                  \(lines.joined(separator: "\n  "))
                0b.12 [\(label)]
                  background identifier fetch, Prospect + Inquiry, on its own thread  \(Phase0b.reading(idRuns).text) (\(idCount) + \(inquiryIDCount) identifiers)
                  identifiers equal the fetched models' PIDs                         \(modelIDs == fetchedIDs) (\(fetchedIDs.count) against \(modelIDs.count))
                  live Inquiry count \(inquiryCount); one fetch of every Inquiry, fresh context  \(inquiryFetch.text)
                """)
            #expect(modelIDs == fetchedIDs, "0b.12: fetchIdentifiers did not return the fetched models' identifiers")
        }
    }

    // MARK: - 0b.4: refetch semantics, and a foreign save against a later main save

    private func scratchShows(_ name: String, count: Int) throws -> (ModelContainer, ModelContext, [Prospect]) {
        let dir = try sandboxes.make(named: name)
        let container = try Phase0.openContainer(at: dir.appendingPathComponent("probe.store"))
        let ctx = container.mainContext
        ctx.autosaveEnabled = false
        var shows: [Prospect] = []
        for n in 0..<count {
            let p = Prospect(naturalKey: "probe-\(n)", groupName: "Ensemble \(n)", discipline: "music",
                             venue: "Hall \(n)", performanceDate: "2027-01-\(String(format: "%02d", 1 + n % 28))",
                             sourceListingURL: nil, priorRelationship: "none", production: "presenter",
                             profile: "strong", coverage: "likely_uncovered", fitScore: 5, tier: "mid",
                             fitReason: "original", matchedClientName: nil, possibleMatchSource: nil,
                             possibleMatchName: nil, status: .drafted)
            ctx.insert(p)
            shows.append(p)
        }
        try ctx.save()
        return (container, ctx, shows)
    }

    private func refetch(_ ctx: ModelContext, _ id: PersistentIdentifier) -> [Prospect] {
        (try? ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.persistentModelID == id }))) ?? []
    }

    @Test func probe0b4RefetchSemantics() async throws {
        if skip("0b.4") { return }
        var lines: [String] = []
        // Every container is held to the end of the test: a context whose container has been released
        // traps on its next write, and Swift may release a local after its last use.
        var held: [ModelContainer] = []
        defer { withExtendedLifetime(held) {} }

        do { // an unsaved main edit, then a refetch by identifier on main: 1 row and 25 rows
            let (container, ctx, shows) = try scratchShows("p0b4-unsaved", count: 30)
            held.append(container)
            shows[0].fitReason = "unsaved"
            let t1 = Phase0.time { _ = refetch(ctx, shows[0].persistentModelID) }
            let kept1 = shows[0].fitReason == "unsaved"
            for s in shows[1...25] { s.fitReason = "unsaved" }
            let ids = shows[1...25].map(\.persistentModelID)
            let t25 = Phase0.time { for id in ids { _ = refetch(ctx, id) } }
            let kept25 = shows[1...25].filter { $0.fitReason == "unsaved" }.count
            lines.append("unsaved edit then refetch on main: 1 row kept \(kept1) (\(String(format: "%.1f", t1)) ms); 25 rows kept \(kept25) of 25 (\(String(format: "%.1f", t25)) ms); hasChanges after \(ctx.hasChanges)")
            #expect(kept1 && kept25 == 25, "0b.4: a refetch by identifier overwrote an unsaved main edit")
        }
        do { // an unsaved main edit to field B, after another context saved field A on the same row
            let (container, ctx, shows) = try scratchShows("p0b4-mixed", count: 2)
            held.append(container)
            let row = shows[0]
            _ = row.tier
            let id = row.persistentModelID
            let foreignA: String? = await phase0OnThread("phase0b-foreign-a") {
                let other = ModelContext(container)
                guard let r = other.model(for: id) as? Prospect else { return "the row was not found" }
                r.tier = "top"
                return Phase0.saveFailure(other)
            }
            try Phase0.requireSaved(foreignA, step: "0b.4 foreign save of A")
            row.fitReason = "unsaved B"
            let before = row.tier
            _ = refetch(ctx, id)
            lines.append("foreign save of A, unsaved main edit of B, refetch on main: B kept \(row.fitReason == "unsaved B"), A refreshed \(row.tier == "top") (A read \(before == "top" ? "fresh" : "stale") before the refetch)")
        }
        do { // a refetch of a row another context deleted and saved
            let (container, ctx, shows) = try scratchShows("p0b4-deleted", count: 2)
            held.append(container)
            let row = shows[0]
            _ = row.fitReason
            let id = row.persistentModelID
            let foreignDelete: String? = await phase0OnThread("phase0b-foreign-delete") {
                let other = ModelContext(container)
                guard let r = other.model(for: id) as? Prospect else { return "the row was not found" }
                other.delete(r)
                return Phase0.saveFailure(other)
            }
            try Phase0.requireSaved(foreignDelete, step: "0b.4 foreign delete")
            let got = refetch(ctx, id)
            let all = ((try? ctx.fetch(FetchDescriptor<Prospect>())) ?? []).count
            lines.append("row deleted by another context, refetch on main: refetch returned \(got.count) rows; a whole fetch returns \(all) of 1 remaining; held instance isDeleted \(row.isDeleted), has a context \(row.modelContext != nil), StoreRows.isLive \(StoreRows.isLive(row))")
        }
        for faulted in [true, false] { // fact 4 from the other side: foreign save of A, then main saves B
            let (container, ctx, shows) = try scratchShows("p0b4-writeback-\(faulted)", count: 2)
            held.append(container)
            let row = shows[0]
            if faulted { _ = probeExtractProspect(row) }
            let id = row.persistentModelID
            let foreignA2: String? = await phase0OnThread("phase0b-foreign-a2") {
                let other = ModelContext(container)
                guard let r = other.model(for: id) as? Prospect else { return "the row was not found" }
                r.tier = "top"
                return Phase0.saveFailure(other)
            }
            try Phase0.requireSaved(foreignA2, step: "0b.4 foreign save of A before main saves B")
            row.fitReason = "main B"
            try ctx.save()
            let check: (String, String) = await phase0OnThread("phase0b-readback") {
                let fresh = ModelContext(container)
                let r = fresh.model(for: id) as? Prospect
                return (r?.tier ?? "nil", r?.fitReason ?? "nil")
            }
            lines.append("foreign save of A then a main save of B (main row \(faulted ? "fully read first" : "not read first")): A kept \(check.0 == "top"), B kept \(check.1 == "main B")")
        }
        Phase0b.say("0b.4 scratch store\n  " + lines.joined(separator: "\n  "))
    }

    // MARK: - 0b.5: the reconcile tick, laps and members-built rows

    @Test(.enabled(if: Phase0.liveStoreExists, "no live store on this machine"))
    func probe0b5ReconcileTick() async throws {
        if skip("0b.5") { return }
        let export = try scratchExport()
        for (label, url) in try corpora("phase0b-5") {
            let container = try Phase0.openContainer(at: url)
            let ctx = container.mainContext
            defer { withExtendedLifetime(container) {} }
            ctx.autosaveEnabled = false
            let scheduler = ReconcileScheduler(context: ctx, replyRunAlive: { _ in false })
            let defaults = ScratchDefaults.make("phase0b-5")
            // Members as the engine would hold them: one fetch at launch.
            let members = try ctx.fetch(FetchDescriptor<Prospect>())
            for r in members { _ = r.recipients.count }
            func membersRows() -> [Prospect] {
                let inserted = ctx.insertedModelsArray.compactMap { $0 as? Prospect }
                let deleted = Set(ctx.deletedModelsArray.compactMap { ($0 as? Prospect)?.persistentModelID })
                return members.filter { !deleted.contains($0.persistentModelID) } + inserted
            }
            func sameAsFetch() -> Bool {
                Set(membersRows().map(\.persistentModelID))
                    == Set(((try? ctx.fetch(FetchDescriptor<Prospect>())) ?? []).map(\.persistentModelID))
            }
            let quiet = sameAsFetch()
            let fresh = Prospect(naturalKey: "phase0b-inserted", groupName: "Inserted", discipline: "music",
                                 venue: "Hall", performanceDate: "2027-06-01", sourceListingURL: nil,
                                 priorRelationship: "none", production: "presenter", profile: "strong",
                                 coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                                 matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                                 status: .drafted)
            ctx.insert(fresh)
            ctx.delete(members[members.count / 3])
            let pending = sameAsFetch()
            let buildMembers = Phase0.median5 { _ = StoreRows(prospects: membersRows(), inquiries: []) }
            ctx.rollback()
            let rolledBack = sameAsFetch()

            // Each lap the tick runs locally, timed as its own main-actor turn. A warm-up round first, so the
            // first tick's real writes (Phase 0 measured 120 rows) are not what the five samples time.
            let now = Date()
            func lapsOnce() -> [String: Double] {
                var laps: [String: Double] = [:]
                var rows = StoreRows(prospects: [], inquiries: [])
                laps["readRows (StoreRows.fetch)"] = Phase0.time { rows = StoreRows.fetch(from: ctx) }
                laps["bookings"] = Phase0.time { _ = scheduler.reconcileBookings(now: now, from: export, rows: rows) }
                laps["conflicts"] = Phase0.time { scheduler.reapplyConflicts(now: now, from: export, prospects: rows.liveProspects) }
                laps["feedFreshness"] = Phase0.time { scheduler.observeFeedFreshness(now: now, from: export, into: defaults) }
                laps["retirement"] = Phase0.time { _ = scheduler.retireShowsThatOpened(now: now) }
                laps["closing read, on main (unsaved changes)"] = Phase0.time {
                    _ = DueReading.derive(prospects: rows.prospects, inquiries: rows.inquiries, now: now, replyRunAlive: false)
                }
                laps["closing count (DueBadge.publish)"] = Phase0.time { DueBadge.publish(3, replies: 1, into: defaults) }
                return laps
            }
            _ = lapsOnce()
            var all: [[String: Double]] = []
            for _ in 0..<5 { all.append(lapsOnce()) }
            // The closing read's main-thread share when nothing is unsaved: the background read, awaited.
            var awaitedMain: [Double] = []
            for _ in 0..<5 {
                let monitor = Phase0bMainTurnMonitor()
                monitor.start()
                _ = await DueReading.read(from: ctx, now: now, replyRunAlive: false)
                awaitedMain.append(monitor.stop().worst)
            }
            let lapText = all[0].keys.sorted().map { k in
                let r = Phase0b.reading(all.map { $0[k] ?? 0 })
                return Phase0b.pad(k, 42) + " " + r.text + (r.median > 50 ? "  OVER 50 ms: batched under D5" : "")
            }
            Phase0b.say("""
                0b.5 [\(label)] \(members.count) shows, \(Phase0.load())
                  members-built StoreRows equals context.fetch: quiet \(quiet), with a pending insert and delete \(pending), after rollback \(rolledBack)
                  building StoreRows from members + inserted - deleted   \(buildMembers.text)
                  \(lapText.joined(separator: "\n  "))
                  closing read awaited off main, worst main turn during it   \(Phase0b.reading(awaitedMain).text)
                  NOT RUN: the reply check, threading repair, proposal sweep, signature refresh and OmniFocus laps, which reach real services (L2)
                """)
            #expect(quiet && pending && rolledBack, "0b.5: members plus inserted minus deleted did not equal the fetch")
        }
    }

    // MARK: - 0b.6: the scout landing, on today's code (the Phase 1a branch does not exist yet)

    @Test(.enabled(if: Phase0.liveStoreExists, "no live store on this machine"))
    func probe0b6ScoutLanding() async throws {
        if skip("0b.6") { return }
        let live = StoreLocation.handoffDirectory(appSupport: StoreLocation.appSupport, isDebugBuild: false)
            .appendingPathComponent("overture-scout-extract-results.json")
        let copy = try sandboxes.make(named: "phase0b-6-results").appendingPathComponent("results.json")
        try? FileManager.default.copyItem(at: live, to: copy)
        guard let data = try? Data(contentsOf: copy), let results = try? ScoutExtractResultsDecoder.decode(data) else {
            Phase0b.say("0b.6 UNMEASURED: no readable scout extract results on this machine")
            return
        }
        let events = results.results.reduce(0) { $0 + $1.events.count }
        var restamped: Set<String> = []
        for (label, url) in try corpora("phase0b-6") {
            let container = try Phase0.openContainer(at: url)
            let ctx = container.mainContext
            defer { withExtendedLifetime(container) {} }
            let saves = Phase0SaveLog(main: ctx)
            var lines: [String] = []
            for round in 1...2 {
                let rows = try ctx.fetch(FetchDescriptor<Prospect>())
                for r in rows { _ = r.recipients.count }
                let before = Dictionary(rows.map { ($0.persistentModelID, phase0Values($0)) }, uniquingKeysWith: { a, _ in a })
                let ingestedBefore = Dictionary(rows.map { ($0.persistentModelID, $0.ingestedAt) }, uniquingKeysWith: { a, _ in a })
                let log = Phase0FireLog()
                phase0ArmTrackers(rows, log: log)
                _ = saves.take()
                let monitor = Phase0bMainTurnMonitor()
                monitor.start()
                let start = Phase0.now()
                let outcome = await ScoutExtractIngest.ingest(results, clients: [], history: [], blocked: .empty, into: ctx)
                let wall = Phase0.ms(since: start)
                await settle()
                let turns = monitor.stop()
                let after = try ctx.fetch(FetchDescriptor<Prospect>())
                let changed = after.filter { p in before[p.persistentModelID].map { $0 != phase0Values(p) } ?? false }
                if round == 2 && label == "live clone" {
                    restamped = Set(after.filter { row in ingestedBefore[row.persistentModelID].map { old in old != row.ingestedAt } ?? false }.map(\.naturalKey))
                }
                let entries = saves.take()
                let sizes = entries.map { e in
                    e.ids.filter { $0.key.lowercased().contains("updated") }.reduce(0) { $0 + ($1.value["Prospect"] ?? 0) }
                }
                let s = log.snapshot
                lines.append("round \(round): wall \(String(format: "%.1f", wall)) ms; largest main turn \(String(format: "%.1f", turns.worst)) ms (\(turns.samples) samples, \(turns.over100) over 100 ms, \(turns.over16) over 16 ms, \(turns.abandoned) abandoned); "
                             + "outcome inserted \(outcome.inserted) updated \(outcome.updated) skipped \(outcome.skipped); rows written (value changed) \(changed.count); trackers fired \(s.rows.count); "
                             + "\(entries.count) saves, didSave updated shows per save: max \(sizes.max() ?? 0), median \(sizes.isEmpty ? 0 : sizes.sorted()[sizes.count / 2]), total \(sizes.reduce(0, +))")
            }
            // The save cost of the ingestedAt writes alone: the rows the unchanged re-land restamps (taken from
            // the clone's round 2, and their three glued copies on the 4x corpus), restamped and saved, against
            // the same save with nothing dirty. One save, and spread over the landing's 36 saves.
            let keys = label == "live clone" ? restamped
                : Set(restamped.flatMap { k in [k, k + "qa", k + "qb", k + "qc"] })
            let rows = try ctx.fetch(FetchDescriptor<Prospect>()).filter { keys.contains($0.naturalKey) }
            var oneSave: [Double] = [], spread: [Double] = [], empty: [Double] = []
            // #4384: each timed save's failure is carried out of the stopwatch and ends the probe, so a save that
            // never landed is not timed as one that did, and the next block does not time pending writes.
            for _ in 0..<5 {
                var failure: String?
                empty.append(Phase0.time { failure = Phase0.saveFailure(ctx) })
                try Phase0.requireSaved(failure, step: "0b.6 empty save")
                oneSave.append(Phase0.time {
                    let stamp = Date()
                    for r in rows { r.ingestedAt = stamp }
                    failure = Phase0.saveFailure(ctx)
                })
                try Phase0.requireSaved(failure, step: "0b.6 one save of the restamp")
                let chunk = max(1, rows.count / 36)
                spread.append(Phase0.time {
                    let stamp = Date()
                    for start in stride(from: 0, to: rows.count, by: chunk) where failure == nil {
                        for r in rows[start..<min(start + chunk, rows.count)] { r.ingestedAt = stamp }
                        failure = Phase0.saveFailure(ctx)
                    }
                })
                try Phase0.requireSaved(failure, step: "0b.6 restamp spread over 36 saves")
            }
            Phase0b.say("""
                0b.6 [\(label)] \(events) events over \(results.results.count) sources, \(Phase0.load())
                  \(lines.joined(separator: "\n  "))
                  ingestedAt restamp of \(rows.count) rows: one save \(Phase0b.reading(oneSave).text); spread over 36 saves \(Phase0b.reading(spread).text); an empty save \(Phase0b.reading(empty).text)
                  the Phase 1a branch arm  UNMEASURED: Phase 1a is not built, so every number above is today's code, no-op writes included
                """)
        }
    }

    // MARK: - 0b.7 and 0b.9: what cannot be measured from here, said rather than skipped

    @Test func probe0b7And0b9Unmeasured() {
        if skip("0b.7/0b.9") { return }
        Phase0b.say("""
            0b.7 Release arm of the generic-over-models probe  UNMEASURED: mac/scripts/run-tests-locked.sh builds and runs the Debug configuration only, and the unit test target compiles the app sources itself, so a -O reading needs a Release test configuration the project does not have (a build setting change, outside a measurement-only PR)
            0b.9 view body cost with the pass served  UNMEASURED: needs a product seam. QueueView computes its RenderData inside makeRenderData behind renderMemo; no entry point hands the view a served RenderData or times its body apart from the fingerprint and the memo lookup
            """)
    }

    // MARK: - 0b.8: DueWork decomposed into per-row contributions

    @Test(.enabled(if: Phase0.liveStoreExists, "no live store on this machine"))
    func probe0b8DueWorkDecomposition() throws {
        if skip("0b.8") { return }
        for (label, url) in try corpora("phase0b-8") {
            let ctx = ModelContext(try Phase0.openContainer(at: url))
            let rows = try ctx.fetch(FetchDescriptor<Prospect>())
            for r in rows { _ = r.recipients.count }
            let inquiries = try ctx.fetch(FetchDescriptor<Inquiry>())
            let base = Date()
            var totalMismatch = 0, categoryMismatch = 0, nextMismatch = 0
            var detail: [String] = []
            for k in 0..<50 {
                let now = base.addingTimeInterval(Double(k) * 13 * 3600 + Double(k % 7) * 611)
                for alive in [false, true] where k % 5 == 0 || !alive {
                    let whole = DueWork.counts(prospects: rows, inquiries: inquiries, now: now, replyRunAlive: alive)
                    let wholeNext = DueWork.nextChange(prospects: rows, now: now, replyRunAlive: alive)
                    var sum = DueWork.counts(prospects: [], inquiries: inquiries, now: now, replyRunAlive: alive)
                    var soonest: Date?
                    for p in rows {
                        let one = DueWork.counts(prospects: [p], inquiries: [], now: now, replyRunAlive: alive)
                        sum.followUps += one.followUps
                        sum.afterTheShow += one.afterTheShow
                        sum.conversationsToConfirm += one.conversationsToConfirm
                        sum.stalledReplyDrafts += one.stalledReplyDrafts
                        sum.repliesToAnswer += one.repliesToAnswer
                        if let n = DueWork.nextChange(prospects: [p], now: now, replyRunAlive: alive), soonest.map({ n < $0 }) ?? true {
                            soonest = n
                        }
                    }
                    if sum.total != whole.total { totalMismatch += 1 }
                    if sum != whole {
                        categoryMismatch += 1
                        if detail.count < 5 { detail.append("instant \(k) alive \(alive): whole \(whole) summed \(sum)") }
                    }
                    if soonest != wholeNext { nextMismatch += 1 }
                }
            }
            let one = rows[rows.count / 2]
            let oneRow = Phase0.median5 {
                _ = DueWork.countAndNextChange(prospects: [one], inquiries: [], now: base, replyRunAlive: false)
            }
            let whole = Phase0.median5 {
                _ = DueWork.countAndNextChange(prospects: rows, inquiries: inquiries, now: base, replyRunAlive: false)
            }
            Phase0b.say("""
                0b.8 [\(label)] \(rows.count) shows, \(inquiries.count) inquiries, 60 comparisons over 50 instants (13 h apart, 10 with a reply run alive), \(Phase0.load())
                  summed per-row totals differ from DueWork.counts        \(totalMismatch) of 60
                  summed per-row categories differ                        \(categoryMismatch) of 60
                  min of per-row nextChange differs from DueWork.nextChange \(nextMismatch) of 60
                  one row's countAndNextChange (the update cost)          \(oneRow.text)
                  today's whole countAndNextChange                        \(whole.text)
                  \(detail.joined(separator: "\n  "))
                """)
        }
    }

    // MARK: - 0b.10: which rows each context field reaches, by moving it

    @Test(.enabled(if: Phase0.liveStoreExists, "no live store on this machine"))
    func probe0b10ContextFields() throws {
        if skip("0b.10") { return }
        let export = try scratchExport()
        for (label, url) in try corpora("phase0b-10") {
            let ctx = ModelContext(try Phase0.openContainer(at: url))
            let t = try tables(ctx, export: export)
            let now = Date()
            let base = inputs(t, now: now, cards: nil)
            let baseOut = passOut(base)
            // The per-row rebuild cost the engine would pay: rows and cards built from a retained preamble.
            let every = t.rows
            let inQueue = QueueRenderPass.Corpus(every).narrowed(QueueModel.queueScope).all
            let context = StageContext(now: now, geo: t.geo, clients: t.clients).resolvingPlaces(of: inQueue)
            let byKey = Dictionary(inQueue.map { ($0.naturalKey, $0) }, uniquingKeysWith: { a, _ in a })
            func rebuildCost(_ keys: Set<String>) -> Double {
                guard !keys.isEmpty else { return 0 }
                let scope = QueueModel.scope(from: inQueue, answers: t.answers, corpus: every, overrides: t.overrides,
                                             sources: t.sources, refusals: t.refusals, clients: context.clients,
                                             now: context.now, cardKeys: [], today: context.today)
                let rows = scope.rows.filter { keys.contains($0.id) }
                let shows = keys.compactMap { byKey[$0] }
                return Phase0.time {
                    for r in rows { _ = scope.cards.card(for: r) }
                    for p in shows { _ = QueueScopeRow(p, facts: RecipientFacts.of(p)) }
                }
            }
            func perturb(_ name: String, _ change: (inout QueueRenderPass.Inputs) -> Void) -> String {
                var i = inputs(t, now: now, cards: nil)
                change(&i)
                let d = diff(baseOut, passOut(i))
                let cost = rebuildCost(d.rows)
                return Phase0b.pad(name, 44) + String(format: " rows reached %5d (%4.1f%%), rebuilding them %7.1f ms; whole-queue values moved: ",
                              d.rows.count, 100 * Double(d.rows.count) / Double(max(baseOut.rows.count, 1)), cost)
                    + (d.global.isEmpty ? "none" : d.global.joined(separator: ", "))
            }
            func shifted(_ seconds: TimeInterval) -> (inout QueueRenderPass.Inputs) -> Void {
                { i in i.context = StageContext(now: now.addingTimeInterval(seconds), geo: t.geo, clients: t.clients) }
            }
            // A town the queue actually holds, so refusing it can reach rows: the commonest location's.
            let towns = Dictionary(grouping: inQueue.compactMap { $0.location?.lowercased() }, by: { $0 })
            let commonest = towns.max { $0.value.count < $1.value.count }?.key ?? "nowhere"
            var promoted = t.overrides
            let topPresenter = Dictionary(grouping: every.compactMap { ProducerGate.key($0.presenter) }, by: { $0 })
                .max { $0.value.count < $1.value.count }?.key
            if let topPresenter { promoted.promoted.insert(topPresenter); promoted.demoted.remove(topPresenter) }
            var lines: [String] = []
            lines.append(perturb("now + 1 minute", shifted(60)))
            lines.append(perturb("now + 1 hour", shifted(3600)))
            lines.append(perturb("now - 1 day", shifted(-86_400)))
            lines.append(perturb("now + 1 day (day rollover)", shifted(86_400)))
            lines.append(perturb("geo: refuse the commonest queue town") { i in
                var g = t.geo; g.userExcludedTowns.insert(commonest)
                i.context = StageContext(now: now, geo: g, clients: t.clients)
            })
            lines.append(perturb("geo: drop every town Dan refused") { i in
                i.context = StageContext(now: now, geo: GeoRefusals(userExcludedTowns: [], allowedSeedTowns: t.geo.allowedSeedTowns), clients: t.clients)
            })
            lines.append(perturb("clients: none (roster unreadable)") { i in
                i.context = StageContext(now: now, geo: t.geo, clients: .none)
            })
            lines.append(perturb("gmailConnected true") { $0.gmailConnected = true })
            lines.append(perturb("runInFlight prep") { $0.runInFlight = .prep })
            lines.append(perturb("runInFlight reachabilityCheck") { $0.runInFlight = .reachabilityCheck })
            lines.append(perturb("prepSlotRunning true") { $0.prepSlotRunning = true })
            lines.append(perturb("checkSlotRunning + since + lookups") { i in
                i.checkSlotRunning = true; i.checkRunSince = now.addingTimeInterval(-120); i.checkLookups = 7
            })
            lines.append(perturb("replyRunAlive true") { $0.replyRunAlive = true })
            lines.append(perturb("orgAnswers: none") { $0.orgAnswers = [] })
            lines.append(perturb("refusals: none") { $0.refusals = .none })
            lines.append(perturb("overrides: promote the commonest presenter") { $0.overrides = promoted })
            lines.append(perturb("sources: none") { $0.sources = [] })
            lines.append(perturb("inquiries: none") { $0.inquiries = [] })
            // heldKeys is not a pass input today (fact 9); measured on scope directly, holding 25 queue rows.
            let held = Set(inQueue.prefix(25).map(\.naturalKey))
            let s0 = QueueModel.scope(from: inQueue, answers: t.answers, corpus: every, overrides: t.overrides, sources: t.sources,
                                      refusals: t.refusals, clients: context.clients, now: context.now, cardKeys: nil,
                                      today: context.today)
            let s1 = QueueModel.scope(from: inQueue, answers: t.answers, corpus: every, overrides: t.overrides, sources: t.sources,
                                      refusals: t.refusals, clients: context.clients, now: context.now, heldKeys: held,
                                      cardKeys: nil, today: context.today)
            let heldReached = s0.rows.filter { r in r != s1.rows.first { $0.id == r.id } || s0.cards.alreadyBuilt(r.id) != s1.cards.alreadyBuilt(r.id) }.count
            Phase0b.say("""
                0b.10 [\(label)] \(baseOut.rows.count) queue rows, \(Phase0.load())
                  \(lines.joined(separator: "\n  "))
                  heldKeys (not a pass input today, fact 9): holding 25 queue rows changes \(heldReached) rows through QueueModel.scope
                  method: each field moved on its own and the pass run again; a row is REACHED when its row, card, stages or Reached out membership changed. That is a lower bound on rows CONSULTING the field (a read whose answer did not move is invisible), which ContextReader would record. Rebuild cost is the rows' cards and rows from a retained preamble, cross-row tables excluded.
                """)
        }
    }

    // MARK: - 0b.11: when each row's output next changes on the clock, and the floor tick's cold bucket

    @Test(.enabled(if: Phase0.liveStoreExists, "no live store on this machine"))
    func probe0b11ValidUntilDistribution() throws {
        if skip("0b.11") { return }
        let export = try scratchExport()
        for (label, url) in try corpora("phase0b-11") {
            let ctx = ModelContext(try Phase0.openContainer(at: url))
            let t = try tables(ctx, export: export)
            let now = Date()
            let every = t.rows
            let inQueue = QueueRenderPass.Corpus(every).narrowed(QueueModel.queueScope).all
            let context = StageContext(now: now, geo: t.geo, clients: t.clients).resolvingPlaces(of: inQueue)

            // The cold bucket: N/60 rows rebuilt from nothing but the retained preamble, five different buckets.
            let scope = QueueModel.scope(from: inQueue, answers: t.answers, corpus: every, overrides: t.overrides,
                                         sources: t.sources, refusals: t.refusals, clients: context.clients,
                                         now: context.now, cardKeys: [], today: context.today)
            let bucketSize = max(1, every.count / 60)
            var bucketRuns: [Double] = []
            for b in 0..<5 {
                let fresh = QueueModel.scope(from: inQueue, answers: t.answers, corpus: every, overrides: t.overrides,
                                             sources: t.sources, refusals: t.refusals, clients: context.clients,
                                             now: context.now, cardKeys: [], today: context.today)
                let rows = Array(fresh.rows.dropFirst(b * bucketSize).prefix(bucketSize))
                let shows = rows.compactMap { r in inQueue.first { $0.naturalKey == r.id } }
                bucketRuns.append(Phase0.time {
                    for r in rows { _ = fresh.cards.card(for: r) }
                    for p in shows { _ = QueueScopeRow(p, facts: RecipientFacts.of(p)) }
                })
            }
            _ = scope
            let bucket = Phase0b.reading(bucketRuns)

            // The distribution is read on the clone only: the fourfold copy keeps every date, so its instants
            // are the clone's with four rows each, by construction.
            guard label == "live clone" else {
                Phase0b.say("""
                    0b.11 [\(label)] \(every.count) shows, \(Phase0.load())
                      cold bucket, \(bucketSize) rows (N/60) rebuilt from a retained preamble  \(bucket.text)  (stop rule: over 16 ms at 5,376)
                      distribution: the clone's, with four rows at each instant (the copy keeps every date)
                    """)
                continue
            }
            func out(_ at: Date) -> [String: Phase0bRowSig] {
                var i = inputs(t, now: at, cards: nil)
                i.context = StageContext(now: at, geo: t.geo, clients: t.clients)
                return passOut(i).rows
            }
            let baseOut = out(now)
            let midnight1 = EasternDate.date(from: EasternDate.today(now.addingTimeInterval(86_400))) ?? now.addingTimeInterval(86_400)
            let midnight2 = midnight1.addingTimeInterval(86_400)
            var grid: [Date] = (1...48).map { now.addingTimeInterval(Double($0) * 3600) }
            grid += [midnight1.addingTimeInterval(-1), midnight1.addingTimeInterval(1),
                     midnight2.addingTimeInterval(-1), midnight2.addingTimeInterval(1)]
            grid.sort()
            // First grid instant at which each row differs from now.
            var firstChange: [String: (Date, Date)] = [:]
            var previous = now
            var evaluations = 1
            let wall = Phase0.time {
                for at in grid {
                    let o = out(at)
                    evaluations += 1
                    for (key, sig) in baseOut where firstChange[key] == nil && o[key] != sig {
                        firstChange[key] = (previous, at)
                    }
                    previous = at
                }
                // Refine each interval to under a minute, bisecting the whole group that changed inside it.
                var groups = Dictionary(grouping: firstChange.keys, by: { firstChange[$0]!.1 })
                while let (end, keys) = groups.first(where: { firstChange[$0.value[0]]!.1.timeIntervalSince(firstChange[$0.value[0]]!.0) > 60 }) {
                    groups[end] = nil
                    let (lo, hi) = firstChange[keys[0]]!
                    let mid = lo.addingTimeInterval(hi.timeIntervalSince(lo) / 2)
                    let o = out(mid)
                    evaluations += 1
                    var early: [String] = [], late: [String] = []
                    for k in keys { if o[k] != baseOut[k] { early.append(k); firstChange[k] = (lo, mid) } else { late.append(k); firstChange[k] = (mid, hi) } }
                    if !early.isEmpty { groups[mid, default: []] += early }
                    if !late.isEmpty { groups[hi.addingTimeInterval(0.001), default: []] += late }
                }
            }
            let atMidnight = firstChange.values.filter { abs($0.1.timeIntervalSince(midnight1)) <= 61 }.count
            let atMidnight2 = firstChange.values.filter { abs($0.1.timeIntervalSince(midnight2)) <= 61 }.count
            let perMinute = Dictionary(grouping: firstChange.values.map { Int($0.1.timeIntervalSince1970 / 60) }, by: { $0 })
            let peak = perMinute.values.map(\.count).max() ?? 0
            let other = firstChange.count - atMidnight - atMidnight2
            let beyond = baseOut.count - firstChange.count
            Phase0b.say("""
                0b.11 [\(label)] \(baseOut.count) queue rows, \(Phase0.load())
                  output first changes at the next Eastern midnight   \(atMidnight) rows (\(String(format: "%.1f", 100 * Double(atMidnight) / Double(max(baseOut.count, 1))))%)
                  at the midnight after                                \(atMidnight2) rows
                  at another instant within 48 h                       \(other) rows
                  no change within 48 h                                \(beyond) rows
                  rows whose first change falls in the busiest minute  \(peak) (four times that on the 4x copy, which keeps every date)
                  cold bucket, \(bucketSize) rows (N/60) rebuilt from a retained preamble  \(bucket.text)
                  method: \(evaluations) whole passes over 48 hourly instants plus both sides of two midnights, each interval bisected to under 60 s (\(String(format: "%.0f", wall)) ms). A row that changes and changes back inside an hour is missed; TimeProbe would record it.
                """)
        }
    }

    // MARK: - 0b.13: Step O collisions on the live store

    @Test(.enabled(if: Phase0.liveStoreExists, "no live store on this machine"))
    func probe0b13StepOCollisions() throws {
        if skip("0b.13") { return }
        let ctx = ModelContext(try Phase0.openContainer(at: try clone("phase0b-13")))
        let rows = try ctx.fetch(FetchDescriptor<Prospect>())
        let answers = try ctx.fetch(FetchDescriptor<OrgReachabilityAnswer>())
        let overrides = ProducerOverrides(promotedRows: try ctx.fetch(FetchDescriptor<PromotedProducer>()),
                                          demotedRows: try ctx.fetch(FetchDescriptor<DemotedHouse>()))
        let corpus = ProducerGate.Corpus(rows.map { ProducerGate.Show(presenter: $0.presenter, venue: $0.venue) })
        var byOrg: [String: Set<String>] = [:]
        var showsByPresenter: [String: Int] = [:]
        for r in rows {
            guard let p = r.presenter, let org = OrgKey.stored(for: p) else { continue }
            byOrg[org, default: []].insert(p)
            showsByPresenter[p, default: 0] += 1
        }
        let answered = Set(answers.map(\.orgKey))
        var splitOrgs = 0, splitShows = 0, verdictSplits = 0, verdictSplitsAnswered = 0
        var hashes: [String] = []
        for (org, spellings) in byOrg {
            let keys = Set(spellings.compactMap { ProducerGate.key($0) })
            guard keys.count > 1 else { continue }
            splitOrgs += 1
            splitShows += spellings.reduce(0) { $0 + (showsByPresenter[$1] ?? 0) }
            let verdicts = Set(spellings.map { ProducerGate.qualifies($0, in: corpus, overrides: overrides) })
            if verdicts.count > 1 {
                verdictSplits += 1
                if answered.contains(org) { verdictSplitsAnswered += 1 }
                hashes.append("\(Phase0b.hash8(org))\(answered.contains(org) ? "(answered)" : "")")
            }
        }
        Phase0b.say("""
            0b.13 [live clone] \(rows.count) shows, \(byOrg.count) organisation keys, \(answers.count) stored answers, \(Phase0.load())
              organisations whose spellings fold to more than one ProducerGate key  \(splitOrgs) (\(splitShows) shows)
              of those, spellings that get DIFFERENT qualifies verdicts               \(verdictSplits), \(verdictSplitsAnswered) with a stored answer (the order-dependent ones)
              org key hashes with split verdicts                                       \(hashes.sorted().joined(separator: " "))
            """)
    }
}
