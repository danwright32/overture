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
        Phase0cRowOracle.upstream(every: rows, answers: answers, refusals: refusals, now: now)
    }

    func oracle(_ now: Date, alive: Bool = false) -> Phase0cRowOracle {
        Phase0cRowOracle(every: rows, inquiries: inquiries, answers: answers, refusals: refusals, stage: stage(now),
                         replyRunAlive: alive)
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
            for (k, at) in instants.enumerated() {
                let oracle = t.oracle(at)
                let atUp = t.upstream(at)
                let atCtx = t.rowContext(at)
                let full = Phase0cRowEntries(rows: every, context: atCtx, upstream: atUp)
                let a = oracle.mismatches(full, rowsByKey: byKey)
                if !a.isEmpty { fullMismatch.append("instant \(k): " + a.joined(separator: "; ")) }
                expiryCosts.append(Phase0.time { _ = proto.apply(changed: [], rows: byPID, upstream: atUp, context: atCtx) })
                expiryRebuilt.append(proto.lastRebuilt)
                let b = oracle.mismatches(proto, rowsByKey: byKey)
                if !b.isEmpty { expiryMismatch.append("instant \(k): " + b.joined(separator: "; ")) }
            }
            instantsJudged += instants.count
            sumMismatches += fullMismatch.count + (atBase.isEmpty ? 0 : 1)
            let rebuiltText = expiryRebuilt.isEmpty ? "none"
                : "median \(expiryRebuilt.sorted()[expiryRebuilt.count / 2]), max \(expiryRebuilt.max() ?? 0)"
            Phase0cRows.say("""
                0c.5 [\(label)] \(every.count) shows, \(load), Debug build
                  today's whole T7 terms (the oracle: scope rows, placements, AgentInputs, organisationRowCounts, DueWork, ReachedOut), five runs: \(todayTerms.text)
                  prototype cold build, every entry                 \(String(format: "%.1f", cold)) ms
                  prototype against the oracle at the base instant  \(atBase.isEmpty ? "0 mismatches" : atBase.joined(separator: "; "))
                  a row change, every real row                      \(rowStats.text)
                  rows over 1 ms (\(slow.count)): \(slowShape)
                  per-row noise, five fixed rows x5                 \(fixedSpread.joined(separator: " | "))
                  hidden flip, every hidden row (\(hiddenCosts.count))          \(Phase0cRows.spread(hiddenCosts).text)
                  inherited move, every inheriting row (\(inheritedCosts.count))  \(Phase0cRows.spread(inheritedCosts).text)
                  reply run flag flipped                            \(String(format: "%.2f", aliveCost)) ms, \(aliveRebuilt) rows rebuilt
                  geography refusal of the busiest town             \(String(format: "%.2f", geoCost)) ms, \(geoRebuilt) rows rebuilt (the re-ask scan alone \(String(format: "%.2f", geoScan)) ms)
                  50 instants: \(instants.count) distinct, \(crossings) DueWork deadline crossings bracketed
                  (a) full per-row rebuild, sums against AgentInputs.from and the rest: \(fullMismatch.count) instants differ\(fullMismatch.isEmpty ? "" : "\n    " + fullMismatch.prefix(5).joined(separator: "\n    "))
                  (b) carried forward on validUntil: \(expiryMismatch.count) instants differ; rows rebuilt per instant \(rebuiltText); \(continuous) rows read the clock continuously; cost \(Phase0cRows.spread(expiryCosts).text)\(expiryMismatch.isEmpty ? "" : "\n    " + expiryMismatch.prefix(5).joined(separator: "\n    "))
                """)
        }
        let verdict = sumMismatches == 0 && worstRow <= 1.0 ? "PASS" : "FAIL"
        Phase0cRows.say("0c.5 stop rule (any sum differs at \(instantsJudged) instants over both sizes, or a row over 1 ms): "
                        + "\(verdict), \(sumMismatches) differing, worst row \(String(format: "%.3f", worstRow)) ms")
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
            let tInquiryRows = Phase0.median5 {
                _ = QueueRenderPass.inquiryRows(t.inquiries, stage: .scout, now: context.now)
            }
            let tStageCounts = Phase0.median5 { _ = StageNavigation.counts(in: placement) }
            let selfBooking = QueueModel.selfBookingIndex(rows)
            let agentInputs = agent()
            func renderData() -> QueueView.RenderData {
                QueueView.RenderData(
                    cards: scope.cards, queueScope: inQueue, selfBooking: selfBooking, agentInputs: agentInputs,
                    gmailConnected: false, probeRunning: false, checkRunning: false, prepRunning: false,
                    checkRunSince: nil, checkLookups: nil, reachedOut: reachedOut, reachedOutKeys: reachedKeys,
                    feedBreaks: feedBreaks, mergeSurvivorsDropped: merged,
                    pendingBookings: QueueModel.pendingBookingCount(rows), fanOutLine: nil, rows: rows,
                    visibleRows: visibleRows, cardCheck: scope.cardCheck, focusedRows: focusedRows,
                    dateGroups: dateGroups, inquiryRows: [], stageCounts: [:], geo: context.geo, placement: placement)
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
                ("inquiryRows", tInquiryRows), ("stage counts", tStageCounts), ("RenderData init", tRenderData),
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
            let sPreamble = Phase0.median5 {
                _ = QueueModel.CardPreamble(linked: linked, inherited: inherited, venueBrands: tables.venueBrands,
                                            rowCounts: rowCounts, calendarBySourceId: calendar, overrides: t.overrides,
                                            clients: context.clients, contradictedCancellations: contradicted,
                                            sameShowGroups: sameShow, titlesByKey: titles,
                                            collapsedFronts: pre.collapsedFronts, collapsedHidden: pre.collapsedHidden,
                                            laterLookalikesByKey: pre.laterLookalikesByKey, nightsByKey: pre.nightsByKey,
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
                    if pre.collapsedHidden.contains(p.naturalKey) { continue }
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
                _ = QueueModel.checkOneCardAgainstAFreshBuild(cards: [:], contactsByKey: looped.contacts,
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
                ("card check over no cards", sCheck), ("CardStore init (showsByKey)", sCardStore),
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
