import Testing
import Foundation
import SwiftData

// #4623: where the queue's pass spends its time, term by term, over the live models AND over the engine's
// retained facts, on the live store's clone and its fourfold copy.
//
// WHY. After the switch (#4358 E4d) the engine's pass over facts measured 513 ms at 1x and 2,263 ms at 4x against
// the pass over models' 373 ms and 1,746 ms (Debug, `QueueEngineCostProbeTests`). This takes each term `make`
// and `QueueModel.scope` run, through the same generic entry points they call, and times it over both row
// families in ALTERNATING order (`Phase0.alternating`), so a difference between the arms is the row family's and
// not the order's (L395, #4614). Then the steps `QueueEngineQueue.derive` adds around `make`, which only the
// facts arm has. Each block carries the load average (L356).
//
// OPT IN, on #4106's rule for every probe of this kind: it clones Dan's store and runs a stopwatch on a shared
// Mac (L224). Without the variable it says it did not run rather than passing silently (L98):
//
//   TEST_RUNNER_MEASURE_4623=1 mac/scripts/run-tests-locked.sh \
//     -only-testing:OvertureTests/PassCostByTermProbeTests
//
// `TEST_RUNNER_MEASURE_4623_SAMPLE=<dir outside any checkout>` also samples the whole pass over each family at
// 4x with /usr/bin/sample, so whatever no named term owns can be read from its stacks. Counts and durations
// only, never a name (L222).
@Suite("#4623 the queue pass by term, over models and over facts (opt in, live store clone)")
@MainActor
final class PassCostByTermProbeTests {

    private let sandboxes = TemporarySandboxes()
    private static var env: [String: String] { ProcessInfo.processInfo.environment }
    private static let samples = 5

