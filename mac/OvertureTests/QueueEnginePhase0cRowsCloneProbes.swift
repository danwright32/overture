import Testing
import Foundation
import SwiftData

// #4106 Phase 0c probes 0c.5 (clone arm), 0c.6 and 0c.10, on a `LiveStoreClone` copy and its fourfold
// corpus. Opt in; see the header of `QueueEnginePhase0cRowsProbeTests.swift` for the variable, the privacy
// rule and the build the timings describe.

/// The pass inputs as the app builds them, read from one context (the same reads Phase 0b's probes make).
@MainActor
struct Phase0cRowsTables {
    let rows: [Prospect]
    let inquiries: [Inquiry]
    let answers: [OrgReachabilityAnswer]
    let sources: [WatchedSource]
    let refusals: ContactRefusal.Ledger
    let overrides: ProducerOverrides
    let geo: GeoRefusals
    let clients: ClientWindow

    init(_ ctx: ModelContext, export: URL) throws {
        rows = try ctx.fetch(FetchDescriptor<Prospect>())
        for r in rows { _ = r.recipients.count }
        sources = try ctx.fetch(FetchDescriptor<WatchedSource>())
        inquiries = try ctx.fetch(FetchDescriptor<Inquiry>())
        answers = try ctx.fetch(FetchDescriptor<OrgReachabilityAnswer>())
        refusals = ContactRefusal.ledger(from: try ctx.fetch(FetchDescriptor<RefusedContactAddress>()))
        overrides = ProducerOverrides(promotedRows: try ctx.fetch(FetchDescriptor<PromotedProducer>()),
                                      demotedRows: try ctx.fetch(FetchDescriptor<DemotedHouse>()))
        geo = GeoRefusals(userExcludedTowns: Set(try ctx.fetch(FetchDescriptor<ExcludedTown>()).map(\.town)),
                          allowedSeedTowns: Set(try ctx.fetch(FetchDescriptor<AllowedSeedTown>()).map(\.town)))
        clients = ClientWindow(sources: sources,
                               clients: DownbeatBridge.loadWithHealth(from: export, now: Date()).clients)
    }

    func stage(_ now: Date) -> StageContext { StageContext(now: now, geo: geo, clients: clients) }

    func rowContext(_ now: Date, alive: Bool = false, geo override: GeoRefusals? = nil) -> Phase0cRowContext {
        let inQueue = rows.filter { $0.statusRaw != "dismissed" }
        let raw = StageContext(now: now, geo: override ?? geo, clients: clients)
        return Phase0cRowContext(stage: raw.resolvingPlaces(of: inQueue), replyRunAlive: alive, inquiries: inquiries)
    }

    func upstream(_ now: Date) -> Phase0cUpstream {
        Phase0cRowOracle.upstream(every: rows, answers: answers, refusals: refusals, overrides: overrides, now: now)
    }

    func oracle(_ now: Date, alive: Bool = false) -> Phase0cRowOracle {
        Phase0cRowOracle(every: rows, inquiries: inquiries, answers: answers, refusals: refusals,
                         overrides: overrides, stage: stage(now), replyRunAlive: alive)
    }
}

extension QueueEnginePhase0cRowsProbeTests {

    func corpora(_ name: String) throws -> [(label: String, url: URL)] {
        let dir = try sandboxes.make(named: name)
        guard let base = try LiveStoreClone.makeClone(in: dir) else {
            throw LiveStoreClone.Refusal.backupFailed("no live store on this machine")
        }
        return [("live clone", base), ("4x", try Phase0.scaledCopy(of: base, factor: 4, in: dir))]
    }

    func scratchExport() throws -> URL {
        let dir = try sandboxes.make(named: "phase0c-rows-export")
        let out = dir.appendingPathComponent("downbeat-export.json")
        if FileManager.default.fileExists(atPath: DownbeatBridge.defaultURL.path) {
            try FileManager.default.copyItem(at: DownbeatBridge.defaultURL, to: out)
        }
        return out
    }

    /// 50 instants from `base`: a pair either side of each DueWork deadline crossing the whole store's
    /// `nextChange` chains to, then pairs either side of the following Eastern midnights.
    static func instants(from base: Date, rows: [Prospect]) -> (all: [Date], crossings: Int) {
        var out: [Date] = [base]
        var t = base
        var crossings = 0
        while out.count < 41, let c = DueWork.nextChange(prospects: rows, now: t, replyRunAlive: false) {
            out.append(c.addingTimeInterval(-1))
            out.append(c.addingTimeInterval(1))
            crossings += 1
            t = c.addingTimeInterval(1)
        }
        var m = base
        while out.count < 50 {
            m = Phase0cRowBuild.nextEasternMidnight(after: m)
            out.append(m.addingTimeInterval(-1))
            if out.count < 50 { out.append(m.addingTimeInterval(1)) }
            m = m.addingTimeInterval(1)
        }
        return (Array(Set(out)).sorted(), crossings)
    }

    // MARK: - 0c.5 on the clone and the 4x corpus

    @Test(.enabled(if: Phase0.liveStoreExists, "no live store on this machine"))
    func probe0c5RowEntriesOnTheClone() throws {
        if skip("0c.5") { return }
        let export = try scratchExport()
        var worstRow = 0.0
        // Gate 0c's rule for a maximum (#4106 comment 5860086027): the median of five replays of the slowest
        // key with the one minute load under 8. Nil once any replay could not be taken under that load.
        var worstReplay: Double? = 0
        // The same rule over a row change that EDITS the draft, so no lint can be reused: without this arm
        // the reuse would be measured only on changes that skip the expensive path (L102).
        var worstEditReplay: Double? = 0
        // How many draft edits were replayed. None means the edit arm measured nothing (no slow key had a
        // draft), so its starting 0 must not stand in the verdict as a measured zero (L90).
        var editReplaysTaken = 0
        var sumMismatches = 0
        var instantsJudged = 0
        for (label, url) in try corpora("phase0c-rows-5") {
            let ctx = ModelContext(try Phase0.openContainer(at: url))
            let t = try Phase0cRowsTables(ctx, export: export)
            let every = t.rows
            let byPID = Dictionary(every.map { ($0.persistentModelID, $0) }, uniquingKeysWith: { a, _ in a })
            let byKey = Dictionary(every.map { ($0.naturalKey, $0) }, uniquingKeysWith: { a, _ in a })
            let base = Date()
            let load = Phase0.load()

            // Noise floor: today's whole T7 terms, five times, unchanged.
            _ = t.oracle(base)
            let todayTerms = Phase0.median5 { _ = t.oracle(base) }

            var proto = Phase0cRowEntries(rows: [], context: t.rowContext(base), upstream: t.upstream(base))
            let cold = Phase0.time {
                proto = Phase0cRowEntries(rows: every, context: t.rowContext(base), upstream: t.upstream(base))
            }
            let atBase = t.oracle(base).mismatches(proto, rowsByKey: byKey)

            // Positive control that the oracle can SEE an override (L159): the rows whose inherited answer
            // Dan's promoted producers and demoted houses change, and the oracle's row for each against the
            // row the production pass builds with those overrides. Compared on the keys both draw, with
            // contact facts in id order on both sides (finding 1 of this probe).
            let withoutOverrides = Phase0cRowOracle.upstream(every: every, answers: t.answers, refusals: t.refusals,
                                                             overrides: .none, now: base).inherited
            let withOverrides = t.upstream(base).inherited
            let touched = Set(withoutOverrides.keys).union(withOverrides.keys)
                .filter { withoutOverrides[$0] != withOverrides[$0] }
            let production = QueueRenderPass.make(QueueRenderPass.Inputs(
                allProspects: QueueRenderPass.Corpus(every), inquiries: t.inquiries, orgAnswers: t.answers,
                sources: t.sources, refusals: t.refusals, overrides: t.overrides, context: t.stage(base),
                focusedStage: .scout, focusedKeys: nil, requestedCardKeys: []))
            var productionRows: [String: QueueScopeRow] = [:]
            for row in production.rows {
                var canonical = row
                if let p = byKey[row.id] { canonical.facts = Phase0cRowBuild.canonicalFacts(p) }
                productionRows[row.id] = canonical
            }
            let oracleRows = t.oracle(base).rows
            let common = Set(productionRows.keys).intersection(oracleRows.keys)
            let touchedDrawn = touched.intersection(common)
            let disagreeing = common.filter { productionRows[$0] != oracleRows[$0] }
            let touchedDisagreeing = touchedDrawn.filter { productionRows[$0] != oracleRows[$0] }
            let overrideControl = touchedDrawn.isEmpty
                ? "UNMEASURED: no drawn row's inherited answer depends on an override on this store"
                : "\(touchedDisagreeing.count) of \(touchedDrawn.count) override-touched rows differ from the production pass"
            #expect(touchedDisagreeing.isEmpty,
                    "oracle rows differ from the production pass on \(touchedDisagreeing.count) override-touched rows [\(label)]")
            #expect(disagreeing.isEmpty,
                    "oracle rows differ from the production pass on \(disagreeing.count) of \(common.count) rows [\(label)]")

