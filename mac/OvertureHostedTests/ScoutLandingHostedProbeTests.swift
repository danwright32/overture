import Testing
import Foundation
import AppKit
import SwiftUI
import SwiftData
import SQLite3
import Observation
@testable import Overture

// #4327 steps 0.2 and 0.9: what RootView's real queries do when the store changes under a landing.
//
// MEASUREMENT ONLY, and OPT IN, for the reason every Phase 0 probe is: each arm holds a window open for a
// deadline, and step 0.2 switches autosave ON, which is the setting that killed the shared test host between
// tests in #3874. So nothing runs without the variable, and saying so is printed rather than passing quietly:
//
//   TEST_RUNNER_MEASURE_4327_PHASE0=1 mac/scripts/run-tests-locked.sh \
//     -only-testing:OvertureHostedTests/ScoutLandingHostedProbeTests
//
// Run it SCOPED. The refetch reading comes from `QueueRenderCounter`'s root surface, which is process wide,
// and the one other suite hosting RootView (`BringingTheQueueUpTests`) would add its own renders to it.
//
// THE INSTRUMENT, and why it can be believed. A `@Query` refetch leaves nothing a test can read directly,
// and a refetch that returns the rows it already had changes nothing a view shows. So every arm PLANTS a
// row: a copy of a stored show written straight into the store file through SQLite, underneath the
// context, which is never told. Only a fetch that really reaches the store can return it, so RootView's
// `allProspects` count moving (the `allProspects` reason on its own render trace, #1930) means its Prospect
// queries refetched. Two controls are ASSERTED, so a zero cannot be a probe that could not see (L159, L98):
//
//   NULL      planted, nothing else done: the count must NOT move. Without this, a store that noticed the
//             planted row on its own would make every arm read "refetched".
//   POSITIVE  planted, then a Prospect edited and saved: the count MUST move. Without this, "no refetch"
//             could be a planted row the query would never have returned anyway.
//
// Each arm gets a fresh store and a fresh window, so no arm inherits another's pending state or tracking.
@MainActor
@Suite("What RootView's queries do under a landing's writes (#4327 steps 0.2 and 0.9)", .serialized)
final class ScoutLandingHostedProbeTests {

    private let sandboxes = TemporarySandboxes()

    nonisolated static var enabled: Bool { ProcessInfo.processInfo.environment["MEASURE_4327_PHASE0"] != nil }

    private func skip(_ step: String) -> Bool {
        guard Self.enabled else {
            print("step-\(step): not measured. Set TEST_RUNNER_MEASURE_4327_PHASE0=1 to run it.")
            return true
        }
        // A locked session never lays the window out, so every arm would read zero (#3842, L11).
        guard !ScreenSession.isLocked else {
            ScreenSession.reportUnmeasured("ScoutLandingHostedProbeTests step \(step)")
            return true
        }
        return false
    }

    private static let seededShows = 30
    private static var rigsMade = 0
    private static let root = QueueRenderCounter.rootSurface

    // MARK: - The rig

    @MainActor
    private final class Rig {
        let container: ModelContainer
        let ctx: ModelContext
        let url: URL
        let window: NSWindow
        let hosting: NSHostingView<RootHarness>
        let held: [Prospect]
        let source: WatchedSource
        init(container: ModelContainer, url: URL, window: NSWindow, hosting: NSHostingView<RootHarness>,
             held: [Prospect], source: WatchedSource) {
            self.container = container
            self.ctx = container.mainContext
            self.url = url
            self.window = window
            self.hosting = hosting
            self.held = held
            self.source = source
        }
    }

    private func pump(_ rig: Rig) {
        rig.hosting.layoutSubtreeIfNeeded()
        rig.hosting.displayIfNeeded()
    }

