import Testing
import Foundation
import SwiftData
import SQLite3

// #4106 Phase 0: the probes and the go/no-go gate for the per-row facts engine (plan v2 on discussion #4267).
//
// MEASUREMENT ONLY. Nothing here changes the app: every probe reads a throwaway clone of the live store (taken
// through `LiveStoreClone`, the one sanctioned route) or a scratch store of its own, and prints what it found.
// Each probe is OPT IN, like `QueueRenderPassLiveStoreCostTests` and for its reason: it clones Dan's store and
// runs a stopwatch, and a timing on a shared Mac measures whatever else the machine is doing (L224). Without
// the variable each test prints that it did not run, rather than passing silently (L98):
//
//   TEST_RUNNER_MEASURE_4106_PHASE0=1 mac/scripts/run-tests-locked.sh \
//     -only-testing:OvertureTests/QueueEnginePhase0ProbeTests
//
// PRIVACY. Counts, durations and field NAMES only: never a show name, a venue, an address or a URL, because
// anything a test prints reaches transcripts by a route no repository scanner inspects (L222).
//
// Every timing is a median of five with its spread (L395, L656), taken in the Debug build the test runner
// builds, which is the build every earlier figure on #4106 was taken in too; a Release build is faster and
// none of these numbers describe it. Load average is printed beside each block (L356).

enum Phase0 {
    nonisolated static var enabled: Bool {
        ProcessInfo.processInfo.environment["MEASURE_4106_PHASE0"] != nil
    }

    nonisolated static var liveStoreExists: Bool { LiveStoreClone.liveStoreURL != nil }

    nonisolated static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    nonisolated static func ms(since start: UInt64) -> Double { Double(now() - start) / 1_000_000 }

    nonisolated static func time(_ work: () -> Void) -> Double {
        let start = now()
        work()
        return ms(since: start)
    }

    struct Reading: Sendable {
        let runs: [Double]
        var median: Double { runs.sorted()[runs.count / 2] }
        var low: Double { runs.min() ?? 0 }
        var high: Double { runs.max() ?? 0 }
        var text: String { String(format: "%.1f ms (%.1f to %.1f)", median, low, high) }
    }

    nonisolated static func median5(_ work: () -> Void) -> Reading {
        Reading(runs: (0..<5).map { _ in time(work) })
    }

    nonisolated static func load() -> String {
        var l = [Double](repeating: 0, count: 3)
        getloadavg(&l, 3)
        return String(format: "load %.2f %.2f %.2f", l[0], l[1], l[2])
    }

    nonisolated static func say(_ line: String) { print("phase0 " + line) }

    nonisolated static func openContainer(at url: URL) throws -> ModelContainer {
        try ModelContainer(for: AppSchema.schema, configurations: [
            ModelConfiguration(schema: AppSchema.schema, url: url, cloudKitDatabase: .none)])
    }

    /// A copy of `clone` holding `factor` times the shows. The copies scale the clone's DISTRIBUTIONS rather
    /// than duplicating rows (L391): every copy keeps its row's shape (status, dates, fields, contacts) and
    /// gets a new identity (natural key, presenter, venue, title, series, thread ids, contact addresses), so
    /// cross-row clusters keyed on those form their own clusters rather than growing fourfold. Dates are
    /// kept, so a night holds `factor` times the shows it did: pessimistic for any term grouped by night,
    /// and stated beside every reading taken on it.
    nonisolated static func scaledCopy(of clone: URL, factor: Int, in dir: URL) throws -> URL {
        let out = dir.appendingPathComponent("Overture-x\(factor).store")
        for suffix in ["", "-wal", "-shm"] {
            let from = URL(fileURLWithPath: clone.path + suffix)
            if FileManager.default.fileExists(atPath: from.path) {
                try FileManager.default.copyItem(at: from, to: URL(fileURLWithPath: out.path + suffix))
            }
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(out.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw ScaleError.sql("open failed")
        }
        defer { sqlite3_close(db) }
        func columns(_ table: String) throws -> [String] {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK else {
                throw ScaleError.sql("table_info \(table)")
            }
            defer { sqlite3_finalize(stmt) }
            var names: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                names.append(String(cString: sqlite3_column_text(stmt, 1)))
            }
            return names
        }
        func exec(_ sql: String) throws {
            var err: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
                let message = err.map { String(cString: $0) } ?? "unknown"
                sqlite3_free(err)
                throw ScaleError.sql(message)
            }
        }
        let offset = 100_000
        let showSuffixed: Set<String> = ["ZNATURALKEY", "ZPRESENTER", "ZVENUE", "ZGROUPNAME", "ZSCOUTGROUPNAME",
                                         "ZSCOUTVENUE", "ZSERIESID", "ZGMAILTHREADID", "ZGMAILMESSAGEID"]
        let contactPrefixed: Set<String> = ["ZEMAIL", "ZID"]
        let contactSuffixed: Set<String> = ["ZGMAILTHREADID", "ZGMAILMESSAGEID", "ZSENDGROUPID"]
        let showCols = try columns("ZPROSPECT")
        let contactCols = try columns("ZRECIPIENT")
        try exec("BEGIN")
        for k in 1..<factor {
            let shift = k * offset
            // GLUED onto the last word, never a new word: a shared " x1" word would put every copied name
            // into one bucket of any word-indexed term (`ProducerGate.VenueKeyIndex`), which made the first
            // reading of this corpus superlinear for a reason no real store has. Glued, "Hall" becomes
            // "Hallqa", so names share words within a copy exactly as they do in the clone.
            let glue = "q" + String(UnicodeScalar(UInt8(96 + k)))
            let showExprs = showCols.map { c -> String in
                if c == "Z_PK" { return "Z_PK + \(shift)" }
                if showSuffixed.contains(c) { return "\(c) || '\(glue)'" }
                return c
            }
            try exec("INSERT INTO ZPROSPECT (\(showCols.joined(separator: ","))) SELECT "
                     + "\(showExprs.joined(separator: ",")) FROM ZPROSPECT WHERE Z_PK < \(offset)")
            let contactExprs = contactCols.map { c -> String in
                if c == "Z_PK" || c == "ZPROSPECT" { return "\(c) + \(shift)" }
                if contactPrefixed.contains(c) { return "'x\(k).' || \(c)" }
                if contactSuffixed.contains(c) { return "\(c) || '\(glue)'" }
                return c
            }
            try exec("INSERT INTO ZRECIPIENT (\(contactCols.joined(separator: ","))) SELECT "
                     + "\(contactExprs.joined(separator: ",")) FROM ZRECIPIENT WHERE Z_PK < \(offset)")
        }
        try exec("UPDATE Z_PRIMARYKEY SET Z_MAX = (SELECT MAX(Z_PK) FROM ZPROSPECT) WHERE Z_NAME = 'Prospect'")
        try exec("UPDATE Z_PRIMARYKEY SET Z_MAX = (SELECT MAX(Z_PK) FROM ZRECIPIENT) WHERE Z_NAME = 'Recipient'")
        try exec("COMMIT")
        return out
    }

    enum ScaleError: Error { case sql(String) }

    /// The shape a scaled corpus must keep (L48): printed side by side for the clone and the copy.
    static func shape(_ rows: [Prospect]) -> String {
        let contacts = rows.reduce(0) { $0 + $1.recipients.count }
        let dismissed = rows.filter { $0.statusRaw == "dismissed" }.count
        let contacted = rows.filter { $0.sentAt != nil }.count
        var perNight: [String: Int] = [:]
        for r in rows { perNight[r.performanceDate ?? "", default: 0] += 1 }
        let pairs = Set(rows.map { "\($0.presenter ?? "")|\($0.venue ?? "")" }).count
        return "\(rows.count) shows, \(contacts) contacts (\(String(format: "%.3f", Double(contacts) / Double(max(rows.count, 1)))) a show), "
            + "dismissed \(String(format: "%.3f", Double(dismissed) / Double(max(rows.count, 1)))), "
            + "contacted \(String(format: "%.3f", Double(contacted) / Double(max(rows.count, 1)))), "
            + "largest night \(perNight.values.max() ?? 0), presenter-venue pairs \(pairs)"
    }
}