            // A row change, over EVERY real row: subtract the old contribution, build the entry, add it.
            let up = proto.upstream
            let rowCtx = proto.context
            var perRow: [Double] = []
            perRow.reserveCapacity(every.count)
            for p in every {
                let pid = p.persistentModelID
                perRow.append(Phase0.time { _ = proto.apply(changed: [pid], rows: byPID, upstream: up, context: rowCtx) })
            }
            let rowStats = Phase0cRows.spread(perRow)
            // The shape of the rows over 1 ms, by count and status only.
            let slow = perRow.indices.filter { perRow[$0] > 1.0 }.map { every[$0] }
            let slowShape = slow.isEmpty ? "none" : slow.map {
                "\($0.statusRaw)/\($0.recipients.count) contacts"
            }.joined(separator: ", ")
            worstRow = max(worstRow, rowStats.max)
            // The slowest sampled keys, each replayed five times with the entry's parts timed (the tail
            // attribution). Five keys rather than one, so a key that sampled low but replays high is not missed.
            var replayLines: [String] = []
            for i in perRow.indices.sorted(by: { perRow[$0] > perRow[$1] }).prefix(5) {
                let p = every[i]
                let pid = p.persistentModelID
                // Up to five minutes for the load to fall under the ceiling, through the one shared reader
                // (#4315); a load it could not read is infinite, so it never passes as quiet.
                let quiet = Phase0.waitForLoad(below: Phase0cRows.loadCeiling, deadline: 300, poll: 5).load
                let shape = "key \(Phase0b.hash8(p.naturalKey)) \(p.statusRaw)/\(p.recipients.count) contacts"
                guard quiet < Phase0cRows.loadCeiling else {
                    worstReplay = nil
                    worstEditReplay = nil
                    replayLines.append("\(shape): UNMEASURED, one minute load \(String(format: "%.2f", quiet)) never fell under 8")
                    continue
                }
                let replay = Phase0.median5 { _ = proto.apply(changed: [pid], rows: byPID, upstream: up, context: rowCtx) }
                var lapRuns: [[(name: String, ms: Double)]] = []
                for _ in 0..<5 {
                    let laps = Phase0cLaps()
                    _ = Phase0cRowBuild.entry(p, context: rowCtx, upstream: up, previous: proto.entries[pid], laps: laps)
                    lapRuns.append(laps.laps)
                }
                let parts = lapRuns[0].indices.map { j -> String in
                    let median = lapRuns.map { $0[j].ms }.sorted()[lapRuns.count / 2]
                    return "\(lapRuns[0][j].name) \(String(format: "%.3f", median))"
                }
                // Inside `placements`, the public pieces its predicates call, so the placement lap is
                // attributed too: the held-contact count and, under it, the draft lint and the greeting hold
                // for each contact, the send-half rule and the prep rule.
                func ms(_ work: () -> Void) -> String { String(format: "%.3f", Phase0.median5(work).median) }
                let pending = p.recipients.filter { $0.sendState == .pending }.count
                let placementParts = [
                    "blockedContactCount \(ms { _ = p.blockedContactCount })",
                    "of which draft lint over every contact \(ms { for r in p.recipients { _ = r.draftLintBlockers } })",
                    "greeting hold over every contact \(ms { for r in p.recipients { _ = r.isBlockedByGreeting } })",
                    "hasEnteredSendHalf \(ms { _ = p.hasEnteredSendHalf })",
                    "needsPrepEligible \(ms { _ = PrepQueueBuilder.needsPrepEligible(p, today: rowCtx.stage.today) })",
                    "\(pending) of \(p.recipients.count) contacts pending",
                ]
                worstReplay = worstReplay.map { max($0, replay.median) }
                // A real edit of this show's draft on the clone copy (never saved): a character appended,
                // five times, then the text put back and the entry rebuilt over it.
                var editText = "no draft to edit"
                if let body = p.draftBody {
                    var runs: [Double] = []
                    for k in 1...5 {
                        p.draftBody = body + String(repeating: " ", count: k)
                        runs.append(Phase0.time { _ = proto.apply(changed: [pid], rows: byPID, upstream: up, context: rowCtx) })
                    }
                    p.draftBody = body
                    proto.apply(changed: [pid], rows: byPID, upstream: up, context: rowCtx)
                    let edit = Phase0.Reading(runs: runs)
                    worstEditReplay = worstEditReplay.map { max($0, edit.median) }
                    editReplaysTaken += 1
                    editText = String(format: "a draft edit, replay median %.3f (%.3f to %.3f)", edit.median, edit.low, edit.high)
                }
                replayLines.append(String(format: "%@: sample %.3f ms, replay median %.3f (%.3f to %.3f) at load %.2f; %@",
                                          shape, perRow[i], replay.median, replay.low, replay.high, quiet, editText)
                                   + "\n      parts (median of five): " + parts.joined(separator: ", ")
                                   + "\n      inside placements (median of five): " + placementParts.joined(separator: ", "))
            }
            // Per-row noise: five fixed rows, each rebuilt five times.
            let fixed = stride(from: 0, to: every.count, by: max(every.count / 5, 1)).prefix(5).map { every[$0] }
            let fixedSpread = fixed.map { p -> String in
                let pid = p.persistentModelID
                return Phase0.median5 { _ = proto.apply(changed: [pid], rows: byPID, upstream: up, context: rowCtx) }.text
            }