    private func makeRig(_ name: String) async throws -> Rig {
        let dir = try sandboxes.make(named: "landing-hosted-\(name)")
        let url = dir.appendingPathComponent("probe.store")
        let container = try TestModelContainer.onDisk(AppSchema.models, at: url)
        let ctx = container.mainContext
        // A DIFFERENT number of shows in every rig this process builds. `QueueRenderCounter`'s root trace is
        // process wide and diffs each render against the LAST root render anywhere, so a RootView outliving its
        // window can set the baseline the next arm is judged against. Seen: the 0.9 null arm, mutated to save
        // an insert, read "nothing this view reads" at a count equal to the previous rig's last one, and the null
        // control SURVIVED (L1); a stray render from the previous RootView is the reading that fits every line. Tearing the old RootView down instead crashed the host (a SwiftData
        // observer left behind traps on the next save, the #3874 shape). With counts that never coincide, a
        // stray render can only ADD an `allProspects` reason, which the null arm is there to catch, and can
        // never hide one.
        Self.rigsMade += 1
        let shows = Self.seededShows + 5 * Self.rigsMade
        for n in 0..<shows {
            let p = Prospect(naturalKey: "probe-\(n)", groupName: "Ensemble \(n)", discipline: "music",
                             venue: "Hall \(n % 7)", performanceDate: "2027-0\(1 + n % 9)-1\(n % 9)",
                             sourceListingURL: nil, priorRelationship: "none", production: "presenter",
                             profile: "strong", coverage: "likely_uncovered", fitScore: 5, tier: "mid",
                             fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                             possibleMatchName: nil, status: .new)
            ctx.insert(p)
        }
        let source = WatchedSource(sourceId: "probe-source", orgName: "Probe Presents",
                                   listingsURL: "https://example.test/calendar", kind: .html)
        ctx.insert(source)
        try ctx.save()
        let held = try ctx.fetch(FetchDescriptor<Prospect>())

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        // #3480: AppKit's default releases a window this scope still holds, which crashed the shared host.
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: RootHarness(container: container))
        hosting.frame = window.contentLayoutRect
        hosting.autoresizingMask = [.width, .height]
        // Taken BEFORE the view is added, because its first render can happen inside the layout below.
        let before = QueueRenderCounter.renderCount(for: Self.root)
        window.contentView?.addSubview(hosting)
        window.layoutIfNeeded()
        let rig = Rig(container: container, url: url, window: window, hosting: hosting, held: held,
                      source: source)