/// Which per-row trackers fired, and on which thread. Written from observation's `onChange`, which is
/// `@Sendable` and runs on whatever thread made the change, so it is lock protected.
final class Phase0FireLog: @unchecked Sendable {
    private let lock = NSLock()
    private var fired: Set<Int> = []
    private var offMain = 0
    private var total = 0

    func record(_ index: Int) {
        let main = Thread.isMainThread
        lock.lock(); defer { lock.unlock() }
        fired.insert(index)
        total += 1
        if !main { offMain += 1 }
    }

    var snapshot: (rows: Set<Int>, total: Int, offMain: Int) {
        lock.lock(); defer { lock.unlock() }
        return (fired, total, offMain)
    }
}

/// One tracker per row, armed on every stored property of that row and of the contacts it reaches, which is
/// exactly what the plan's per-row intake would arm (`ScopeField.arm`, `armAll`).
@MainActor
func phase0ArmTrackers<M: ScopeObserved>(_ rows: [M], log: Phase0FireLog) {
    for (index, row) in rows.enumerated() {
        withObservationTracking {
            var seen = Set<ObjectIdentifier>()
            row.armAll(seen: &seen)
        } onChange: {
            log.record(index)
        }
    }
}

/// What every `ModelContext.didSave` reported: which context, which thread, and the identifiers by key and
/// entity. Kept generic over the userInfo keys so a key SwiftData adds later is printed rather than missed.
final class Phase0SaveLog: @unchecked Sendable {
    struct Entry: Sendable, CustomStringConvertible {
        let fromMain: Bool
        let onMainThread: Bool
        let ids: [String: [String: Int]]
        let identifiers: [String: [PersistentIdentifier]]
        var description: String {
            let parts = ids.keys.sorted().map { key -> String in
                let byEntity = ids[key]!.keys.sorted().map { "\($0) \(ids[key]![$0]!)" }.joined(separator: ", ")
                return "\(key): [\(byEntity)]"
            }
            return "save(mainContext: \(fromMain), mainThread: \(onMainThread), \(parts.joined(separator: "; ")))"
        }
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var token: NSObjectProtocol?

    init(main: ModelContext) {
        let mainID = ObjectIdentifier(main)
        token = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil,
                                                       queue: nil) { [weak self] note in
            let fromMain = (note.object as? ModelContext).map { ObjectIdentifier($0) == mainID } ?? false
            var ids: [String: [String: Int]] = [:]
            var identifiers: [String: [PersistentIdentifier]] = [:]
            for (key, value) in note.userInfo ?? [:] {
                let name = String(describing: key)
                guard let list = value as? [PersistentIdentifier] else {
                    ids[name] = ["(not identifiers)": 1]
                    continue
                }
                identifiers[name] = list
                var byEntity: [String: Int] = [:]
                for id in list { byEntity[id.entityName, default: 0] += 1 }
                ids[name] = byEntity
            }
            self?.append(Entry(fromMain: fromMain, onMainThread: Thread.isMainThread, ids: ids,
                               identifiers: identifiers))
        }
    }

    deinit { if let token { NotificationCenter.default.removeObserver(token) } }

    private func append(_ e: Entry) { lock.lock(); entries.append(e); lock.unlock() }

    func take() -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        let out = entries
        entries = []
        return out
    }
}

/// A value snapshot of one show and its contacts, so a probe can tell a tracker that fired on a REAL change
/// from one that fired on a write of the same value.
func phase0Values(_ p: Prospect) -> [String] {
    var out = Prospect.scopeFields.compactMap { field -> String? in
        if field.keyPath == \Prospect.recipients as AnyKeyPath { return nil }
        return String(describing: p[keyPath: field.keyPath] ?? "nil")
    }
    for r in p.recipients.sorted(by: { $0.id < $1.id }) {
        for field in Recipient.scopeFields where field.keyPath != \Recipient.prospect as AnyKeyPath {
            out.append(String(describing: r[keyPath: field.keyPath] ?? "nil"))
        }
    }
    return out
}

/// Runs work on a dedicated thread OUTSIDE the cooperative pool (L241), and hands back its result.
func phase0OnThread<T: Sendable>(_ name: String, _ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        let thread = Thread { continuation.resume(returning: work()) }
        thread.name = name
        thread.stackSize = 8 << 20
        thread.start()
    }
}

// Probe 7's scratch facts protocol: the fields the scope predicate and one card field set read.
protocol Phase0ShowFacts {
    var naturalKey: String { get }
    var groupName: String { get }
    var presenter: String? { get }
    var location: String? { get }
    var discipline: String { get }
    var venue: String? { get }
    var performanceDate: String? { get }
    var fitScore: Int { get }
    var tier: String { get }
    var statusRaw: String { get }
    var showOutcomeRaw: String? { get }
    var outcomeRaw: String { get }
    var sentAt: Date? { get }
    var runNights: [String] { get }
}

struct Phase0ShowValue: Phase0ShowFacts, Sendable {
    let naturalKey: String, groupName: String, presenter: String?, location: String?, discipline: String
    let venue: String?, performanceDate: String?, fitScore: Int, tier: String, statusRaw: String
    let showOutcomeRaw: String?, outcomeRaw: String, sentAt: Date?, runNights: [String]
    init(_ p: Prospect) {
        naturalKey = p.naturalKey; groupName = p.groupName; presenter = p.presenter; location = p.location
        discipline = p.discipline; venue = p.venue; performanceDate = p.performanceDate
        fitScore = p.fitScore; tier = p.tier; statusRaw = p.statusRaw; showOutcomeRaw = p.showOutcomeRaw
        outcomeRaw = p.outcomeRaw; sentAt = p.sentAt; runNights = p.runNights
    }
}

struct Phase0CardFields: Equatable {
    let id: String, title: String, venueLine: String, date: String, fit: Int, tier: String
    let contacted: Bool, nights: Int, outcome: String, presenter: String, discipline: String, status: String
}

extension Prospect: Phase0ShowFacts {}

@MainActor
@Suite("#4106 Phase 0 probes (opt in, live store clone)")
struct QueueEnginePhase0ProbeTests {

    private let sandboxes = TemporarySandboxes()