            // Upstream hand-offs over every real key of the kind: each hidden row un-hidden, each inherited
            // answer withdrawn, one at a time, and put back.
            var hiddenCosts: [Double] = []
            for key in up.hidden.sorted() {
                var moved = up
                moved.hidden.remove(key)
                hiddenCosts.append(Phase0.time { _ = proto.apply(changed: [], rows: byPID, upstream: moved, context: rowCtx) })
                proto.apply(changed: [], rows: byPID, upstream: up, context: rowCtx)
            }
            var inheritedCosts: [Double] = []
            for key in up.inherited.keys.sorted() {
                var moved = up
                moved.inherited[key] = nil
                inheritedCosts.append(Phase0.time { _ = proto.apply(changed: [], rows: byPID, upstream: moved, context: rowCtx) })
                proto.apply(changed: [], rows: byPID, upstream: up, context: rowCtx)
            }
            // Context scalars: the reply run flag, and a geography refusal of a town the store holds.
            var aliveCtx = rowCtx
            aliveCtx.replyRunAlive = true
            let aliveCost = Phase0.time { _ = proto.apply(changed: [], rows: byPID, upstream: up, context: aliveCtx) }
            let aliveRebuilt = proto.lastRebuilt
            proto.apply(changed: [], rows: byPID, upstream: up, context: rowCtx)
            let towns = every.compactMap { $0.location?.split(separator: ",").first.map { $0.lowercased() } }
            var townCounts: [String: Int] = [:]
            for town in towns { townCounts[town, default: 0] += 1 }
            let busiest = townCounts.max { $0.value < $1.value }?.key
            var geoCost = 0.0, geoRebuilt = 0, geoScan = 0.0
            // #4368: the refusal read again by Gate 0c's rule, the median of five replays with the one minute
            // load under 8 at both ends. A single sample (128.6 ms at 4x on 2026-09-29) decides nothing.
            // REPORT ONLY here: a town refusal is judged against the plan's 100 ms per-change kind budget on
            // the gate table, not against 0c.5's 1 ms per-row stop, so it deliberately does not feed
            // `worstReplay`, which would fail 0c.5 for a different question.
            var geoReplayText = "no town on this store"
            if let busiest {
                var refused = t.geo
                refused.userExcludedTowns.insert(busiest)
                let geoCtx = t.rowContext(base, geo: refused)
                geoCost = Phase0.time { _ = proto.apply(changed: [], rows: byPID, upstream: up, context: geoCtx) }
                geoRebuilt = proto.lastRebuilt
                geoScan = Phase0.time {
                    for p in every where p.statusRaw != "dismissed" { _ = geoCtx.stage.geo.hidesFromQueue(p) }
                }
                proto.apply(changed: [], rows: byPID, upstream: up, context: rowCtx)
                let quiet = Phase0.waitForLoad(below: Phase0cRows.loadCeiling, deadline: 300, poll: 5)
                var runs: [Double] = []
                var rebuilt: [Int] = []
                for _ in 0..<5 {
                    runs.append(Phase0.time { _ = proto.apply(changed: [], rows: byPID, upstream: up, context: geoCtx) })
                    rebuilt.append(proto.lastRebuilt)
                    proto.apply(changed: [], rows: byPID, upstream: up, context: rowCtx)
                }
                let after = Phase0.oneMinuteLoad()
                let replay = Phase0.Reading(runs: runs)
                geoReplayText = Phase0cRows.geoReplayLine(replay, rebuilt: rebuilt, loadBefore: quiet.load, loadAfter: after)
            }