        let rendered = await waitUntil("RootView to render at least once", timeout: .seconds(30)) {
            pump(rig)
            return QueueRenderCounter.renderCount(for: Self.root) > before
        }
        #expect(rendered, "RootView never rendered, so nothing below measured anything")
        await settle(rig)
        return rig
    }

    // Until the root has rendered nothing for 25 consecutive polls AND nothing has saved in that time, so an
    // arm starts from a screen and a store at rest rather than from RootView's own launch work (L290).
    private func settle(_ rig: Rig) async {
        let saves = SaveLog(rig.ctx)
        defer { saves.stop() }
        var last = (QueueRenderCounter.renderCount(for: Self.root), 0)
        var quiet = 0
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline && quiet < 25 {
            pump(rig)
            let now = (QueueRenderCounter.renderCount(for: Self.root), saves.count)
            quiet = now == last ? quiet + 1 : 0
            last = now
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func close(_ rig: Rig) {
        // Off again, and nothing left pending, BEFORE the window goes: the #3874 crash is an autosave timer
        // firing into SwiftUI's observer after the test that armed it has ended.
        rig.ctx.autosaveEnabled = false
        if rig.ctx.hasChanges { rig.ctx.rollback() }
        rig.window.close()
    }

    // MARK: - Planting a row underneath the context

    private enum PlantError: Error { case sql(String) }

    // A copy of the first stored show, with the next primary key and a suffixed natural key, written through
    // SQLite and never through SwiftData, so no context, notification or history entry knows it exists.
    private static func plant(into url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw PlantError.sql("open failed")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5_000)
        var columns: [String] = []
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(ZPROSPECT)", -1, &stmt, nil) == SQLITE_OK else {
            throw PlantError.sql("table_info")
        }
        while sqlite3_step(stmt) == SQLITE_ROW { columns.append(String(cString: sqlite3_column_text(stmt, 1))) }
        sqlite3_finalize(stmt)
        guard columns.contains("Z_PK"), columns.contains("ZNATURALKEY") else { throw PlantError.sql("no columns") }
        let exprs = columns.map { c -> String in
            switch c {
            case "Z_PK": return "(SELECT MAX(Z_PK) FROM ZPROSPECT) + 1"
            case "ZNATURALKEY": return "ZNATURALKEY || '-planted'"
            default: return c
            }
        }
        for sql in ["BEGIN IMMEDIATE",
                    "INSERT INTO ZPROSPECT (\(columns.joined(separator: ","))) SELECT \(exprs.joined(separator: ",")) "
                        + "FROM ZPROSPECT ORDER BY Z_PK LIMIT 1",
                    "UPDATE Z_PRIMARYKEY SET Z_MAX = (SELECT MAX(Z_PK) FROM ZPROSPECT) WHERE Z_NAME = 'Prospect'",
                    "COMMIT"] {
            var err: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
                let message = err.map { String(cString: $0) } ?? "unknown"
                sqlite3_free(err)
                throw PlantError.sql(message)
            }
        }
    }

    // MARK: - What an arm watches

    // Every didSave of the main context, with when it arrived.
    private final class SaveLog: @unchecked Sendable {
        private let lock = NSLock()
        private var times: [UInt64] = []
        private var token: NSObjectProtocol?
        init(_ ctx: ModelContext) {
            token = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: ctx,
                                                           queue: nil) { [weak self] _ in
                let t = DispatchTime.now().uptimeNanoseconds
                self?.lock.lock(); self?.times.append(t); self?.lock.unlock()
            }
        }
        var count: Int { lock.lock(); defer { lock.unlock() }; return times.count }
        var first: UInt64? { lock.lock(); defer { lock.unlock() }; return times.first }
        func stop() { if let token { NotificationCenter.default.removeObserver(token) } }
    }

    // One observation tracker per held show, armed on every stored property it has, so a fire names the row
    // and when. Fires once per row, which is all a "did anything fire" reading needs.
    private final class Trackers: @unchecked Sendable {
        private let lock = NSLock()
        private var fired: [Int: UInt64] = [:]
        func record(_ row: Int) {
            let t = DispatchTime.now().uptimeNanoseconds
            lock.lock(); if fired[row] == nil { fired[row] = t }; lock.unlock()
        }
        var rows: Set<Int> { lock.lock(); defer { lock.unlock() }; return Set(fired.keys) }
        var first: UInt64? { lock.lock(); defer { lock.unlock() }; return fired.values.min() }
    }

    private func armTrackers(_ rows: [Prospect]) -> Trackers {
        let log = Trackers()
        for (i, row) in rows.enumerated() {
            withObservationTracking {
                var seen = Set<ObjectIdentifier>()
                row.armAll(seen: &seen)
            } onChange: {
                log.record(i)
            }
        }
        return log
    }

    // RootView's renders since a baseline, with the reason each gave and when it was seen.
    private struct RootRenders {
        var renders = 0
        var reasons: [String] = []
        var firstRefetch: UInt64?
        var refetched: Bool { firstRefetch != nil }
    }

    private func sample(_ into: inout RootRenders, since base: Int) {
        let total = QueueRenderCounter.renderCount(for: Self.root) - base
        guard total > into.renders else { return }
        let fresh = total - into.renders
        let kept = QueueRenderCounter.reasons(for: Self.root)
        let new = Array(kept.suffix(min(fresh, kept.count)))
        into.renders = total
        into.reasons += new
        if into.firstRefetch == nil,
           new.contains(where: { $0.components(separatedBy: ", ").contains("allProspects") }) {
            into.firstRefetch = DispatchTime.now().uptimeNanoseconds
        }
    }

    // What ScopeMemo decides over the held rows, with the context as it stands. `held` means observation had
    // not marked it stale, `served` that it was stale and served as a refetch, `rebuilt` that it derived again.
    private func memoVerdict(_ memo: ScopeMemo<Int>, _ rig: Rig) -> String {
        let builds = memo.builds, served = memo.servedUnchanged
        var fp = ScopeFingerprint()
        fp.add(rig.held)
        _ = memo.value(fingerprint: fp, cardKeys: [], now: Date(), staleAfter: .never, savesIn: rig.container,
                       onRefetch: .serveWhenNothingChanged) { rig.held.count }
        if memo.builds != builds { return "rebuilt" }
        if memo.servedUnchanged != served { return "served" }
        return "held"
    }

    private struct Reading {
        let arm: String
        let atYield: String
        let window: String
        let refetched: Bool
        let refetchMs: Double?
        let autosaved: Bool
        let saveMs: Double?
        let otherRowsFired: Int
        let fireMs: Double?
    }

    private static func ms(_ t: UInt64?, from start: UInt64) -> Double? {
        t.map { Double(Int64($0) - Int64(start)) / 1_000_000 }
    }

    private static func fmt(_ v: Double?) -> String { v.map { String(format: "%.0f ms", $0) } ?? "never" }

    // One arm: a fresh rig, a planted row, the action, ONE main actor yield (read at once), then the window
    // watched until `stop` holds or it expires.
    private func run(_ arm: String, autosave: Bool, window: Duration,
                     stop: ((RootRenders, SaveLog) -> Bool)? = nil,
                     excludeFromFires: Set<Int> = [],
                     action: (Rig) throws -> Void) async throws -> Reading {
        let rig = try await makeRig(arm)
        defer { close(rig) }
        try Self.plant(into: rig.url)
        let memo = ScopeMemo<Int>()
        _ = memoVerdict(memo, rig)
        let trackers = armTrackers(rig.held)
        let saves = SaveLog(rig.ctx)
        defer { saves.stop() }
        rig.ctx.autosaveEnabled = autosave
        let base = QueueRenderCounter.renderCount(for: Self.root)
        let queueBodies = QueueRenderCounter.renderCount(for: QueueRenderCounter.queueBodySurface)
        let derivations = QueueRenderCounter.derivations
        var renders = RootRenders()

        let start = DispatchTime.now().uptimeNanoseconds
        try action(rig)
        await Task.yield()
        sample(&renders, since: base)
        let atYield = "hasChanges \(rig.ctx.hasChanges), root renders \(renders.renders) "
            + "(refetched \(renders.refetched)), saves \(saves.count), rows fired "
            + "\(trackers.rows.subtracting(excludeFromFires).count), memo \(memoVerdict(memo, rig))"

        let deadline = ContinuousClock.now + window
        while ContinuousClock.now < deadline {
            pump(rig)
            sample(&renders, since: base)
            if let stop, stop(renders, saves) { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let fired = trackers.rows.subtracting(excludeFromFires)
        let windowText = "hasChanges \(rig.ctx.hasChanges), root renders \(renders.renders) reasons "
            + "\(renders.reasons), saves \(saves.count), rows fired \(fired.count) of \(rig.held.count), "
            + "queue bodies \(QueueRenderCounter.renderCount(for: QueueRenderCounter.queueBodySurface) - queueBodies) "
            + "derivations \(QueueRenderCounter.derivations - derivations), memo \(memoVerdict(memo, rig))"
        return Reading(arm: arm, atYield: atYield, window: windowText, refetched: renders.refetched,
                       refetchMs: Self.ms(renders.firstRefetch, from: start), autosaved: saves.count > 0,
                       saveMs: Self.ms(saves.first, from: start), otherRowsFired: fired.count,
                       fireMs: Self.ms(trackers.first, from: start))
    }

    private static func line(_ r: Reading) -> String {
        """
          \(r.arm)
            after one yield: \(r.atYield)
            over the window: \(r.window)
            first refetch \(fmt(r.refetchMs)), first save \(fmt(r.saveMs)), first tracker fire \(fmt(r.fireMs))
        """
    }

    private static func insertUnsaved(_ rig: Rig) {
        rig.ctx.insert(Prospect(naturalKey: "probe-unsaved", groupName: "Unsaved Ensemble", discipline: "music",
                                venue: "Hall 1", performanceDate: "2027-03-03", sourceListingURL: nil,
                                priorRelationship: "none", production: "presenter", profile: "strong",
                                coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                                matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                                status: .new))
    }

    // MARK: - Step 0.2: does anything fire on an unsaved insert after a main actor yield?

    // Decides whether approach B (one save at the end of a split landing) is ever viable, and whether Phase
    // C's rule, a clean context at every yield, is needed. Four arms:
    //
    //   null             autosave off, planted, nothing done                       (asserted: no refetch)
    //   unsaved, off     autosave off, an insert left unsaved over the yield       (approach B's setting)
    //   unsaved, on      autosave ON, the product's setting, the same insert       (asserted: an autosave is seen)
    //   saved            autosave off, the same insert then saved                  (asserted: a refetch is seen)
    @Test func step02AnUnsavedInsertAcrossAMainActorYield() async throws {
        if skip("0.2") { return }
        let null = try await run("null: autosave off, planted, nothing done", autosave: false,
                                 window: .seconds(2)) { _ in }
        let off = try await run("unsaved insert, autosave off", autosave: false,
                                window: .seconds(2)) { Self.insertUnsaved($0) }
        // Watched until the first autosave plus a second beyond it, or 60 s, so what fired BEFORE any save is
        // separated from the refetch the autosave itself causes.
        var sawSaveAt: ContinuousClock.Instant?
        let on = try await run("unsaved insert, autosave ON", autosave: true, window: .seconds(60),
                               stop: { _, saves in
                                   if saves.count > 0, sawSaveAt == nil { sawSaveAt = .now }
                                   return sawSaveAt.map { ContinuousClock.now - $0 > .seconds(1) } ?? false
                               }) { Self.insertUnsaved($0) }
        let saved = try await run("insert then save, autosave off", autosave: false,
                                  window: .seconds(5), stop: { renders, _ in renders.refetched }) { rig in
            Self.insertUnsaved(rig)
            try rig.ctx.save()
        }
        let refetchBeforeAutosave = on.refetchMs.map { r in on.saveMs.map { r < $0 } ?? true } ?? false
        let fireBeforeAutosave = on.fireMs.map { f in on.saveMs.map { f < $0 } ?? true } ?? false
        print("""
        step-0.2 an unsaved Prospect insert across a main actor yield, RootView hosted (\(Self.seededShows) shows plus 5 per rig, on disk)
        \(Self.line(null))
        \(Self.line(off))
        \(Self.line(on))
        \(Self.line(saved))
          ANSWER: with autosave off an unsaved insert refetched \(off.refetched), fired \(off.otherRowsFired) held rows'
          trackers, saved \(off.autosaved); with autosave on, a refetch before the first autosave \(refetchBeforeAutosave),
          a tracker fire before it \(fireBeforeAutosave), the autosave arrived after \(Self.fmt(on.saveMs))
        """)
        #expect(!null.refetched, Comment(rawValue: "NULL CONTROL: the planted row reached RootView with nothing saved, so a "
                + "refetch reading below cannot be told from the store noticing the plant on its own"))
        #expect(saved.refetched, Comment(rawValue: "POSITIVE CONTROL: a saved insert did not refetch RootView's queries, so a "
                + "no-refetch reading cannot be told from an instrument that cannot see one"))
        #expect(on.autosaved, Comment(rawValue: "POSITIVE CONTROL: autosave was switched on and never observed in 60 s, so the "
                + "autosave arm measured a context that does not autosave"))
    }

    // MARK: - Step 0.9: does a save touching only non-Prospect rows refetch RootView's Prospect queries?

    // Sizes A2 and A12 (after A2 a pure re-land's per-source saves carry only WatchedSource rows) and the
    // cost of A6's LandingRun insert. `LandingRun` does not exist yet, so its stand-in is `CancelledShoot`:
    // an independent entity with no relationship to Prospect that no `@Query` anywhere in the app reads,
    // which is the shape A6 gives LandingRun.
    @Test func step09ASaveOfOnlyOtherEntitiesAndRootViewsProspectQueries() async throws {
        if skip("0.9") { return }
        let null = try await run("null: planted, nothing saved", autosave: false, window: .seconds(2)) { _ in }
        let watched = try await run("save of one WatchedSource field", autosave: false, window: .seconds(2)) { rig in
            // Any value the row did not hold (it held nil). From the live clock, as every hosted fixture's instants
            // are (HostedProbeFixturesFollowTheLiveClockTests), so it never drifts into a different state.
            rig.source.lastCheckedAt = LiveClockProbe.fresh
            try rig.ctx.save()
        }
        let landingRun = try await run("save of one inserted CancelledShoot (LandingRun stand in)", autosave: false,
                                       window: .seconds(2)) { rig in
            rig.ctx.insert(CancelledShoot(bookingId: "probe-booking", shootName: "Probe", startDate: "2027-01-01"))
            try rig.ctx.save()
        }
        let prospect = try await run("save of one Prospect field (positive control)", autosave: false,
                                     window: .seconds(5), stop: { renders, _ in renders.refetched },
                                     excludeFromFires: [0]) { rig in
            rig.held[0].fitReason = "edited"
            try rig.ctx.save()
        }
        print("""
        step-0.9 a save touching only other entities, RootView hosted (\(Self.seededShows) shows plus 5 per rig, on disk)
        \(Self.line(null))
        \(Self.line(watched))
        \(Self.line(landingRun))
        \(Self.line(prospect))
          ANSWER: RootView's Prospect queries refetched on a WatchedSource-only save \(watched.refetched), on a
          CancelledShoot-only save \(landingRun.refetched), on a Prospect save \(prospect.refetched)
          (held Prospect trackers fired: \(watched.otherRowsFired), \(landingRun.otherRowsFired), \(prospect.otherRowsFired) other than the edited row)
        """)
        #expect(!null.refetched, "NULL CONTROL: the planted row reached RootView with nothing saved")
        #expect(prospect.refetched, "POSITIVE CONTROL: a Prospect save did not refetch RootView's Prospect queries")
    }
}