    @Test(.enabled(if: Phase0.liveStoreExists, "no live store on this machine"))
    func thePassByTermOverModelsAndOverFacts() async throws {
        guard Self.env["MEASURE_4623"] != nil else {
            print("probe4623: not measured. Set TEST_RUNNER_MEASURE_4623=1 to run it.")
            return
        }
        #if DEBUG
        let build = "Debug"
        #else
        let build = "optimised, DEBUG off"
        #endif
        await RealStoreTestLock.shared.acquire()
        do {
            let dir = try sandboxes.make(named: "probe4623")
            guard let clone = try LiveStoreClone.makeClone(in: dir) else {
                throw LiveStoreClone.Refusal.backupFailed("no live store on this machine")
            }
            let sizes = (Self.env["MEASURE_4623_SIZES"] ?? "1,4").split(separator: ",").compactMap { Int($0) }
            for factor in sizes {
                let url = factor == 1 ? clone : try Phase0.scaledCopy(of: clone, factor: factor, in: dir)
                try await measure(url: url, label: "\(factor)x", build: build)
            }
            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }

    private func say(_ line: String) { print("probe4623 " + line) }

    private func measure(url: URL, label: String, build: String) async throws {
        let container = try Phase0.openContainer(at: url)
        let ctx = ModelContext(container)
        let shows = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(!shows.isEmpty, "the \(label) corpus holds no shows, so nothing was timed")
        for s in shows { _ = s.recipients.count }
        let inquiries = try ctx.fetch(FetchDescriptor<Inquiry>())
        let answers = try ctx.fetch(FetchDescriptor<OrgReachabilityAnswer>())
        let sources = try ctx.fetch(FetchDescriptor<WatchedSource>())
        let refusals = ContactRefusal.ledger(from: try ctx.fetch(FetchDescriptor<RefusedContactAddress>()))
        let overrides = ProducerOverrides(promotedRows: try ctx.fetch(FetchDescriptor<PromotedProducer>()),
                                          demotedRows: try ctx.fetch(FetchDescriptor<DemotedHouse>()))
        let geo = GeoRefusals(userExcludedTowns: Set(try ctx.fetch(FetchDescriptor<ExcludedTown>()).map(\.town)),
                              allowedSeedTowns: Set(try ctx.fetch(FetchDescriptor<AllowedSeedTown>()).map(\.town)))
        let now = Date()
        let stage = StageContext(now: now, geo: geo, clients: .none)

        // The facts as the engine holds them: one extraction of the whole store, and the shows in the engine's order.
        let facts = try FactStore.extractAll(from: ctx)
        let factRows = QueueEngineQueue.shows(facts)
        // The models in the SAME order, so the two arms sort and walk the same sequence.
        let byID = Dictionary(shows.map { ($0.persistentModelID, $0) }, uniquingKeysWith: { a, _ in a })
        let modelRows = factRows.compactMap { byID[$0.persistentModelID] }
        #expect(modelRows.count == shows.count, "a fact row had no model, so the arms are not the same rows")

        func modelInputs(_ cards: Set<String>?) -> QueueRenderPass.Inputs {
            QueueRenderPass.Inputs(allProspects: QueueRenderPass.Corpus(modelRows), inquiries: inquiries,
                                   orgAnswers: answers, sources: sources, refusals: refusals, overrides: overrides,
                                   context: stage, focusedStage: .scout, focusedKeys: nil, requestedCardKeys: cards)
        }
        let viewport = Set(QueueRenderPass.make(modelInputs([])).focusedRows
            .prefix(QueueViewportAssumption.rows).map(\.id))
        let engineInput = QueueEnginePassInput(
            facts: facts,
            viewInputs: QueueEngineViewInputs(focusedStage: .scout, focusedKeys: nil, requestedCardKeys: viewport),
            now: now, context: QueueEngineContextInputs(clients: .none))
        var factInputs = QueueEngineQueue.passInputs(engineInput, shows: factRows)
        // The models' pass checks a card in the pass and the engine's does not; take that out of the comparison so
        // the arms differ only in the row family. Its own cost is timed as a term below.
        var models = modelInputs(viewport)
        models.checksACardInThePass = false
        factInputs.checksACardInThePass = false

        let m = PassTermCensus(models)
        let f = PassTermCensus(factInputs)
        #expect(m.rows.count == f.rows.count, "the two arms built different numbers of rows")

        let loadBefore = Phase0.load()
        // The whole pass, each family, and the engine's derive around it, alternated.
        let whole = Phase0.alternating([
            ("p4623-\(label)-make-models", { _ = QueueRenderPass.make(models) }),
            ("p4623-\(label)-make-facts", { _ = QueueRenderPass.make(factInputs) }),
            ("p4623-\(label)-derive-facts", { _ = QueueEngineQueue.derive(engineInput) }),
        ], samples: 7)
        var modelsChecking = modelInputs(viewport)
        modelsChecking.checksACardInThePass = true
        let check = Phase0.alternating([
            ("p4623-\(label)-make-models-with-card-check", { _ = QueueRenderPass.make(modelsChecking) }),
            ("p4623-\(label)-make-models-no-card-check", { _ = QueueRenderPass.make(models) }),
        ])
        say("[\(label)] \(build), \(shows.count) shows, \(m.inQueue.count) in scope, \(viewport.count) cards asked, "
            + "\(loadBefore) before, \(Phase0.load()) after")
        say("[\(label)] whole make over models          \(whole[0].text)")
        say("[\(label)] whole make over facts           \(whole[1].text)")
        say("[\(label)] QueueEngineQueue.derive (facts) \(whole[2].text)")
        say("[\(label)] models with the in-pass card check \(check[0].text) against without \(check[1].text)")

        // Term by term, each alternated across the two families.
        var mSum = 0.0, fSum = 0.0
        var lines: [String] = []
        for (name, mWork) in m.terms {
            guard let fWork = f.terms.first(where: { $0.0 == name })?.1 else { continue }
            let r = Phase0.alternating([("p4623-\(label)-models-\(name)", mWork),
                                        ("p4623-\(label)-facts-\(name)", fWork)], samples: Self.samples)
            // The top level terms only: `scope whole` stands for its indented parts, which are timed beside it.
            if !name.hasPrefix("  ") { mSum += r[0].median; fSum += r[1].median }
            lines.append(Self.pad(name, 44) + " models " + r[0].text + "   facts " + r[1].text
                         + String(format: "   facts minus models %+.1f", r[1].median - r[0].median))
        }
        say("[\(label)] by term, \(Phase0.load()):\n  " + lines.joined(separator: "\n  "))
        say(String(format: "[\(label)] named terms sum: models %.1f ms of %.1f, facts %.1f ms of %.1f; unattributed "
                   + "models %.1f, facts %.1f", mSum, whole[0].median, fSum, whole[1].median,
                   whole[0].median - mSum, whole[1].median - fSum))

        // What `QueueEngineQueue.derive` does around `make`, facts only.
        var dLines: [String] = []
        let pass = QueueEngineQueue.derive(engineInput)
        let built = pass.data.cards.contents
        let extra: [(String, () -> Void)] = [
            ("shows in key order (sort)", { _ = QueueEngineQueue.shows(facts) }),
            ("passInputs (records sorted)", { _ = QueueEngineQueue.passInputs(engineInput, shows: factRows) }),
            ("cards.contents", { _ = pass.data.cards.contents }),
            ("DueWork.nextChange over facts", {
                _ = DueWork.nextChange(from: factRows, contacts: { $0.factContacts }, now: now, replyRunAlive: false)
            }),
            ("riskiestKey and its two maps", {
                let builtShows = factRows.filter { built.cards[$0.naturalKey] != nil }
                _ = QueueModel.riskiestKey(
                    among: built.cards.keys,
                    contactsByKey: Dictionary(builtShows.map { ($0.naturalKey, $0.factContacts) }, uniquingKeysWith: { a, _ in a }),
                    draftBodies: Dictionary(builtShows.map { ($0.naturalKey, $0.draftBody) }, uniquingKeysWith: { a, _ in a }))
            }),
            ("toPrep", {
                let today = EasternDate.today(now)
                _ = factRows.filter { PrepQueueBuilder.needsPrepEligible(PrepEligibilityView(row: $0), today: today) }
                    .map(ShowIdentity.init)
            }),
        ]
        for (name, work) in extra {
            let r = Phase0.alternating([("p4623-\(label)-derive-\(name)", work)], samples: Self.samples)
            dLines.append(Self.pad(name, 44) + " " + r[0].text)
        }
        say("[\(label)] derive around make, facts only, \(Phase0.load()):\n  " + dLines.joined(separator: "\n  "))

        // The stacks of the whole pass, one family at a time.
        if label == "4x" || Self.env["MEASURE_4623_SAMPLE_ALL"] != nil, let out = Self.env["MEASURE_4623_SAMPLE"] {
            for (arm, work) in [("models", { _ = QueueRenderPass.make(models) }),
                                ("facts", { _ = QueueEngineQueue.derive(engineInput) })] as [(String, () -> Void)] {
                let file = out + "/p4623-\(label)-\(arm).sample.txt"
                let sampler = Process()
                sampler.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
                sampler.arguments = ["\(getpid())", "20", "1", "-mayDie", "-file", file]
                try sampler.run()
                try? await Task.sleep(for: .seconds(4))
                let started = Phase0.now()
                var passes = 0
                while Phase0.ms(since: started) < 24_000 { work(); passes += 1 }
                sampler.waitUntilExit()
                say("[\(label)] sampled \(passes) \(arm) passes (sample exit \(sampler.terminationStatus)) to \(file)")
            }
        }
    }

    private static func pad(_ s: String, _ n: Int) -> String {
        s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
    }
}

/// Every term `QueueRenderPass.make` and `QueueModel.scope` run, over one row family, each through the entry point
/// the pass itself calls, with the values each consumes worked out once beforehand so a term is timed alone.
@MainActor
private struct PassTermCensus<Row: QueuePassRow> {
    let every: [Row]
    let inQueue: [Row]
    let rows: [QueueScopeRow]
    let terms: [(String, () -> Void)]