            // 50 instants, including each DueWork deadline crossing: (a) a full rebuild of every entry, whose
            // sums are the stop rule, and (b) the prototype carried forward, rebuilding only the rows whose
            // recorded validUntil passed, which is what T10's TimeProbe would have to make true.
            let (instants, crossings) = Self.instants(from: base, rows: every)
            var fullMismatch: [String] = []
            var expiryMismatch: [String] = []
            var expiryCosts: [Double] = []
            var expiryRebuilt: [Int] = []
            var continuous = 0
            for e in proto.entries.values where e.validUntil <= e.builtAt { continuous += 1 }
            // #4368, a stand-in for plan v7's TimeProbe: at each instant, the rows whose output REALLY moved
            // since the instant before (the full rebuild's entry against the previous full rebuild's, by
            // `sameOutput`), against the rows the carried-forward prototype rebuilds, and what building only
            // the moved rows costs. A perfect TimeProbe could rebuild no fewer than the moved rows, so this is
            // the floor the clock kind could reach, not a design for reaching it.
            var previousFull = Phase0cRowEntries(rows: every, context: t.rowContext(base), upstream: t.upstream(base))
            var needed: [Int] = []
            var neededCosts: [Double] = []
            for (k, at) in instants.enumerated() {
                let oracle = t.oracle(at)
                let atUp = t.upstream(at)
                let atCtx = t.rowContext(at)
                let full = Phase0cRowEntries(rows: every, context: atCtx, upstream: atUp)
                let a = oracle.mismatches(full, rowsByKey: byKey)
                if !a.isEmpty { fullMismatch.append("instant \(k): " + a.joined(separator: "; ")) }
                let moved = Phase0cRows.movedRows(from: previousFull.entries, to: full.entries)
                needed.append(moved.count)
                neededCosts.append(Phase0.time {
                    for pid in moved {
                        guard let p = byPID[pid] else { continue }
                        _ = Phase0cRowBuild.entry(p, context: atCtx, upstream: atUp, previous: previousFull.entries[pid])
                    }
                })
                previousFull = full
                expiryCosts.append(Phase0.time { _ = proto.apply(changed: [], rows: byPID, upstream: atUp, context: atCtx) })
                expiryRebuilt.append(proto.lastRebuilt)
                let b = oracle.mismatches(proto, rowsByKey: byKey)
                if !b.isEmpty { expiryMismatch.append("instant \(k): " + b.joined(separator: "; ")) }
            }
            instantsJudged += instants.count
            sumMismatches += Phase0cRows.mismatchesJudged(full: fullMismatch.count, expiry: expiryMismatch.count,
                                                          baseDiffers: !atBase.isEmpty)
            let rebuiltText = expiryRebuilt.isEmpty ? "none"
                : "median \(expiryRebuilt.sorted()[expiryRebuilt.count / 2]), max \(expiryRebuilt.max() ?? 0)"
            Phase0cRows.say("""
                0c.5 [\(label)] \(every.count) shows, \(load), Debug build
                  today's whole T7 terms (the oracle: scope rows, placements, AgentInputs, organisationRowCounts, DueWork, ReachedOut), five runs: \(todayTerms.text)
                  prototype cold build, every entry                 \(String(format: "%.1f", cold)) ms
                  prototype against the oracle at the base instant  \(atBase.isEmpty ? "0 mismatches" : atBase.joined(separator: "; "))
                  overrides: \(t.overrides == .none ? "none stored" : "stored"); rows whose inherited answer an override changes \(touched.count), \(touchedDrawn.count) of them drawn
                  oracle rows against the production pass (overrides applied): \(disagreeing.count) of \(common.count) common rows differ; \(overrideControl)
                  a row change, every real row                      \(rowStats.text)
                  rows over 1 ms (\(slow.count)): \(slowShape)
                  the five slowest keys, replayed:
                    \(replayLines.joined(separator: "\n    "))
                  per-row noise, five fixed rows x5                 \(fixedSpread.joined(separator: " | "))
                  hidden flip, every hidden row (\(hiddenCosts.count))          \(Phase0cRows.spread(hiddenCosts).text)
                  inherited move, every inheriting row (\(inheritedCosts.count))  \(Phase0cRows.spread(inheritedCosts).text)
                  reply run flag flipped                            \(String(format: "%.2f", aliveCost)) ms, \(aliveRebuilt) rows rebuilt
                  geography refusal of the busiest town             \(String(format: "%.2f", geoCost)) ms, \(geoRebuilt) rows rebuilt (the re-ask scan alone \(String(format: "%.2f", geoScan)) ms)
                  geography refusal, replayed                       \(geoReplayText)
                  50 instants: \(instants.count) distinct, \(crossings) DueWork deadline crossings bracketed
                  (a) full per-row rebuild, sums against AgentInputs.from and the rest: \(fullMismatch.count) instants differ\(fullMismatch.isEmpty ? "" : "\n    " + fullMismatch.prefix(5).joined(separator: "\n    "))
                  (b) carried forward on validUntil: \(expiryMismatch.count) instants differ; rows rebuilt per instant \(rebuiltText); \(continuous) rows read the clock continuously; cost \(Phase0cRows.spread(expiryCosts).text)\(expiryMismatch.isEmpty ? "" : "\n    " + expiryMismatch.prefix(5).joined(separator: "\n    "))
                  (c) TimeProbe stand-in, rows whose output really moved per instant: \(Phase0cRows.countText(needed)) (rebuilt: \(rebuiltText)); building only those \(Phase0cRows.spread(neededCosts).text)
                      per instant, moved/rebuilt: \(zip(needed, expiryRebuilt).map { "\($0)/\($1)" }.joined(separator: " "))
                """)
        }
        if editReplaysTaken == 0 { worstEditReplay = nil }
        let judged = Phase0cRows.judgedReplay(rowChange: worstReplay, draftEdit: worstEditReplay, editsTaken: editReplaysTaken)
        let verdict = Phase0cRows.stopVerdict(mismatches: sumMismatches, replayedMaxMs: judged)
        Phase0cRows.say("0c.5 stop rule (any sum differs at \(instantsJudged) instants over both sizes, or the slowest key's "
                        + "replayed median, a row change or a draft edit, over 1 ms, load under 8): \(verdict), \(sumMismatches) differing, "
                        + "worst replay \(worstReplay.map { String(format: "%.3f", $0) + " ms" } ?? "UNMEASURED"), "
                        + "worst draft edit replay \(worstEditReplay.map { String(format: "%.3f", $0) + " ms" } ?? "UNMEASURED"); "
                        + "worst single sample \(String(format: "%.3f", worstRow)) ms, reported and deciding nothing")
    }

    // MARK: - 0c.6 the unattributed remainder, the published copies and the verifier's snapshot

    @Test(.enabled(if: Phase0.liveStoreExists, "no live store on this machine"))
    func probe0c6UnattributedRemainder() throws {
        if skip("0c.6") { return }
        let export = try scratchExport()
        var remainderAt4x: Double?
        for (label, url) in try corpora("phase0c-rows-6") {
            let ctx = ModelContext(try Phase0.openContainer(at: url))
            let t = try Phase0cRowsTables(ctx, export: export)
            let every = t.rows
            let now = Date()
            let load = Phase0.load()
            let inputs = QueueRenderPass.Inputs(
                allProspects: QueueRenderPass.Corpus(every), inquiries: t.inquiries, orgAnswers: t.answers,
                sources: t.sources, refusals: t.refusals, overrides: t.overrides, context: t.stage(now),
                focusedStage: .scout, focusedKeys: nil, requestedCardKeys: [])
            _ = QueueRenderPass.make(inputs)
            let floor = Phase0.median5 { _ = QueueRenderPass.make(inputs) }

            // The pass, line by line, in the order `make` runs it.
            let corpus = QueueRenderPass.Corpus(every)
            let tAll = Phase0.median5 { _ = corpus.all }
            let tNarrow = Phase0.median5 { _ = corpus.narrowed(QueueModel.queueScope) }
            let inQueue = corpus.narrowed(QueueModel.queueScope).all
            let raw = t.stage(now)
            let tGeo = Phase0.median5 { _ = raw.resolvingPlaces(of: inQueue) }
            let context = raw.resolvingPlaces(of: inQueue)
            func runScope() -> QueueModel.Scope {
                QueueModel.scope(from: inQueue, answers: t.answers, corpus: every, overrides: t.overrides,
                                 sources: t.sources, refusals: t.refusals, clients: context.clients,
                                 now: context.now, cardKeys: [], today: context.today)
            }
            let tScope = Phase0.median5 { _ = runScope() }
            let scope = runScope()
            let rows = scope.rows
            #if DEBUG
            let tCounter = Phase0.median5 { QueueRenderCounter.recordDerivation(inputs: [:], rows: rows) }
            #else
            let tCounter = Phase0.Reading(runs: [0])
            #endif
            let tReached = Phase0.median5 { _ = ReachedOutQueue.activeWithDates(from: inQueue, now: context.now) }
            let reachedOut = ReachedOutQueue.activeWithDates(from: inQueue, now: context.now)
            let tReachedKeys = Phase0.median5 { _ = Set(reachedOut.map(\.prospect.naturalKey)) }
            let reachedKeys = Set(reachedOut.map(\.prospect.naturalKey))
            let tPlace = Phase0.median5 { _ = StageNavigation.placements(in: inQueue, context: context) }
            let placement = StageNavigation.placements(in: inQueue, context: context)
            let tQueueKeys = Phase0.median5 { _ = StageNavigation.queueKeys(in: placement, reachedOutKeys: reachedKeys) }
            let inAStage = StageNavigation.queueKeys(in: placement, reachedOutKeys: reachedKeys)
            let tVisible = Phase0.median5 { _ = rows.filter { inAStage.contains($0.id) } }
            let visibleRows = rows.filter { inAStage.contains($0.id) }
            let tWanted = Phase0.median5 {
                _ = Set(StageNavigation.focusedKeys(stage: .scout, leadKeys: [], in: placement))
            }
            let wanted = Set(StageNavigation.focusedKeys(stage: .scout, leadKeys: [], in: placement))
            let tFocused = Phase0.median5 { _ = rows.filter { wanted.contains($0.id) } }
            let focusedRows = rows.filter { wanted.contains($0.id) }
            let tToday = Phase0.median5 { _ = EasternDate.today(now) }
            let today = EasternDate.today(now)
            let tEvents = Phase0.median5 {
                _ = FeedBreakEvent.events(among: every, asOf: today, contradicted: scope.contradictedCancellations)
            }
            let events = FeedBreakEvent.events(among: every, asOf: today, contradicted: scope.contradictedCancellations)
            let tFeedNotices = Phase0.median5 { _ = AppNotices.feedBreaks(events, shownInQueue: { inAStage.contains($0) }) }
            let feedBreaks = AppNotices.feedBreaks(events, shownInQueue: { inAStage.contains($0) })
            func survivors() -> [String] {
                every.filter { p in
                    guard p.mergeSurvivorUnseenAt != nil, !p.isClosed else { return false }
                    return EasternDate.runIsLive(lastNight: EasternDate.runLastNight(runEndDate: p.runEndDate,
                                                                                     performanceDate: p.performanceDate),
                                                 today: today)
                }.map(\.naturalKey)
            }
            let tSurvivors = Phase0.median5 { _ = survivors() }
            let unseen = survivors()
            let tSurvivorNotices = Phase0.median5 {
                _ = AppNotices.mergeSurvivorsTheFeedDropped(unseen, shownInQueue: { inAStage.contains($0) })
            }
            let merged = AppNotices.mergeSurvivorsTheFeedDropped(unseen, shownInQueue: { inAStage.contains($0) })
            let tSelfBooking = Phase0.median5 { _ = QueueModel.selfBookingIndex(rows) }
            func agent() -> AgentInputs {
                AgentInputs.from(prospects: inQueue, allProspects: every, inquiries: t.inquiries, context: context,
                                 gmailConnected: false, runInFlight: nil, replyRunAlive: false, placement: placement,
                                 reachedOut: reachedOut)
            }
            let tAgent = Phase0.median5 { _ = agent() }
            // AgentInputs.from's own parts.
            let aCounts = Phase0.median5 { _ = StageNavigation.counts(in: placement) }
            let aDue = Phase0.median5 {
                _ = DueWork.counts(prospects: every, inquiries: t.inquiries, now: context.now, replyRunAlive: false)
            }
            let aDeadEnds = Phase0.median5 { _ = DraftedDeadEnd.count(in: inQueue) }
            let aStalled = Phase0.median5 {
                _ = StalledReplyDraft.dueRecipients(from: inQueue, now: context.now, runAlive: false).count
            }
            let aShowCount = Phase0.median5 { _ = ReachedOutQueue.showCount(of: reachedOut) }
            let aReachedDue = Phase0.median5 {
                _ = reachedOut.filter { ReachedOutQueue.isDueNow(for: $0.recipient, of: $0.prospect, now: context.now) }.count
            }
            let aInquiries = Phase0.median5 {
                _ = t.inquiries.filter { StageNavigation.stage(for: $0) == .review }.count
                    + t.inquiries.filter { StageNavigation.stage(for: $0) == .reachedOut }.count
                    + t.inquiries.filter { StageNavigation.stage(for: $0) == .reachedOut && $0.hasUnhandledReply }.count
            }
            let tPending = Phase0.median5 { _ = QueueModel.pendingBookingCount(rows) }
            let tFanOut = Phase0.median5 { _ = QueueRenderPass.fanOutWarning(inQueue) }
            let tGroup = Phase0.median5 { _ = QueueModel.groupByDate(focusedRows) }
            let dateGroups = QueueModel.groupByDate(focusedRows)
            // #4317: each heading's reachability answers, which the pass takes now.
            let tHeadings = Phase0.median5 {
                _ = QueueModel.dateProbeHeadings(dateGroups, now: context.now, today: context.today, geo: context.geo)
            }
            let headings = QueueModel.dateProbeHeadings(dateGroups, now: context.now, today: context.today,
                                                        geo: context.geo)
            let tInquiryRows = Phase0.median5 {
                _ = QueueRenderPass.inquiryRows(t.inquiries, stage: .scout, now: context.now)
            }
            let tStageCounts = Phase0.median5 { _ = StageNavigation.counts(in: placement) }
            // #4106 view workstream: the masthead's two folds, which the pass takes now.
            let tMissed = Phase0.median5 {
                _ = QueueModel.keysMissedByACheck(rows, now: context.now, today: context.today, geo: context.geo)
            }
            let missed = QueueModel.keysMissedByACheck(rows, now: context.now, today: context.today, geo: context.geo)
            let tSummary = Phase0.median5 { _ = QueueModel.summary(visibleRows) }
            let selfBooking = QueueModel.selfBookingIndex(rows)
            let agentInputs = agent()
            func renderData() -> QueueView.RenderData {
                QueueView.RenderData(
                    cards: scope.cards, queueScope: inQueue.map { ShowIdentity($0) }, selfBooking: selfBooking, agentInputs: agentInputs,
                    gmailConnected: false, probeRunning: false, checkRunning: false, prepRunning: false,
                    checkRunSince: nil, checkLookups: nil,
                    reachedOut: reachedOut.map { ReachedOutSnapshot(show: $0.prospect, contact: $0.recipient, next: $0.next) },
                    reachedOutKeys: reachedKeys,
                    feedBreaks: feedBreaks, mergeSurvivorsDropped: merged,
                    pendingBookings: QueueModel.pendingBookingCount(rows),
                    summary: QueueModel.summary(visibleRows), missedByACheckKeys: missed, fanOutLine: nil, rows: rows,
                    visibleRows: visibleRows, cardCheck: scope.cardCheck, focusedRows: focusedRows,
                    dateGroups: dateGroups, inquiryRows: [], inquiryGroups: [], inquiriesByRowID: [:],
                    reachedOutList: .none, dateProbeHeadings: headings, stageCounts: [:], geo: context.geo,
                    placement: placement, now: context.now)
            }
            let tRenderData = Phase0.median5 { _ = renderData() }
            let passTerms: [(String, Phase0.Reading)] = [
                ("allProspects.all", tAll), ("narrowed(queueScope) (the sort)", tNarrow), ("geo resolve", tGeo),
                ("QueueModel.scope, no cards", tScope), ("QueueRenderCounter.recordDerivation (DEBUG)", tCounter),
                ("ReachedOutQueue.activeWithDates", tReached), ("reachedOutKeys", tReachedKeys),
                ("StageNavigation.placements", tPlace), ("queueKeys", tQueueKeys), ("visibleRows filter", tVisible),
                ("focusedKeys set", tWanted), ("focusedRows filter", tFocused), ("EasternDate.today", tToday),
                ("FeedBreakEvent.events (shared set)", tEvents), ("AppNotices.feedBreaks", tFeedNotices),
                ("unseen merge survivors", tSurvivors), ("mergeSurvivorsTheFeedDropped", tSurvivorNotices),
                ("selfBookingIndex", tSelfBooking), ("AgentInputs.from (as the pass calls it)", tAgent),
                ("pendingBookingCount", tPending), ("fanOutWarning", tFanOut), ("groupByDate", tGroup),
                ("inquiryRows", tInquiryRows), ("stage counts", tStageCounts),
                ("dateProbeHeadings (each heading's reachability answers)", tHeadings),
                ("keysMissedByACheck (the masthead's offer)", tMissed), ("summary (the masthead's counts)", tSummary),
                ("RenderData init", tRenderData),
            ]
            let passNamed = passTerms.reduce(0) { $0 + $1.1.median }
            let agentTerms: [(String, Phase0.Reading)] = [
                ("counts(in: placement)", aCounts), ("DueWork.counts over every show", aDue),
                ("DraftedDeadEnd.count", aDeadEnds), ("StalledReplyDraft.dueRecipients", aStalled),
                ("showCount(of:)", aShowCount), ("reachedOutDue filter", aReachedDue), ("inquiry filters", aInquiries),
            ]
            let agentNamed = agentTerms.reduce(0) { $0 + $1.1.median }

            // Inside scope, line by line.
            let sLinkMap = Phase0.median5 { _ = inQueue.map(EngagementLink.Row.init) }
            let linkRows = inQueue.map(EngagementLink.Row.init)
            let sLinkGroup = Phase0.median5 { _ = EngagementLink.group(linkRows) }
            let linked = EngagementLink.group(linkRows)
            let sShows = Phase0.median5 { _ = every.map { ProducerGate.Show(presenter: $0.presenter, venue: $0.venue) } }
            let shows = every.map { ProducerGate.Show(presenter: $0.presenter, venue: $0.venue) }
            let sTables = Phase0.median5 { _ = QueueModel.ProducerTables(shows: shows, overrides: t.overrides) }
            let tables = QueueModel.ProducerTables(shows: shows, overrides: t.overrides)
            let sInherited = Phase0.median5 {
                _ = QueueModel.inheritedAnswers(t.answers, corpus: every, overrides: t.overrides, refusals: t.refusals,
                                                heldKeys: [], now: now, producerCorpus: tables.corpus)
            }
            let inherited = QueueModel.inheritedAnswers(t.answers, corpus: every, overrides: t.overrides,
                                                        refusals: t.refusals, heldKeys: [], now: now,
                                                        producerCorpus: tables.corpus)
            let sRowCounts = Phase0.median5 { _ = QueueModel.organisationRowCounts(every.map(\.presenter)) }
            let rowCounts = QueueModel.organisationRowCounts(every.map(\.presenter))
            let sCalendar = Phase0.median5 { _ = QueueModel.sourceCalendarIndex(t.sources) }
            let calendar = QueueModel.sourceCalendarIndex(t.sources)
            let sContradicted = Phase0.median5 { _ = ContradictedCancellation.contradictedKeys(among: every) }
            let contradicted = ContradictedCancellation.contradictedKeys(among: every)
            let sShowLinkMap = Phase0.median5 { _ = every.map(ShowLink.Row.init) }
            let showLinkRows = every.map(ShowLink.Row.init)
            let sShowLinkGroup = Phase0.median5 { _ = ShowLink.group(showLinkRows) }
            let sameShow = ShowLink.group(showLinkRows)
            let sTitles = Phase0.median5 {
                _ = Dictionary(every.map { ($0.naturalKey, $0.groupName) }, uniquingKeysWith: { first, _ in first })
            }
            let titles = Dictionary(every.map { ($0.naturalKey, $0.groupName) }, uniquingKeysWith: { first, _ in first })
            let sDrawn = Phase0.median5 { _ = Set(inQueue.map(\.naturalKey)) }
            let drawn = Set(inQueue.map(\.naturalKey))
            let sCollapse = Phase0.median5 { _ = ShowLink.collapse(showLinkRows, drawn: drawn) }
            let collapse = ShowLink.collapse(showLinkRows, drawn: drawn)
            func lookalikes() -> [String: [String]] {
                var by: [String: [Prospect]] = [:]
                for row in every { if let target = row.arrivedLookingLike { by[target, default: []].append(row) } }
                return by.mapValues { rows in
                    rows.sorted { ($0.firstSeenAt ?? .distantPast) > ($1.firstSeenAt ?? .distantPast) }.map(\.naturalKey)
                }
            }
            let sLookalikes = Phase0.median5 { _ = lookalikes() }
            func nights() -> [String: String] {
                Dictionary(every.compactMap { row -> (String, String)? in
                    guard let night = row.performanceDate, !night.isEmpty else { return nil }
                    return (row.naturalKey, night)
                }, uniquingKeysWith: { first, _ in first })
            }
            let sNights = Phase0.median5 { _ = nights() }
            func preamble() -> QueueModel.CardPreamble {
                QueueModel.CardPreamble(linked: linked, inherited: inherited, venueBrands: tables.venueBrands,
                                        rowCounts: rowCounts, calendarBySourceId: calendar, overrides: t.overrides,
                                        clients: context.clients, contradictedCancellations: contradicted,
                                        sameShowGroups: sameShow, titlesByKey: titles, collapsedFronts: collapse.fronts,
                                        collapsedHidden: collapse.hidden, laterLookalikesByKey: lookalikes(),
                                        nightsByKey: nights(), now: now, day: today)
            }
            let pre = preamble()
            // #4356: the two tables built OUTSIDE the timed block, which times the preamble's init alone,
            // since `sLookalikes` and `sNights` already time their derivation and both are summed below.
            let lookalikeTable = lookalikes()
            let nightTable = nights()
            let sPreamble = Phase0.median5 {
                _ = QueueModel.CardPreamble(linked: linked, inherited: inherited, venueBrands: tables.venueBrands,
                                            rowCounts: rowCounts, calendarBySourceId: calendar, overrides: t.overrides,
                                            clients: context.clients, contradictedCancellations: contradicted,
                                            sameShowGroups: sameShow, titlesByKey: titles,
                                            collapsedFronts: collapse.fronts, collapsedHidden: collapse.hidden,
                                            laterLookalikesByKey: lookalikeTable, nightsByKey: nightTable,
                                            now: now, day: today)
            }
            // The row loop exactly as scope runs it with no cards wanted.
            let noCards: Set<String> = []
            func loop() -> (rows: [QueueScopeRow], contacts: [String: [Recipient]]) {
                var out: [QueueScopeRow] = []
                var contactsByKey: [String: [Recipient]] = [:]
                out.reserveCapacity(inQueue.count)
                contactsByKey.reserveCapacity(inQueue.count)
                for p in inQueue {
                    if pre.tables.isCollapsedHidden(p.naturalKey) { continue }
                    let contacts = p.countedRecipients
                    let key = p.naturalKey
                    contactsByKey[key] = contacts
                    out.append(QueueScopeRow(p, facts: RecipientFacts.of(p, contacts: contacts),
                                             inheritedReachability: inherited[key]))
                    if noCards.contains(key) { _ = key }
                }
                return (out, contactsByKey)
            }
            let sLoop = Phase0.median5 { _ = loop() }
            let looped = loop()
            let sCheck = Phase0.median5 {
                _ = QueueModel.checkOneCardAgainstAFreshBuild(cards: [:], contactsByKey: looped.contacts, draftBodies: [:],
                                                              corpus: inQueue, preamble: pre)
            }
            let sCardStore = Phase0.median5 {
                _ = QueueModel.CardStore(cards: [:], shows: inQueue, contactsByKey: looped.contacts, preamble: pre,
                                         requestedKeys: noCards, registry: nil)
            }
            let store = QueueModel.CardStore(cards: [:], shows: inQueue, contactsByKey: looped.contacts, preamble: pre,
                                             requestedKeys: noCards, registry: nil)
            let sScopeInit = Phase0.median5 {
                _ = QueueModel.Scope(rows: looped.rows, cards: store,
                                     cardCheck: QueueModel.Scope.CardCheck(ran: false, divergence: nil),
                                     contradictedCancellations: contradicted)
            }
            let scopeTerms: [(String, Phase0.Reading)] = [
                ("EngagementLink rows map", sLinkMap), ("EngagementLink.group", sLinkGroup),
                ("ProducerGate.Show map", sShows), ("ProducerTables cold", sTables),
                ("inheritedAnswers (the ledger)", sInherited), ("organisationRowCounts", sRowCounts),
                ("sourceCalendarIndex", sCalendar), ("ContradictedCancellation", sContradicted),
                ("ShowLink rows map (paid twice)", Phase0.Reading(runs: sShowLinkMap.runs.map { $0 * 2 })),
                ("ShowLink.group", sShowLinkGroup), ("titlesByKey", sTitles), ("drawn set", sDrawn),
                ("ShowLink.collapse", sCollapse), ("laterLookalikes", sLookalikes), ("nightsByKey", sNights),
                ("CardPreamble init", sPreamble), ("row loop (hidden check, contacts, row)", sLoop),
                ("card check over no cards", sCheck), ("CardStore init (sources)", sCardStore),
                ("Scope init", sScopeInit),
            ]
            let scopeNamed = scopeTerms.reduce(0) { $0 + $1.1.median }

            // The published arrays, copied (the first write after handing one out copies the whole buffer).
            func copy<T>(_ xs: [T]) -> Phase0.Reading {
                guard let first = xs.first else { return Phase0.Reading(runs: [0]) }
                return Phase0.median5 {
                    var c = xs
                    c.append(first)
                    _ = c.count
                }
            }
            let copies: [(String, Phase0.Reading)] = [
                ("rows (\(rows.count))", copy(rows)), ("visibleRows (\(visibleRows.count))", copy(visibleRows)),
                ("focusedRows (\(focusedRows.count))", copy(focusedRows)), ("queueScope (\(inQueue.count))", copy(inQueue)),
                ("reachedOut (\(reachedOut.count))", copy(reachedOut)), ("dateGroups (\(dateGroups.count))", copy(dateGroups)),
            ]
            let copyTotal = copies.reduce(0) { $0 + $1.1.median }

            // The verifier's snapshot: handing the patched cache to another thread is a copy of a value, which
            // costs nothing until main next writes the cache, and that write then copies every entry (L331:
            // measured on the prototype's own storage, since the engine's does not exist yet).
            let proto = Phase0cRowEntries(rows: every, context: t.rowContext(now), upstream: t.upstream(now))
            let firstPID = every[0].persistentModelID
            let handOff = Phase0.median5 {
                let entries = proto.entries
                _ = entries.count
            }
            let firstWrite = Phase0.median5 {
                var entries = proto.entries
                let snapshot = entries
                entries[firstPID] = nil
                _ = snapshot.count + entries.count
            }
            let rowsByKey = proto.rowsByKey
            let rowsWrite = Phase0.median5 {
                var byKey = rowsByKey
                let snapshot = byKey
                byKey[every[0].naturalKey] = nil
                _ = snapshot.count + byKey.count
            }

            let passRemainder = floor.median - passNamed
            let scopeRemainder = tScope.median - scopeNamed
            if label == "4x" { remainderAt4x = passRemainder }
            Phase0cRows.say("""
                0c.6 [\(label)] \(every.count) shows, \(inQueue.count) in scope, \(load), Debug build
                  THE FLOOR, today's pass with no cards, five runs      \(floor.text)
                  the pass, line by line:
                    \(passTerms.map { Phase0b.pad($0.0, 46) + " " + $0.1.text }.joined(separator: "\n    "))
                  named \(String(format: "%.1f", passNamed)) ms of the floor \(String(format: "%.1f", floor.median)) ms: UNATTRIBUTED \(String(format: "%.1f", passRemainder)) ms (the floor's own spread is \(String(format: "%.1f", floor.high - floor.low)) ms)
                  AgentInputs.from's own parts:
                    \(agentTerms.map { Phase0b.pad($0.0, 46) + " " + $0.1.text }.joined(separator: "\n    "))
                  named \(String(format: "%.1f", agentNamed)) ms of \(String(format: "%.1f", tAgent.median)) ms
                  inside QueueModel.scope, line by line:
                    \(scopeTerms.map { Phase0b.pad($0.0, 46) + " " + $0.1.text }.joined(separator: "\n    "))
                  named \(String(format: "%.1f", scopeNamed)) ms of \(String(format: "%.1f", tScope.median)) ms: UNATTRIBUTED \(String(format: "%.1f", scopeRemainder)) ms
                  published arrays, one copy each:
                    \(copies.map { Phase0b.pad($0.0, 46) + " " + $0.1.text }.joined(separator: "\n    "))
                  all published copies together \(String(format: "%.2f", copyTotal)) ms
                  verifier snapshot of the entry cache (\(proto.entries.count) entries): hand-off \(handOff.text); first main write after it \(firstWrite.text)
                  verifier snapshot of the rows table (\(rowsByKey.count) rows): first main write after it \(rowsWrite.text)
                """)
        }
        if let r = remainderAt4x {
            Phase0cRows.say("0c.6 stop rule (an unattributed remainder over 10 ms at 5,376): "
                            + "\(r > 10 ? "FAIL" : "PASS"), remainder \(String(format: "%.1f", r)) ms at 4x")
        } else {
            Phase0cRows.say("0c.6 stop rule: UNMEASURED, the 4x corpus was not built")
        }
    }
}