    private func skip(_ probe: String) -> Bool {
        guard Phase0.enabled else {
            print("phase0 \(probe): not measured. Set TEST_RUNNER_MEASURE_4106_PHASE0=1 to run it.")
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

    /// The clone and, beside it, the fourfold copy. Both returned so every probe that asks for 4x reads the
    /// same pair.
    private func corpora(_ name: String) throws -> [(label: String, url: URL)] {
        let dir = try sandboxes.make(named: name)
        guard let base = try LiveStoreClone.makeClone(in: dir) else {
            throw LiveStoreClone.Refusal.backupFailed("no live store on this machine")
        }
        let big = try Phase0.scaledCopy(of: base, factor: 4, in: dir)
        return [("live clone", base), ("4x", big)]
    }

    private func scratchExport() throws -> URL {
        let dir = try sandboxes.make(named: "phase0-export")
        let out = dir.appendingPathComponent("downbeat-export.json")
        if FileManager.default.fileExists(atPath: DownbeatBridge.defaultURL.path) {
            try FileManager.default.copyItem(at: DownbeatBridge.defaultURL, to: out)
        }
        return out
    }

    private func scratchDefaults() -> UserDefaults {
        let name = "phase0-\(UUID().uuidString)"
        return UserDefaults(suiteName: name)!
    }

    private func settle() async { try? await Task.sleep(for: .milliseconds(150)) }

    // MARK: - Probe 1: the split of today's cost, at 1,340 and at 4x

    @Test(.enabled(if: Phase0.liveStoreExists, "no live store on this machine"))
    func probe1CostSplit() throws {
        if skip("probe 1") { return }
        for (label, url) in try corpora("phase0-p1") {
            let container = try Phase0.openContainer(at: url)
            let fetch = Phase0.median5 {
                let c = ModelContext(container)
                _ = ((try? c.fetch(FetchDescriptor<Prospect>())) ?? []).count
            }
            let coldExtract = Phase0.median5 {
                let c = ModelContext(container)
                let rows = (try? c.fetch(FetchDescriptor<Prospect>())) ?? []
                _ = rows.map(probeExtractProspect).count
            }
            let ctx = ModelContext(container)
            let rows = try ctx.fetch(FetchDescriptor<Prospect>())
            let inquiries = try ctx.fetch(FetchDescriptor<Inquiry>())
            let answers = try ctx.fetch(FetchDescriptor<OrgReachabilityAnswer>())
            let sources = try ctx.fetch(FetchDescriptor<WatchedSource>())
            let refusals = ContactRefusal.ledger(from: try ctx.fetch(FetchDescriptor<RefusedContactAddress>()))
            let overrides = ProducerOverrides(promotedRows: try ctx.fetch(FetchDescriptor<PromotedProducer>()),
                                              demotedRows: try ctx.fetch(FetchDescriptor<DemotedHouse>()))
            _ = rows.map(probeExtractProspect).count
            let warmExtract = Phase0.median5 { _ = rows.map(probeExtractProspect).count }
            let oneRow = Phase0.median5 { _ = probeExtractProspect(rows[rows.count / 2]) }
            let inquiryExtract = Phase0.median5 { _ = inquiries.map(probeExtractInquiry).count }

            let shows = rows.map { ProducerGate.Show(presenter: $0.presenter, venue: $0.venue) }
            let tablesCold = Phase0.median5 { _ = QueueModel.ProducerTables(shows: shows, overrides: overrides) }
            let tablesKey = Phase0.median5 { _ = QueueModel.ProducerTables.key(shows: shows, overrides: overrides) }

            func pass(_ keys: Set<String>?) -> QueueView.RenderData {
                QueueRenderPass.make(QueueRenderPass.Inputs(
                    allProspects: QueueRenderPass.Corpus(rows), inquiries: inquiries, orgAnswers: answers,
                    sources: sources, refusals: refusals, overrides: overrides,
                    context: .at(QueueModel.easternToday(), now: Date()),
                    focusedStage: .scout, focusedKeys: nil, requestedCardKeys: keys))
            }
            let viewport = Set(pass([]).focusedRows.prefix(QueueViewportAssumption.rows).map(\.id))
            _ = pass(viewport)
            let shipping = Phase0.median5 { _ = pass(viewport) }
            let floor = Phase0.median5 { _ = pass([]) }
            Phase0.say("""
                p1 [\(label)] \(Phase0.load())
                  shape                                   \(Phase0.shape(rows))
                  fetch every show, fresh context          \(fetch.text)
                  fetch + extract every field, cold        \(coldExtract.text)
                  extract every field, rows in memory      \(warmExtract.text)  (\(String(format: "%.4f", warmExtract.median / Double(rows.count))) ms a show)
                  extract one show                         \(oneRow.text)
                  extract every inquiry (\(inquiries.count))            \(inquiryExtract.text)
                  ProducerTables built cold from values    \(tablesCold.text)
                  ProducerTables.key (hash) from values     \(tablesKey.text)
                  today's pass over models, viewport cards \(shipping.text)
                  today's pass over models, no cards        \(floor.text)
                  value pass over prebuilt facts           UNMEASURED: needs the Phase 2 records and the Phase 3 port
                """)
        }
    }

    // MARK: - Probe 7: generic code over the Prospect model, against today's model code

    /// The scope predicate (`QueueModel.queueScope`), written once as generic code.
    static func genericScope<F: Phase0ShowFacts>(_ all: [F]) -> [F] {
        all.enumerated()
            .filter { $0.element.statusRaw != "dismissed" }
            .sorted { lhs, rhs in
                let l = lhs.element.performanceDate ?? "", r = rhs.element.performanceDate ?? ""
                if l != r { return lhs.element.performanceDate == nil ? true
                    : (rhs.element.performanceDate == nil ? false : l < r) }
                if lhs.element.fitScore != rhs.element.fitScore { return lhs.element.fitScore > rhs.element.fitScore }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    static func genericCard<F: Phase0ShowFacts>(_ f: F) -> Phase0CardFields {
        Phase0CardFields(id: f.naturalKey, title: f.groupName,
                   venueLine: [f.venue, f.location].compactMap { $0 }.joined(separator: ", "),
                   date: f.performanceDate ?? "", fit: f.fitScore, tier: f.tier, contacted: f.sentAt != nil,
                   nights: f.runNights.count, outcome: f.showOutcomeRaw ?? f.outcomeRaw,
                   presenter: f.presenter ?? "", discipline: f.discipline, status: f.statusRaw)
    }

    /// The same field set, written the way today's code is: concretely over the model.
    static func concreteCard(_ p: Prospect) -> Phase0CardFields {
        Phase0CardFields(id: p.naturalKey, title: p.groupName,
                   venueLine: [p.venue, p.location].compactMap { $0 }.joined(separator: ", "),
                   date: p.performanceDate ?? "", fit: p.fitScore, tier: p.tier, contacted: p.sentAt != nil,
                   nights: p.runNights.count, outcome: p.showOutcomeRaw ?? p.outcomeRaw,
                   presenter: p.presenter ?? "", discipline: p.discipline, status: p.statusRaw)
    }

    @Test(.enabled(if: Phase0.liveStoreExists, "no live store on this machine"))
    func probe7GenericOverModelCost() throws {
        if skip("probe 7") { return }
        let container = try Phase0.openContainer(at: try clone("phase0-p7"))
        let ctx = ModelContext(container)
        let rows = try ctx.fetch(FetchDescriptor<Prospect>())
        let values = rows.map(Phase0ShowValue.init)
        // Agreement first, so a faster arm cannot be a wrong one.
        let todayScope = QueueModel.queueScope(rows).map(\.naturalKey)
        #expect(Self.genericScope(rows).map(\.naturalKey) == todayScope,
                "the generic scope over models disagrees with QueueModel.queueScope")
        #expect(Self.genericScope(values).map(\.naturalKey) == todayScope,
                "the generic scope over values disagrees with QueueModel.queueScope")
        #expect(rows.map(Self.genericCard) == rows.map(Self.concreteCard), "generic card over models disagrees")
        #expect(values.map(Self.genericCard) == rows.map(Self.concreteCard), "generic card over values disagrees")

        let scopeToday = Phase0.median5 { _ = QueueModel.queueScope(rows).count }
        let scopeModel = Phase0.median5 { _ = Self.genericScope(rows).count }
        let scopeValue = Phase0.median5 { _ = Self.genericScope(values).count }
        let cardToday = Phase0.median5 { _ = rows.map(Self.concreteCard).count }
        let cardModel = Phase0.median5 { _ = rows.map(Self.genericCard).count }
        let cardValue = Phase0.median5 { _ = values.map(Self.genericCard).count }
        // An EXISTING generic term with a model conformer (`PrepEligibilityFacts`, #1666), over the model and
        // over `QueueItem`, the value that conforms to it today.
        let items = rows.map { QueueItem($0) }
        let today = QueueModel.easternToday()
        let prepModel = Phase0.median5 { _ = PrepQueueBuilder.eligible(rows, today: today).count }
        let prepValue = Phase0.median5 { _ = PrepQueueBuilder.eligible(items, today: today).count }
        Phase0.say("""
            p7 \(rows.count) shows, \(Phase0.load())
              scope: today's QueueModel.queueScope over models  \(scopeToday.text)
              scope: generic, instantiated with Prospect         \(scopeModel.text)
              scope: generic, instantiated with a value           \(scopeValue.text)
              card fields: concrete over Prospect (today's shape) \(cardToday.text)
              card fields: generic over Prospect                  \(cardModel.text)
              card fields: generic over a value                   \(cardValue.text)
              PrepQueueBuilder.eligible (existing generic) over Prospect  \(prepModel.text)
              PrepQueueBuilder.eligible (existing generic) over QueueItem \(prepValue.text)
              specialisation: UNMEASURED in this Debug build (-Onone does not specialise generics)
            """)
    }

    // MARK: - Probe 5: arming one tracker per row

    @Test(.enabled(if: Phase0.liveStoreExists, "no live store on this machine"))
    func probe5TrackerArmCost() throws {
        if skip("probe 5") { return }
        for (label, url) in try corpora("phase0-p5") {
            let container = try Phase0.openContainer(at: url)
            let ctx = ModelContext(container)
            let rows = try ctx.fetch(FetchDescriptor<Prospect>())
            for r in rows { _ = r.recipients.count }
            let one = Phase0.median5 { phase0ArmTrackers([rows[rows.count / 2]], log: Phase0FireLog()) }
            let all = Phase0.median5 { phase0ArmTrackers(rows, log: Phase0FireLog()) }
            let batch100 = Phase0.median5 { phase0ArmTrackers(Array(rows.prefix(100)), log: Phase0FireLog()) }
            Phase0.say("""
                p5 [\(label)] \(rows.count) shows, \(Phase0.load())
                  arm one show (every field, its contacts)  \(one.text)
                  arm 100 shows                              \(batch100.text)
                  arm every show, one tracker each           \(all.text)  (\(String(format: "%.4f", all.median / Double(rows.count))) ms a show)
                """)
        }
    }

    // MARK: - Probe 2: didSave, observation and refault behaviour, on a scratch store

    private struct Scratch {
        let container: ModelContainer
        let ctx: ModelContext
        let shows: [Prospect]
        let inquiry: Inquiry
        let answer: OrgReachabilityAnswer
    }

    private func scratchStore(_ name: String) throws -> Scratch {
        let dir = try sandboxes.make(named: name)
        let container = try Phase0.openContainer(at: dir.appendingPathComponent("probe.store"))
        let ctx = container.mainContext
        var shows: [Prospect] = []
        for n in 0..<4 {
            let p = Prospect(naturalKey: "probe-\(n)", groupName: "Ensemble \(n)", discipline: "music",
                             venue: "Hall \(n)", performanceDate: "2027-01-0\(n + 1)", sourceListingURL: nil,
                             priorRelationship: "none", production: "presenter", profile: "strong",
                             coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                             matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                             status: .drafted)
            ctx.insert(p)
            for c in 0..<(n < 2 ? 2 : (n == 2 ? 1 : 0)) {
                p.recipients.append(Recipient(id: "r\(n)-\(c)", email: "r\(n)\(c)@example.com", name: "Contact",
                                              role: "press", provenance: .presenter))
            }
            shows.append(p)
        }
        let inquiry = Inquiry(source: .contactForm, inquirerName: "Ada", inquirerEmail: "ada@example.org",
                              eventName: "Gala", performanceDate: "2027-02-01", venue: "Hall", notes: nil)
        ctx.insert(inquiry)
        let answer = OrgReachabilityAnswer(orgKey: OrgKey.stored(for: "Probe Ensemble")!, result: .emailFound,
                                           probedAt: Date(), sourceNaturalKey: "probe-0", sourceGroupName: "g",
                                           presenterName: "Probe Ensemble", foundEmails: ["a@example.org"])
        ctx.insert(answer)
        try ctx.save()
        return Scratch(container: container, ctx: ctx, shows: shows, inquiry: inquiry, answer: answer)
    }

    private struct Observed {
        let showFires: Set<Int>
        let otherFires: Int
        let offMain: Int
        let saves: [Phase0SaveLog.Entry]
        var line: String {
            "trackers fired on shows \(showFires.sorted()) (of 4), inquiry/answer trackers \(otherFires), "
                + "off main \(offMain); \(saves.isEmpty ? "no didSave" : saves.map(\.description).joined(separator: " | "))"
        }
    }

    private func observe(_ s: Scratch, _ act: () throws -> Void) async throws -> Observed {
        let log = Phase0SaveLog(main: s.ctx)
        let shows = Phase0FireLog(), others = Phase0FireLog()
        phase0ArmTrackers(s.shows, log: shows)
        phase0ArmTrackers([s.inquiry], log: others)
        phase0ArmTrackers([s.answer], log: others)
        try act()
        await settle()
        let a = shows.snapshot, b = others.snapshot
        return Observed(showFires: a.rows, otherFires: b.total, offMain: a.offMain + b.offMain, saves: log.take())
    }

    @Test func probe2DidSaveAndObservation() async throws {
        if skip("probe 2") { return }
        var lines: [String] = []

        do { // an equal-value assignment
            let s = try scratchStore("p2-equal")
            var dirty = false
            let o = try await observe(s) {

                s.shows[0].groupName = s.shows[0].groupName
                dirty = s.ctx.hasChanges
                try s.ctx.save()
            }
            #expect(o.showFires == [0] && dirty, "PINNED 2026-09-26: an equal-value write fired its row's tracker and dirtied the context")
            lines.append("equal-value assignment: hasChanges after it \(dirty); \(o.line)")
        }
        do { // cascade delete of a show with two contacts
            let s = try scratchStore("p2-cascade")
            let o = try await observe(s) { s.ctx.delete(s.shows[1]); try s.ctx.save() }
            #expect(o.saves.first?.ids.values.contains { $0["Recipient"] == 2 } == true,
                    "PINNED 2026-09-26: a cascade delete named the show and both its contacts as deleted in one didSave")
            lines.append("cascade delete (show with 2 contacts): \(o.line)")
        }
        do { // lone contact delete, three ways
            let s = try scratchStore("p2-lone")
            let o1 = try await observe(s) { s.ctx.delete(s.shows[0].recipients[0]); try s.ctx.save() }
            lines.append("lone contact delete via context.delete: \(o1.line)")
            let o2 = try await observe(s) { s.shows[1].setRecipients([s.shows[1].recipients[0]]); try s.ctx.save() }
            lines.append("lone contact delete via setRecipients: \(o2.line)")
            let o3 = try await observe(s) { s.shows[2].removeRecipient(id: "r2-0"); try s.ctx.save() }
            lines.append("lone contact delete via removeRecipient: \(o3.line)")
        }
        do { // small-table delete, and whether a fingerprint of that table moves
            let s = try scratchStore("p2-small")
            func fingerprint() -> String {
                let rows = (try? s.ctx.fetch(FetchDescriptor<OrgReachabilityAnswer>())) ?? []
                return "\(rows.count)|" + rows.map(\.orgKey).sorted().joined(separator: ",")
            }
            let before = fingerprint()
            let o = try await observe(s) { s.ctx.delete(s.answer); try s.ctx.save() }
            let after = fingerprint()
            #expect(before != after, "deleting an answer did not move the small-table fingerprint")
            lines.append("small-table delete (answer): fingerprint moved \(before != after); \(o.line)")
        }
        do { // an inquiry inserted, edited, deleted
            let s = try scratchStore("p2-inquiry")
            let fresh = Inquiry(source: .contactForm, inquirerName: "Bea", inquirerEmail: "bea@example.org",
                                eventName: "Recital", performanceDate: "2027-03-01", venue: "Hall", notes: nil)
            let o1 = try await observe(s) { s.ctx.insert(fresh); try s.ctx.save() }
            lines.append("inquiry insert: \(o1.line)")
            let o2 = try await observe(s) { s.inquiry.inquirerName = "Ada B"; try s.ctx.save() }
            lines.append("inquiry edit: \(o2.line)")
            let o3 = try await observe(s) { s.ctx.delete(s.inquiry); try s.ctx.save() }
            lines.append("inquiry delete: \(o3.line)")
        }
        do { // a unique naturalKey upsert
            let s = try scratchStore("p2-upsert")
            let oldID = s.shows[0].persistentModelID
            let o = try await observe(s) {
                let twin = Prospect(naturalKey: "probe-0", groupName: "Upserted", discipline: "music",
                                    venue: "Hall 0", performanceDate: "2027-01-01", sourceListingURL: nil,
                                    priorRelationship: "none", production: "presenter", profile: "strong",
                                    coverage: "likely_uncovered", fitScore: 9, tier: "mid", fitReason: "r",
                                    matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                                    status: .drafted)
                s.ctx.insert(twin)
                try s.ctx.save()
            }
            let rows = try s.ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == "probe-0" }))
            let reportedInserted = o.saves.contains { $0.ids.contains { $0.key.contains("inserted") && $0.value["Prospect"] == 1 } }
            #expect(o.showFires.isEmpty && s.shows[0].fitScore == 9 && rows.first?.persistentModelID == oldID && reportedInserted,
                    "PINNED 2026-09-26: a unique naturalKey upsert changed the held row IN PLACE, kept its PID, reported it as INSERTED, and fired NO tracker")
            lines.append("naturalKey upsert: rows with the key after save \(rows.count), same PID "
                         + "\(rows.first?.persistentModelID == oldID), held instance now reads "
                         + "fitScore \(s.shows[0].fitScore) (was 5); \(o.line)")
        }
        do { // a contact moved between shows
            let s = try scratchStore("p2-move")
            let o = try await observe(s) {
                let moved = s.shows[0].recipients[0]
                s.shows[0].recipients.removeAll { $0 === moved }
                s.shows[3].recipients.append(moved)
                try s.ctx.save()
            }
            #expect(o.showFires == [0, 3], "PINNED 2026-09-26: moving a contact fired both the old and the new parent")
            lines.append("contact moved from show 0 to show 3: \(o.line)")
        }
        do { // temporary to permanent identifier on first save
            let s = try scratchStore("p2-temp")
            let p = Prospect(naturalKey: "probe-new", groupName: "New", discipline: "music", venue: "Hall",
                             performanceDate: "2027-04-01", sourceListingURL: nil, priorRelationship: "none",
                             production: "presenter", profile: "strong", coverage: "likely_uncovered",
                             fitScore: 5, tier: "mid", fitReason: "r", matchedClientName: nil,
                             possibleMatchSource: nil, possibleMatchName: nil, status: .drafted)
            s.ctx.insert(p)
            let before = p.persistentModelID
            try s.ctx.save()
            let after = p.persistentModelID
            let viaModel = s.ctx.model(for: before) as? Prospect
            let viaRegistered: Prospect? = s.ctx.registeredModel(for: before)
            let viaFetch = try s.ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.persistentModelID == before }))
            #expect(before != after && viaModel !== p && viaFetch.isEmpty,
                    "PINNED 2026-09-26: an identifier captured before the first save no longer resolves after it")
            lines.append("temporary PID: identifier changed on first save \(before != after); captured-before "
                         + "resolves via model(for:) to the same object \(viaModel === p), via registeredModel "
                         + "\(viaRegistered === p), via a fetch by identifier \(viaFetch.count) rows")
        }
        do { // insert then delete before any save
            let s = try scratchStore("p2-insdel")
            var dirtyAfter = false
            let o = try await observe(s) {
                let p = Prospect(naturalKey: "probe-gone", groupName: "Gone", discipline: "music", venue: "Hall",
                                 performanceDate: "2027-05-01", sourceListingURL: nil, priorRelationship: "none",
                                 production: "presenter", profile: "strong", coverage: "likely_uncovered",
                                 fitScore: 5, tier: "mid", fitReason: "r", matchedClientName: nil,
                                 possibleMatchSource: nil, possibleMatchName: nil, status: .drafted)
                s.ctx.insert(p)
                s.ctx.delete(p)
                dirtyAfter = s.ctx.hasChanges
                try s.ctx.save()
            }
            lines.append("insert then delete before save: hasChanges before the save \(dirtyAfter); \(o.line)")
        }
        do { // an unsaved main-context insert, seen by a fetch
            let s = try scratchStore("p2-pending")
            let p = Prospect(naturalKey: "probe-pending", groupName: "Pending", discipline: "music", venue: "Hall",
                             performanceDate: "2027-06-01", sourceListingURL: nil, priorRelationship: "none",
                             production: "presenter", profile: "strong", coverage: "likely_uncovered",
                             fitScore: 5, tier: "mid", fitReason: "r", matchedClientName: nil,
                             possibleMatchSource: nil, possibleMatchName: nil, status: .drafted)
            s.ctx.insert(p)
            let seen = try s.ctx.fetch(FetchDescriptor<Prospect>()).count
            var strict = FetchDescriptor<Prospect>()
            strict.includePendingChanges = false
            let unseen = try s.ctx.fetch(strict).count
            let background = try ModelContext(s.container).fetch(FetchDescriptor<Prospect>()).count
            #expect(seen == 5 && unseen == 4 && background == 4,
                    "PINNED 2026-09-26: a main-context fetch sees an unsaved insert; a background context does not")
            lines.append("unsaved insert: main-context fetch sees \(seen) of 5, with includePendingChanges false "
                         + "\(unseen), a background context \(background)")
        }
        do { // didSave synchronous on main, and autosave
            let s = try scratchStore("p2-sync")
            let log = Phase0SaveLog(main: s.ctx)
            s.shows[0].fitReason = "edited"
            try s.ctx.save()
            let immediately = log.take()
            lines.append("explicit main save: didSave already delivered when save() returned "
                         + "\(immediately.count == 1), on main thread \(immediately.first?.onMainThread ?? false)")
            let fires = Phase0FireLog()
            phase0ArmTrackers(s.shows, log: fires)
            s.ctx.autosaveEnabled = true
            s.shows[1].fitReason = "autosaved"
            let deadline = Phase0.now() + 15_000_000_000
            var autosaves: [Phase0SaveLog.Entry] = []
            while autosaves.isEmpty && Phase0.now() < deadline {
                try? await Task.sleep(for: .milliseconds(100))
                autosaves = log.take()
            }
            let snap = fires.snapshot
            lines.append("autosave: arrived within 15 s \(!autosaves.isEmpty), "
                         + "\(autosaves.map(\.description).joined(separator: " | ")); tracker fires off main \(snap.offMain) of \(snap.total)")
        }
        do { // a save through another context: does the main context's tracker fire, where, and is it stale
            let s = try scratchStore("p2-foreign")
            let log = Phase0SaveLog(main: s.ctx)
            let fires = Phase0FireLog()
            phase0ArmTrackers(s.shows, log: fires)
            let id = s.shows[0].persistentModelID
            let container = s.container
            let wrote: Bool = await phase0OnThread("phase0-foreign") {
                let other = ModelContext(container)
                guard let row = other.model(for: id) as? Prospect else { return false }
                row.fitReason = "written elsewhere"
                return (try? other.save()) != nil
            }
            await settle()
            let snap = fires.snapshot
            #expect(snap.rows.isEmpty && s.shows[0].fitReason != "written elsewhere",
                    "PINNED 2026-09-26: a save through another context fired no main tracker and left the main instance stale")
            lines.append("foreign save (background context, own thread): wrote \(wrote); main tracker fired "
                         + "\(snap.rows.sorted()) off main \(snap.offMain); main instance reads fresh value "
                         + "\(s.shows[0].fitReason == "written elsewhere"); \(log.take().map(\.description).joined(separator: " | "))")
        }
        for candidate in ["refetch by identifier", "registeredModel", "rollback"] { // forcing a fresh read
            let s = try scratchStore("p2-refault-\(candidate.prefix(4))")
            let held = s.shows[0]
            _ = held.fitReason
            let id = held.persistentModelID
            let container = s.container
            _ = await phase0OnThread("phase0-refault") {
                let other = ModelContext(container)
                if let row = other.model(for: id) as? Prospect { row.fitReason = "written elsewhere"; try? other.save() }
                return true
            }
            await settle()
            let staleBefore = held.fitReason != "written elsewhere"
            var fresh = false, sameObject = false
            switch candidate {
            case "refetch by identifier":
                let got = try s.ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.persistentModelID == id }))
                sameObject = got.first === held
                fresh = got.first?.fitReason == "written elsewhere"
            case "registeredModel":
                let got: Prospect? = s.ctx.registeredModel(for: id)
                sameObject = got === held
                fresh = got?.fitReason == "written elsewhere"
            default:
                s.ctx.rollback()
                sameObject = true
                fresh = held.fitReason == "written elsewhere"
            }
            #expect(fresh == (candidate == "refetch by identifier"),
                    "PINNED 2026-09-26: only a refetch by identifier refreshed a stale main instance; registeredModel and rollback did not")
            lines.append("refault candidate '\(candidate)': held instance stale before \(staleBefore); "
                         + "candidate returned the same object \(sameObject), reads the saved value \(fresh), "
                         + "held instance now reads the saved value \(held.fitReason == "written elsewhere")")
        }
        do { // resolving an identifier on the main context: a deleted row
            let s = try scratchStore("p2-resolve")
            let id = s.shows[3].persistentModelID
            s.ctx.delete(s.shows[3])
            try s.ctx.save()
            let registered: Prospect? = s.ctx.registeredModel(for: id)
            let viaModel = s.ctx.model(for: id)
            #expect(registered == nil && StoreRows.isLive(viaModel),
                    "PINNED 2026-09-26: model(for:) on a deleted, saved row returns a model StoreRows.isLive calls live")
            lines.append("deleted row: registeredModel returns \(registered == nil ? "nil" : "a model"); model(for:) "
                         + "returns a model that is live by StoreRows.isLive \(StoreRows.isLive(viaModel)), "
                         + "isDeleted \(viaModel.isDeleted), has a context \(viaModel.modelContext != nil)")
        }
        Phase0.say("p2 scratch store\n  " + lines.joined(separator: "\n  "))
    }

    // MARK: - Probes 2a, 2b, 2c: per-row trackers against the whole-table fetches that stay, on the clone

    @Test(.enabled(if: Phase0.liveStoreExists, "no live store on this machine"))
    func probe2abcPerRowIntakeOnTheClone() async throws {
        if skip("probe 2a/2b/2c") { return }
        let container = try Phase0.openContainer(at: try clone("phase0-p2abc"))
        let ctx = container.mainContext
        let saves = Phase0SaveLog(main: ctx)
        let rows = try ctx.fetch(FetchDescriptor<Prospect>())
        for r in rows { _ = r.recipients.count }
        let edited = rows.count / 2
        var lines: [String] = []

        func fires(_ label: String, _ act: () throws -> Void) async rethrows -> Int {
            let log = Phase0FireLog()
            phase0ArmTrackers(rows, log: log)
            _ = saves.take()
            try act()
            await settle()
            let s = log.snapshot
            let saveText = saves.take().map(\.description).joined(separator: " | ")
            lines.append("\(label): \(s.rows.count) of \(rows.count) trackers fired (off main \(s.offMain))"
                         + (saveText.isEmpty ? "" : "; \(saveText)"))
            return s.rows.count
        }

        // 2a: one field on one row, then a save.
        var atMutation = 0
        let log2a = Phase0FireLog()
        phase0ArmTrackers(rows, log: log2a)
        rows[edited].fitReason += " "
        atMutation = log2a.snapshot.rows.count
        try ctx.save()
        await settle()
        let after2a = log2a.snapshot
        lines.append("2a one field saved on one row: \(atMutation) fired at the write, \(after2a.rows.count) of "
                     + "\(rows.count) after the save (the edited row fired \(after2a.rows.contains(edited))); "
                     + saves.take().map(\.description).joined(separator: " | "))

        // 2b: the whole-table main-context fetches that stay in the product.
        let b1 = await fires("2b StoreRows.fetch shape, no save since arming") { _ = StoreRows.fetch(from: ctx) }
        rows[edited].fitReason += " "
        try ctx.save()
        let b2 = await fires("2b StoreRows.fetch shape, straight after a one-row save") { _ = StoreRows.fetch(from: ctx) }
        let scheduler = ReconcileScheduler(context: ctx, replyRunAlive: { _ in false })
        let defaults = scratchDefaults()
        let b3 = await fires("2b republishDueBadge shape (Prospect + Inquiry)") {
            _ = scheduler.republishDueBadge(now: Date(), defaults: defaults)
        }

        // 2c: the tick's store-touching passes over an unchanged feed, twice (the second is the unchanged one).
        let export = try scratchExport()
        var c2 = 0
        for round in 1...2 {
            let before = rows.map(phase0Values)
            let log = Phase0FireLog()
            phase0ArmTrackers(rows, log: log)
            _ = saves.take()
            let tickRows = StoreRows.fetch(from: ctx)
            scheduler.reconcileBookings(now: Date(), from: export, rows: tickRows)
            scheduler.reapplyConflicts(now: Date(), from: export, prospects: tickRows.liveProspects)
            scheduler.retireShowsThatOpened(now: Date())
            _ = scheduler.republishDueBadge(now: Date(), defaults: defaults)
            await settle()
            let changed = zip(before, rows.map(phase0Values)).filter { $0 != $1 }.count
            let s = log.snapshot
            if round == 2 { c2 = s.rows.count }
            lines.append("2c local tick passes, round \(round): \(s.rows.count) of \(rows.count) trackers fired, "
                         + "\(changed) rows changed value; "
                         + saves.take().map(\.description).joined(separator: " | "))
        }
        lines.append("2c NOT RUN: the Gmail reply check, threading repair, proposal sweep, signature refresh and "
                     + "OmniFocus sync, which reach real services a test must not touch (L2)")
        Phase0.say("p2abc [live clone] \(rows.count) shows, \(Phase0.load())\n  " + lines.joined(separator: "\n  "))
        #expect(after2a.rows.contains(edited), "the positive control: the edited row's own tracker did not fire")
        #expect(b1 == 0 && b2 == 0 && b3 == 0,
                "PINNED 2026-09-26: a whole-table main-context fetch (StoreRows.fetch, republishDueBadge) fired no per-row tracker")
        #expect(c2 == 0, "PINNED 2026-09-26: a second local tick over an unchanged feed fired no per-row tracker")
    }

    // MARK: - Probe 3: the verifier's cost on its own thread, and what it does to the main thread

    @Test(.enabled(if: Phase0.liveStoreExists, "no live store on this machine"))
    func probe3VerifierCost() async throws {
        if skip("probe 3") { return }
        for (label, url) in try corpora("phase0-p3") {
            let container = try Phase0.openContainer(at: url)
            // One verifier run: fetch through a fresh context, extract, the model-direct card sample, the
            // cold ProducerTables, and today's scope over the fetched models as the stand-in for "a full pass"
            // (the value pass does not exist yet), all on a dedicated thread.
            @Sendable func run() -> [String: Double] {
                var laps: [String: Double] = [:]
                var t = Phase0.now()
                let c = ModelContext(container)
                let rows = (try? c.fetch(FetchDescriptor<Prospect>())) ?? []
                let inquiries = (try? c.fetch(FetchDescriptor<Inquiry>())) ?? []
                let answers = (try? c.fetch(FetchDescriptor<OrgReachabilityAnswer>())) ?? []
                let sources = (try? c.fetch(FetchDescriptor<WatchedSource>())) ?? []
                laps["fetch"] = Phase0.ms(since: t); t = Phase0.now()
                _ = rows.map(probeExtractProspect).count
                _ = inquiries.map(probeExtractInquiry).count
                laps["extract"] = Phase0.ms(since: t); t = Phase0.now()
                for p in rows.prefix(40) { _ = QueueItem(p) }
                laps["card sample (40)"] = Phase0.ms(since: t); t = Phase0.now()
                let shows = rows.map { ProducerGate.Show(presenter: $0.presenter, venue: $0.venue) }
                _ = QueueModel.ProducerTables(shows: shows, overrides: .none)
                laps["ProducerTables cold"] = Phase0.ms(since: t); t = Phase0.now()
                _ = QueueModel.scope(from: QueueModel.queueScope(rows), answers: answers, corpus: rows,
                                     sources: sources, cardKeys: [])
                laps["scope over models (pass stand-in)"] = Phase0.ms(since: t)
                return laps
            }
            _ = await phase0OnThread("phase0-verifier-warm") { run() }

            // The async burst's latency, idle, five times.
            func burst() async -> Double {
                await withTaskGroup(of: Double.self) { group in
                    for _ in 0..<100 {
                        let t0 = Phase0.now()
                        group.addTask { Phase0.ms(since: t0) }
                    }
                    var all: [Double] = []
                    for await v in group { all.append(v) }
                    return all.sorted()[all.count / 2]
                }
            }
            var idle: [Double] = []
            for _ in 0..<5 { idle.append(await burst()) }

            // Five runs, each with a main-thread gap monitor and a burst beside it.
            var walls: [Double] = []
            var gaps: [Double] = []
            var busyBursts: [Double] = []
            var lapsAll: [[String: Double]] = []
            for _ in 0..<5 {
                let start = Phase0.now()
                let task = Task.detached { await phase0OnThread("phase0-verifier") { run() } }
                var worstGap = 0.0
                var burstDone = false
                while true {
                    let t0 = Phase0.now()
                    try? await Task.sleep(for: .milliseconds(2))
                    worstGap = max(worstGap, Phase0.ms(since: t0) - 2)
                    if !burstDone { busyBursts.append(await burst()); burstDone = true }
                    if Phase0.ms(since: start) > 60_000 { break }
                    if await isFinished(task) { break }
                }
                let laps = await task.value
                walls.append(Phase0.ms(since: start))
                gaps.append(worstGap)
                lapsAll.append(laps)
            }
            let lapText = lapsAll.first!.keys.sorted().map { k in
                "\(k) \(Phase0.Reading(runs: lapsAll.map { $0[k] ?? 0 }).text)"
            }.joined(separator: "; ")
            Phase0.say("""
                p3 [\(label)] \(Phase0.load())
                  run wall time            \(Phase0.Reading(runs: walls).text), max \(String(format: "%.1f", walls.max() ?? 0)) ms
                  stages                   \(lapText)
                  worst main-thread gap beyond a 2 ms sleep, per run \(Phase0.Reading(runs: gaps).text)
                  async burst median latency idle   \(Phase0.Reading(runs: idle).text)
                  async burst median latency during \(Phase0.Reading(runs: busyBursts).text)
                  value pass on the verifier thread UNMEASURED: the pass is @MainActor over models today
                """)
        }
    }

    private func isFinished<T>(_ task: Task<T, Never>) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { _ = await task.value; return true }
            group.addTask { try? await Task.sleep(for: .milliseconds(1)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    // MARK: - Probe 4: every reader's derivation and every writer's own main-actor work

    @Test(.enabled(if: Phase0.liveStoreExists, "no live store on this machine"))
    func probe4ReadersAndWriters() async throws {
        if skip("probe 4") { return }
        let export = try scratchExport()
        let loaded = DownbeatBridge.loadWithHealth(from: export, now: Date())
        let exportTuple: DayOffEditing.Export = (loaded.bookings, loaded.blockedDates, loaded.health)
        for (label, url) in try corpora("phase0-p4") {
            let container = try Phase0.openContainer(at: url)
            let ctx = container.mainContext
            let rows = try ctx.fetch(FetchDescriptor<Prospect>())
            let inquiries = try ctx.fetch(FetchDescriptor<Inquiry>())
            let sources = try ctx.fetch(FetchDescriptor<WatchedSource>())
            for r in rows { _ = r.recipients.count }
            let now = Date()
            let context = StageContext(geo: .none, clients: .none)
            let allRows = Phase0.median5 { _ = rows.map { QueueScopeRow($0, facts: RecipientFacts.of($0)) }.count }
            let searchable = Phase0.median5 {
                let kept = rows.filter { $0.status != .dismissed }
                let reached = Set(ReachedOutQueue.active(from: kept, now: now).map(\.prospect.naturalKey))
                let scope = StageNavigation.stagedKeys(in: kept, reachedOutKeys: reached, context: context)
                _ = rows.map { QueueScopeRow($0, facts: RecipientFacts.of($0)) }.filter { scope.contains($0.id) }.count
            }
            let reprepEligible = Phase0.median5 { _ = ProspectMutations.bulkReprepEligible(rows, now: now).count }
            let bounces = Phase0.median5 { _ = BounceDetection.unresolvedBounces(in: rows).count }
            let toPrep = Phase0.median5 {
                let byStatus = (try? ctx.fetch(FetchDescriptor<Prospect>(predicate: PrepQueueBuilder.needsPrepPredicate))) ?? []
                _ = PrepQueueBuilder.eligible(byStatus, today: QueueModel.easternToday()).count
            }
            let items = Phase0.median5 { _ = QueueModel.items(from: rows, corpus: rows, sources: sources).count }
            let archive = Phase0.median5 { _ = QueueModel.scope(from: rows, sources: sources, cardKeys: []) }
            let due = Phase0.median5 {
                _ = DueWork.countAndNextChange(prospects: rows, inquiries: inquiries, now: now, replyRunAlive: false)
            }
            let followUps = Phase0.median5 {
                _ = FollowUpsRenderPass.make(FollowUpsRenderPass.Inputs(
                    prospects: FollowUpsRenderPass.Corpus(rows), inquiries: inquiries, sources: sources,
                    now: now, replyRunAlive: false))
            }
            let sourcesSheet = Phase0.median5 {
                _ = SourcesRenderPass.make(SourcesRenderPass.Inputs(
                    prospects: SourcesRenderPass.Corpus(rows), sources: sources, searchQuery: "",
                    context: StageContext(now: now, geo: .none, clients: .none)))
            }
            // The small-table refetch after a save, in the same context the way @Query does it.
            var smallRuns: [Double] = []
            for i in 0..<5 {
                rows[i].fitReason += " "
                try ctx.save()
                smallRuns.append(Phase0.time {
                    _ = (try? ctx.fetch(FetchDescriptor<OrgReachabilityAnswer>()))?.count
                    _ = (try? ctx.fetch(FetchDescriptor<PromotedProducer>()))?.count
                    _ = (try? ctx.fetch(FetchDescriptor<DemotedHouse>()))?.count
                    _ = (try? ctx.fetch(FetchDescriptor<WatchedSource>()))?.count
                    _ = (try? ctx.fetch(FetchDescriptor<RefusedContactAddress>()))?.count
                    _ = (try? ctx.fetch(FetchDescriptor<Inquiry>()))?.count
                    _ = (try? ctx.fetch(FetchDescriptor<ExcludedTown>()))?.count
                    _ = (try? ctx.fetch(FetchDescriptor<AllowedSeedTown>()))?.count
                })
            }
            // Writers' own main-actor work before and including their save.
            let scheduler = ReconcileScheduler(context: ctx, replyRunAlive: { _ in false })
            let defaults = scratchDefaults()
            let openingFetch = Phase0.median5 { _ = StoreRows.fetch(from: ctx).prospects.count }
            let badge = Phase0.median5 { _ = scheduler.republishDueBadge(now: now, defaults: defaults) }
            // A whole night dismissed, five different nights, each its own sample.
            var perNight: [String: [String]] = [:]
            for r in rows where r.status != .dismissed { perNight[r.performanceDate ?? "", default: []].append(r.naturalKey) }
            let nights = perNight.filter { !$0.key.isEmpty && $0.value.count >= 3 }.sorted { $0.value.count > $1.value.count }.prefix(5)
            var dismissRuns: [Double] = []
            var dismissSizes: [Int] = []
            for (night, keys) in nights {
                dismissSizes.append(keys.count)
                dismissRuns.append(Phase0.time {
                    ProspectMutations.dismissAll(keys, reason: .pitchingOtherShows, dateLabel: night, prospects: rows,
                                                 context: ctx, feedback: ActionFeedback(), now: now,
                                                 export: exportTuple)
                })
            }
            let reprepCount = ProspectMutations.bulkReprepEligible(rows, now: now).count
            let reprep = Phase0.time {
                ProspectMutations.bulkReprep(.draftOnly, prospects: rows, context: ctx, feedback: ActionFeedback(), now: now)
            }
            Phase0.say("""
                p4 [\(label)] \(rows.count) shows, \(Phase0.load())
                  readers (RootView and siblings, over rows already in memory):
                    allRows (QueueScopeRow per show)         \(allRows.text)
                    searchableRows (stagedKeys + rows)       \(searchable.text)
                    bulkReprepEligible                       \(reprepEligible.text)
                    BounceDetection.unresolvedBounces        \(bounces.text)
                    toPrep (status fetch + eligible)          \(toPrep.text)
                    QueueModel.items (a card for every show) \(items.text)
                    Archive scope over every show            \(archive.text)
                    Due count (countAndNextChange)           \(due.text)
                    FollowUpsRenderPass.make                 \(followUps.text)
                    SourcesRenderPass.make                   \(sourcesSheet.text)
                    eight small-table refetches after a save  \(Phase0.Reading(runs: smallRuns).text)
                    UNMEASURED: OrganisationsView, OutcomePatternsView and WrittenOffBacklogSection, StruckAddressesView, ExperimentReportView, EmptyAnswerSection, PrepSelectionSheet derive inside their bodies with no entry point a test can call
                  writers (own main-actor work, including their save):
                    reconcile opening read (StoreRows.fetch)  \(openingFetch.text)
                    republishDueBadge                         \(badge.text)
                    whole-night dismiss, nights of \(dismissSizes) shows  \(Phase0.Reading(runs: dismissRuns.isEmpty ? [0] : dismissRuns).text)
                    bulk reprep of \(reprepCount) shows, one run          \(String(format: "%.1f", reprep)) ms
                    scout block landing: see probe 6
                """)
        }
    }

    // MARK: - Probe 6: what a scout block landing marks updated when it re-lands unchanged shows

    @Test(.enabled(if: Phase0.liveStoreExists, "no live store on this machine"))
    func probe6ScoutUpsert() async throws {
        if skip("probe 6") { return }
        // The RELEASE app's last results file, copied into the sandbox before it is read. The decoder's own
        // `defaultURL` resolves to the test process's handoff folder, which holds nothing.
        let live = StoreLocation.handoffDirectory(appSupport: StoreLocation.appSupport, isDebugBuild: false)
            .appendingPathComponent("overture-scout-extract-results.json")
        let copy = try sandboxes.make(named: "phase0-p6-results").appendingPathComponent("results.json")
        try? FileManager.default.copyItem(at: live, to: copy)
        guard let data = try? Data(contentsOf: copy),
              let results = try? ScoutExtractResultsDecoder.decode(data) else {
            Phase0.say("p6 UNMEASURED: no readable scout extract results on this machine")
            return
        }
        let container = try Phase0.openContainer(at: try clone("phase0-p6"))
        let ctx = container.mainContext
        let saves = Phase0SaveLog(main: ctx)
        let events = results.results.reduce(0) { $0 + $1.events.count }
        var lines: [String] = []
        for round in 1...3 {
            let rows = try ctx.fetch(FetchDescriptor<Prospect>())
            for r in rows { _ = r.recipients.count }
            let before = Dictionary(rows.map { ($0.persistentModelID, phase0Values($0)) }, uniquingKeysWith: { a, _ in a })
            let log = Phase0FireLog()
            phase0ArmTrackers(rows, log: log)
            _ = saves.take()
            let start = Phase0.now()
            let outcome = await ScoutExtractIngest.ingest(results, clients: [], history: [], blocked: .empty,
                                                          into: ctx)
            let wall = Phase0.ms(since: start)
            await settle()
            let after = try ctx.fetch(FetchDescriptor<Prospect>())
            let changed = after.filter { p in before[p.persistentModelID].map { $0 != phase0Values(p) } ?? false }.count
            // WHICH show fields moved, by name only, counted over the rows that changed.
            let names = Prospect.scopeFields.filter { $0.keyPath != \Prospect.recipients as AnyKeyPath }
                .map { String(describing: $0.keyPath).replacingOccurrences(of: "\\Prospect.", with: "") }
            var moved: [String: Int] = [:]
            for p in after {
                guard let old = before[p.persistentModelID] else { continue }
                let new = phase0Values(p)
                for (i, name) in names.enumerated() where i < old.count && i < new.count && old[i] != new[i] {
                    moved[name, default: 0] += 1
                }
                if old.count != new.count || old.dropFirst(names.count) != new.dropFirst(names.count) {
                    moved["(contact fields)", default: 0] += 1
                }
            }
            let movedText = moved.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            let entries = saves.take()
            let updatedShows = entries.reduce(0) { total, e in
                total + e.ids.filter { $0.key.lowercased().contains("updated") }.reduce(0) { $0 + ($1.value["Prospect"] ?? 0) }
            }
            let s = log.snapshot
            lines.append("round \(round): \(String(format: "%.1f", wall)) ms wall (awaits included), outcome "
                         + "inserted \(outcome.inserted) updated \(outcome.updated) skipped \(outcome.skipped); "
                         + "trackers fired \(s.rows.count) of \(rows.count); rows whose values changed \(changed); "
                         + "didSave updated shows \(updatedShows) over \(entries.count) saves; fields that moved: \(movedText)")
        }
        Phase0.say("p6 [live clone] \(results.results.count) sources, \(events) events, \(Phase0.load())\n  "
                   + lines.joined(separator: "\n  "))
    }

    // MARK: - Probe 8: filling the main context's members at launch, four ways

    @Test(.enabled(if: Phase0.liveStoreExists, "no live store on this machine"))
    func probe8LaunchMemberFill() async throws {
        if skip("probe 8") { return }
        for (label, url) in try corpora("phase0-p8") {
            // (a) one main-context whole fetch, then arming every row. A fresh container per sample, so
            // nothing is registered in the main context when it starts.
            var aFetch: [Double] = [], aArm: [Double] = []
            for _ in 0..<5 {
                let c = try Phase0.openContainer(at: url)
                var rows: [Prospect] = []
                aFetch.append(Phase0.time { rows = (try? c.mainContext.fetch(FetchDescriptor<Prospect>())) ?? [] })
                aArm.append(Phase0.time { phase0ArmTrackers(rows, log: Phase0FireLog()) })
            }
            // (b) background fetch and extraction, then re-resolving every identifier on main, then arming.
            var bBackground: [Double] = [], bResolve: [Double] = [], bArm: [Double] = []
            for _ in 0..<5 {
                let c = try Phase0.openContainer(at: url)
                let t0 = Phase0.now()
                let ids: [PersistentIdentifier] = await phase0OnThread("phase0-launch-read") {
                    let bg = ModelContext(c)
                    let rows = (try? bg.fetch(FetchDescriptor<Prospect>())) ?? []
                    _ = rows.map(probeExtractProspect).count
                    return rows.map(\.persistentModelID)
                }
                bBackground.append(Phase0.ms(since: t0))
                var rows: [Prospect] = []
                bResolve.append(Phase0.time { rows = ids.compactMap { c.mainContext.model(for: $0) as? Prospect }.map { p in _ = p.naturalKey; return p } })
                bArm.append(Phase0.time { phase0ArmTrackers(rows, log: Phase0FireLog()) })
            }
            // (c) sorted main-context fetches in batches, each batch arming its rows.
            var cLines: [String] = []
            for size in [25, 50, 100, 200] {
                var totals: [Double] = [], worst: [Double] = []
                var batches = 0
                for _ in 0..<5 {
                    let c = try Phase0.openContainer(at: url)
                    var offset = 0, total = 0.0, largest = 0.0
                    batches = 0
                    while true {
                        var d = FetchDescriptor<Prospect>(sortBy: [SortDescriptor(\Prospect.naturalKey)])
                        d.fetchOffset = offset
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
                        offset += got.count
                    }
                    totals.append(total)
                    worst.append(largest)
                }
                cLines.append("batch \(size): \(batches) batches, total \(Phase0.Reading(runs: totals).text), largest batch \(Phase0.Reading(runs: worst).text)")
            }
            // (d) one row resolved on demand through model(for:), nothing registered, then armed.
            var dRuns: [Double] = []
            for i in 0..<5 {
                let c = try Phase0.openContainer(at: url)
                let ids: [PersistentIdentifier] = await phase0OnThread("phase0-ids") {
                    ((try? ModelContext(c).fetch(FetchDescriptor<Prospect>())) ?? []).map(\.persistentModelID)
                }
                let id = ids[(ids.count / 7) * (i + 1)]
                dRuns.append(Phase0.time {
                    if let p = c.mainContext.model(for: id) as? Prospect {
                        _ = p.naturalKey
                        phase0ArmTrackers([p], log: Phase0FireLog())
                    }
                })
            }
            Phase0.say("""
                p8 [\(label)] \(Phase0.load())
                  (a) one main fetch        fetch \(Phase0.Reading(runs: aFetch).text), arm every row \(Phase0.Reading(runs: aArm).text)
                  (b) background then resolve  background read + extract (off main) \(Phase0.Reading(runs: bBackground).text), resolve every PID on main \(Phase0.Reading(runs: bResolve).text), arm \(Phase0.Reading(runs: bArm).text)
                  (c) sorted batches on main, each batch fetched and armed:
                      \(cLines.joined(separator: "\n      "))
                  (d) one row on demand through model(for:), resolved and armed \(Phase0.Reading(runs: dRuns).text)
                """)
        }
    }
}