    init(_ i: QueueRenderPass.PassInputs<Row>) {
        let every = i.allProspects.all
        let inQueue = QueueModel.queueScope(every)
        let context = i.context.resolvingPlaces(of: inQueue)
        let now = context.now
        let today = context.today
        let overrides = i.overrides
        let tables = QueueModel.ProducerTables(rows: every, overrides: overrides)
        let scope = QueueModel.scope(from: inQueue, answers: i.orgAnswers, corpus: every, overrides: overrides,
                                     sources: i.sources, refusals: i.refusals, clients: context.clients, now: now,
                                     cardKeys: i.requestedCardKeys, today: today, checksACard: false)
        let rows = scope.rows
        let inherited = QueueModel.inheritedAnswers(i.orgAnswers, corpus: every, overrides: overrides,
                                                    refusals: i.refusals, heldKeys: [], now: now,
                                                    producerCorpus: tables.corpus)
        let reachedOut = ReachedOutQueue.activeWithDates(from: inQueue, contacts: { $0.passContacts }, now: now)
        let reachedOutKeys = Set(reachedOut.map(\.prospect.naturalKey))
        let placement = StageNavigation.placements(of: inQueue, contacts: { $0.passContacts }, context: context)
        let inAStage = StageNavigation.queueKeys(in: placement, reachedOutKeys: reachedOutKeys)
        let visibleRows = rows.filter { inAStage.contains($0.id) }
        let wanted = Set(StageNavigation.focusedKeys(stage: i.focusedStage, leadKeys: [], in: placement))
        let focusedRows = rows.filter { wanted.contains($0.id) }
        let dateGroups = QueueModel.groupByDate(focusedRows)
        let drawn = Set(inQueue.map(\.naturalKey))
        let cardKeys = i.requestedCardKeys
        let preamble = scope.cards.preamble
        var contactsByKey: [String: [Row.Contact]] = [:]
        for p in inQueue { contactsByKey[p.naturalKey] = p.factContacts }
        let cardRows = inQueue.filter { cardKeys?.contains($0.naturalKey) ?? true }
        let answers = i.orgAnswers, refusals = i.refusals, sources = i.sources, inquiries = i.inquiries
        let corpus = i.allProspects

        self.every = every
        self.inQueue = inQueue
        self.rows = rows
        self.terms = [
            ("corpus sweep and queueScope (filter+sort)", { _ = corpus.narrowed(QueueModel.queueScope).all }),
            ("geo resolvingPlaces", { _ = i.context.resolvingPlaces(of: inQueue) }),
            ("scope whole (no card check)", {
                _ = QueueModel.scope(from: inQueue, answers: answers, corpus: every, overrides: overrides,
                                     sources: sources, refusals: refusals, clients: context.clients, now: now,
                                     cardKeys: cardKeys, today: today, checksACard: false)
            }),
            ("  T6 EngagementLink.group", { _ = EngagementLink.group(among: inQueue) }),
            ("  T4 ProducerTables cold", { _ = QueueModel.ProducerTables(rows: every, overrides: overrides) }),
            ("  T5 inheritedAnswers (ledger)", {
                _ = QueueModel.inheritedAnswers(answers, corpus: every, overrides: overrides, refusals: refusals,
                                                heldKeys: [], now: now, producerCorpus: tables.corpus)
            }),
            ("  T7 organisationRowCounts", { _ = QueueModel.organisationRowCounts(among: every) }),
            ("  sourceCalendarIndex", { _ = QueueModel.sourceCalendarIndex(sources) }),
            ("  T2 ContradictedCancellation", { _ = ContradictedCancellation.contradictedKeys(among: every) }),
            ("  T1 ShowLink.group", { _ = ShowLink.group(among: every) }),
            ("  T8 titlesByKey", { _ = QueueModel.titlesByKey(among: every) }),
            ("  T1 ShowLink.collapse", { _ = ShowLink.collapse(among: every, drawn: drawn) }),
            ("  T8 laterLookalikes", { _ = QueueModel.laterLookalikes(among: every) }),
            ("  T8 nightsByKey", { _ = QueueModel.nightsByKey(among: every) }),
            ("  T7 row loop (contacts, RecipientFacts, row)", {
                for p in inQueue {
                    let contacts = p.factContacts
                    _ = QueueScopeRow(p, facts: RecipientFacts.of(p, contacts: contacts),
                                      inheritedReachability: inherited[p.naturalKey])
                }
            }),
            ("    of which factContacts read", { for p in inQueue { _ = p.factContacts } }),
            ("  cards for the viewport", {
                for p in cardRows { _ = QueueModel.card(p, among: contactsByKey[p.naturalKey] ?? [], preamble: preamble) }
            }),
            ("  CardStore's card sources", { _ = Row.cardSources(shows: inQueue, contacts: contactsByKey) }),
            ("T7 ReachedOutQueue.activeWithDates", {
                _ = ReachedOutQueue.activeWithDates(from: inQueue, contacts: { $0.passContacts }, now: now)
            }),
            ("T7 StageNavigation.placements", {
                _ = StageNavigation.placements(of: inQueue, contacts: { $0.passContacts }, context: context)
            }),
            ("queueKeys, focusedKeys, row filters", {
                let keys = StageNavigation.queueKeys(in: placement, reachedOutKeys: reachedOutKeys)
                _ = rows.filter { keys.contains($0.id) }
                let w = Set(StageNavigation.focusedKeys(stage: .scout, leadKeys: [], in: placement))
                _ = rows.filter { w.contains($0.id) }
            }),
            ("T3 feed breaks (contradicted handed in)", {
                _ = AppNotices.feedBreaks(FeedBreakEvent.events(among: every, asOf: today,
                                                                contradicted: scope.contradictedCancellations),
                                          shownInQueue: { inAStage.contains($0) })
            }),
            ("T8 unseenSurvivors", {
                _ = QueueRenderPass.unseenSurvivors(of: every, today: today, closed: { $0.passIsClosed })
            }),
            ("T8 keysMissedByACheck", {
                _ = QueueModel.keysMissedByACheck(rows, now: now, today: today, geo: context.geo)
            }),
            ("T8 summary", { _ = QueueModel.summary(visibleRows) }),
            ("inquiryRows", { _ = QueueRenderPass.inquiryRows(inquiries, stage: .scout, now: now) }),
            ("T8 groupByDate and dateProbeHeadings", {
                let g = QueueModel.groupByDate(focusedRows)
                _ = QueueModel.dateProbeHeadings(g, now: now, today: today, geo: context.geo)
            }),
            ("T8 queueScope identities", { _ = inQueue.map { ShowIdentity($0) } }),
            ("T8 selfBookingIndex", { _ = QueueModel.selfBookingIndex(rows) }),
            ("T7 AgentInputs.from", {
                _ = AgentInputs.from(prospects: inQueue, allProspects: every, contacts: { $0.passContacts },
                                     inquiries: inquiries, context: context, gmailConnected: false,
                                     runInFlight: nil, replyRunAlive: false, placement: placement,
                                     reachedOut: reachedOut)
            }),
            ("reachedOut snapshots", {
                _ = reachedOut.map { ReachedOutSnapshot(show: $0.prospect, contact: $0.recipient, next: $0.next) }
            }),
            ("T8 pendingBookingCount", { _ = QueueModel.pendingBookingCount(rows) }),
            ("T8 fanOutWarning", { _ = QueueRenderPass.fanOutWarning(inQueue) }),
            ("stage counts", { _ = StageNavigation.counts(in: placement) }),
        ]
        _ = dateGroups
    }
}