// MARK: - 0c.5's untested case, on the synthetic fixture (#4368)

extension QueueEnginePhase0cRowsProbeTests {

    /// Every contacted show in a fixture of the clone's size, given one more contact still waiting to send
    /// and a draft, so a draft edit reaches the draft lint (#4310's 1.752 ms case). Today's clone has no such
    /// show, which is why the clone arm cannot exercise it (the posted table, 2026-09-29).
    static func pendingContactDraftShows(_ fx: Phase0cRowsFixture) -> [Prospect] {
        let contacted = fx.rows.filter { $0.status == .contacted && $0.sentAt != nil }
        for (i, p) in contacted.enumerated() {
            let id = "\(p.naturalKey)-waiting-\(i)@example.org"
            let waiting = Recipient(id: id, email: id, provenance: .act)
            p.setRecipients(p.recipients + [waiting])
            p.draftBody = Phase0cRowsFixture.draft
        }
        return contacted
    }

    // Runs on every push, cheaply: the fixture really builds the case the probe below times, and a draft edit
    // there really reaches the lint (L102: an arm that skips the expensive path measures the skip).
    @Test func thePendingContactDraftEditCaseReachesTheLint() throws {
        let fx = try Phase0cRowsFixture(size: 60, seed: 4368)
        let shows = Self.pendingContactDraftShows(fx)
        try #require(!shows.isEmpty, "the fixture holds no contacted show, so the case cannot be built")
        var proto = Phase0cRowEntries(rows: fx.rows, context: fx.rowContext(), upstream: fx.upstream())
        let before = Self.disagreement(fx, proto)
        let p = shows[0]
        let pid = p.persistentModelID
        #expect(p.recipients.contains { $0.sendState == .pending && $0.email != nil })
        p.draftBody = Phase0cRowsFixture.draftWithSlot
        proto.apply(changed: [pid], rows: fx.rowsByPID, upstream: fx.upstream(), context: fx.rowContext())
        #expect(proto.entries[pid]?.lint?.body == Phase0cRowsFixture.draftWithSlot,
                "the edit did not reach the draft lint, so timing it would time the skip")
        // The edit adds no disagreement of its own. Not "no disagreement at all": this shape disagrees at build
        // on `reachedOutDue`, and in a way that moves between runs of one seed (see the probe below), so an
        // assertion of none would be a flaky red on every push.
        #expect(Self.disagreement(fx, proto) == before, "the draft edit changed how the prototype disagrees with the oracle")
    }

    // The TimeProbe stand-in's count, on every push: two builds at one instant move nothing, and a changed row
    // is counted (L159: the positive case in the same fixture as the empty one).
    @Test func theTimeProbeStandInCountsOnlyRowsWhoseOutputMoved() throws {
        let fx = try Phase0cRowsFixture(size: 60, seed: 4368)
        let a = Phase0cRowEntries(rows: fx.rows, context: fx.rowContext(), upstream: fx.upstream())
        let b = Phase0cRowEntries(rows: fx.rows, context: fx.rowContext(), upstream: fx.upstream())
        #expect(Phase0cRows.movedRows(from: a.entries, to: b.entries).isEmpty)
        let p = try #require(fx.rows.first { $0.status == .new })
        p.status = .dismissed
        let c = Phase0cRowEntries(rows: fx.rows, context: fx.rowContext(), upstream: fx.upstream())
        let moved = Phase0cRows.movedRows(from: a.entries, to: c.entries)
        #expect(moved.contains(p.persistentModelID))
        #expect(moved.count < fx.rows.count / 2, "a one row change moved \(moved.count) rows")
    }

    // The refusal replay is scored only under the load rule (#4368), on every push.
    @Test func aRefusalReplayTakenAtLoadEightOrOverDecidesNothing() {
        let r = Phase0.Reading(runs: [3, 1, 2, 5, 4])
        #expect(!Phase0cRows.geoReplayLine(r, rebuilt: [9], loadBefore: 2, loadAfter: 7.9).contains("UNMEASURED"))
        #expect(Phase0cRows.geoReplayLine(r, rebuilt: [9], loadBefore: 8, loadAfter: 2).hasPrefix("UNMEASURED"))
        #expect(Phase0cRows.geoReplayLine(r, rebuilt: [9], loadBefore: 2, loadAfter: .infinity).hasPrefix("UNMEASURED"))
    }

    @Test func aFieldValueHoldingACommaStaysWhole() {
        let fields = Self.agentFields("AgentInputs(toTriage: 3, runInFlight: Optional(x: 1, y: 2), reachedOutDue: 295)")
        #expect(fields["runInFlight"] == "Optional(x: 1, y: 2)")
        #expect(fields["reachedOutDue"] == "295")
        #expect(fields.count == 3)
    }

    /// `AgentInputs`' description as field name to value, so a disagreement names its fields. Split only on a
    /// comma at the top level, outside any parentheses or brackets, so a nested value stays whole.
    static func agentFields(_ text: String) -> [String: String] {
        var body = text
        if body.hasPrefix("AgentInputs(") { body.removeFirst("AgentInputs(".count) }
        if body.hasSuffix(")") { body.removeLast() }
        var parts: [String] = []
        var current = ""
        var depth = 0
        for ch in body {
            if ch == "(" || ch == "[" { depth += 1 } else if ch == ")" || ch == "]" { depth -= 1 }
            if ch == "," && depth == 0 { parts.append(current); current = ""; continue }
            current.append(ch)
        }
        parts.append(current)
        var out: [String: String] = [:]
        for part in parts {
            let pair = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2 { out[pair[0]] = pair[1] }
        }
        return out
    }

    /// How the prototype disagrees with the oracle, by component and by AgentInputs FIELD NAME, so two states
    /// that disagree in the same places compare equal even when the counts behind them moved.
    static func disagreement(_ fx: Phase0cRowsFixture, _ proto: Phase0cRowEntries) -> Set<String> {
        let oracle = fx.oracle()
        var out = Set(oracle.mismatches(proto, rowsByKey: fx.rowsByKey).filter { !$0.hasPrefix("AgentInputs") })
        let mine = agentFields(String(describing: proto.agentInputs))
        let theirs = agentFields(oracle.agent)
        for name in Set(mine.keys).union(theirs.keys) where mine[name] != theirs[name] { out.insert("AgentInputs." + name) }
        return out
    }

    /// The draft edit on a contacted show with a contact waiting, timed on the synthetic fixture by Gate 0c's
    /// rule: every such show edited once, then the five slowest replayed five times each with the one minute
    /// load under 8, the median of the slowest key deciding. Opt in with the other 0c.5 probes.
    @Test func probe0c5PendingContactDraftEditOnTheFixture() throws {
        if skip("0c.5 pending contact draft edit") { return }
        for size in [1_350, 5_400] {
            let fx = try Phase0cRowsFixture(size: size, seed: 4368)
            let shows = Self.pendingContactDraftShows(fx)
            try #require(!shows.isEmpty, "the fixture holds no contacted show at \(size) rows, so nothing can be timed")
            var proto = Phase0cRowEntries(rows: fx.rows, context: fx.rowContext(), upstream: fx.upstream())
            let byPID = fx.rowsByPID
            let up = proto.upstream, ctx = proto.context
            func edit(_ p: Prospect) -> Double {
                let pid = p.persistentModelID
                p.draftBody = p.draftBody == Phase0cRowsFixture.draft ? Phase0cRowsFixture.draftWithSlot
                    : Phase0cRowsFixture.draft
                return Phase0.time { _ = proto.apply(changed: [pid], rows: byPID, upstream: up, context: ctx) }
            }
            // Whether the prototype agrees BEFORE any edit, and, if an edit changes the disagreement, which edit
            // first and which AgentInputs fields (counts only, field names and numbers, L222). Measured
            // 2026-09-29: it disagrees at BUILD, on `reachedOutDue`, once a contacted show carries a waiting
            // contact, so the edits are judged against the build's disagreement rather than against none.
            let atBuild = fx.oracle().mismatches(proto, rowsByKey: fx.rowsByKey)
            let buildDisagreement = Self.disagreement(fx, proto)
            let buildFields = Self.agentFields(String(describing: proto.agentInputs))
            let buildOracle = Self.agentFields(fx.oracle().agent)
            let buildDiffering = buildFields.keys.filter { buildFields[$0] != buildOracle[$0] }.sorted()
                .map { "\($0) \(buildFields[$0] ?? "-") against \(buildOracle[$0] ?? "-")" }
            // The oracle is judged once, after every edit, never between edits: at 5,400 rows one oracle costs
            // about a second, and one per edit held the shared test lock for twenty minutes (2026-09-30).
            let samples = shows.map { edit($0) }
            let afterDisagreement = Self.disagreement(fx, proto)
            let added = afterDisagreement.subtracting(buildDisagreement).sorted()
            let firstBreak = added.isEmpty ? "none" : added.joined(separator: ", ")
            let mismatches = fx.oracle().mismatches(proto, rowsByKey: fx.rowsByKey)
            // The build's own disagreement is the finding and FAILS the stop rule below; what this asserts is
            // that the edits add none.
            #expect(afterDisagreement == buildDisagreement,
                    "the draft edits changed how the prototype disagrees with the oracle [\(size)]")
            var replays: [String] = []
            var worst: Double? = 0
            // One bounded wait before the FIRST key only, then the load read before and after each key, which is
            // what decides it: a wait per key could outlast the runner's twenty minute stall limit on a busy Mac,
            // so a later key can be UNMEASURED on load the wait did not cover.
            _ = Phase0.waitForLoad(below: Phase0cRows.loadCeiling, deadline: 300, poll: 5)
            for i in samples.indices.sorted(by: { samples[$0] > samples[$1] }).prefix(5) {
                let p = shows[i]
                let before = Phase0.oneMinuteLoad()
                let reading = Phase0.Reading(runs: (0..<5).map { _ in edit(p) })
                let after = Phase0.oneMinuteLoad()
                let shape = "key \(Phase0b.hash8(p.naturalKey)) \(p.recipients.count) contacts, "
                    + "\(p.recipients.filter { $0.sendState == .pending }.count) pending"
                guard before < Phase0cRows.loadCeiling && after < Phase0cRows.loadCeiling else {
                    worst = nil
                    replays.append(shape + String(format: ": UNMEASURED, load %.2f before and %.2f after", before, after))
                    continue
                }
                worst = worst.map { max($0, reading.median) }
                replays.append(shape + String(format: ": sample %.3f ms, replay median %.3f (%.3f to %.3f), load %.2f before, %.2f after",
                                              samples[i], reading.median, reading.low, reading.high, before, after))
            }
            // 0c.5's own stop rule: any disagreement fails it, whatever the timing says.
            // No show edited means nothing was measured, never a measured zero (L90).
            if samples.isEmpty { worst = nil }
            let verdict = Phase0cRows.stopVerdict(mismatches: mismatches.count, replayedMaxMs: worst)
            Phase0cRows.say("""
                0c.5 pending contact draft edit [synthetic \(size) rows, seed 4368] \(shows.count) contacted shows given a waiting contact, \(Phase0.load()), Debug build
                  every such show edited once                         \(Phase0cRows.spread(samples).text)
                  oracle at build, before any edit                    \(atBuild.isEmpty ? "0 mismatches" : "prototype against oracle " + buildDiffering.joined(separator: "; "))
                  oracle after the edits                              \(mismatches.count) mismatches; disagreement the edits added: \(firstBreak)
                  the five slowest keys, replayed:
                    \(replays.joined(separator: "\n    "))
                  stop (any disagreement with the oracle, or the slowest key's replayed median over 1 ms, load under 8): \(verdict)\(worst.map { String(format: ", %.3f ms", $0) } ?? "")
                """)
        }
    }
}
