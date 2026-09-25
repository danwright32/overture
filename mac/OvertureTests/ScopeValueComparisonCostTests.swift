import Testing
import Foundation
import SwiftData

// #4252: what serving a refetch costs, against the derivation it saves, per surface.
//
// THE CHOICE THIS HOLDS HONEST. A memo keyed by a `ScopeFingerprint` names what an observed change with no
// save behind it means (`ScopeMemo.Refetch`). Serving it re-registers observation on every stored property
// of every row the memo was handed, so it is only a saving where that costs less than deriving again. Each
// surface's choice rests on that comparison, so the comparison is asserted here for each, as a RATIO in the
// same run rather than a number of milliseconds, which would be measuring the machine (L224, L63, L316).
//
// The opt-in half reads the live store and prints the numbers #4252's PR quotes.
@MainActor
@Suite("Serving a refetch costs less than the derivation it saves, where it is chosen (#4252)")
struct ScopeValueComparisonCostTests {

    // The same live shape as `QueueRenderPassCostTests`, so check-fixture-corpus-drift.sh holds it too.
    // LIVE-SHAPE: prospects
    private static let corpusSize = 1224

    // The live store's watched sources, measured 2026-09-25.
    private static let sourceCount = 74

    private let sandboxes = TemporarySandboxes()

    private func container() throws -> ModelContainer {
        try TestModelContainer.inMemory(AppSchema.models)
    }

    // Most rows untriaged, the rest drafted or contacted, and every contacted row carrying a recipient,
    // because re-arming walks into recipients and a corpus with none would flatter it.
    private func seed(_ ctx: ModelContext) -> [Prospect] {
        let venues = ["Weill Recital Hall", "SoHo Playhouse", "The Green Room 42", "Merkin Hall",
                      "Roulette Intermedium", "The Tank", "Bargemusic", "David Geffen Hall"]
        var rows: [Prospect] = []
        for n in 0..<Self.corpusSize {
            let date = String(format: "2026-%02d-%02d", 8 + (n % 4), 1 + (n % 27))
            let venue = venues[n % venues.count]
            let contacted = n >= 545 && n % 2 == 1
            let p = Prospect(naturalKey: "row-\(n)", groupName: "Ensemble \(n % 90)", discipline: "music",
                             venue: venue, performanceDate: date, sourceListingURL: nil,
                             priorRelationship: "none", production: n % 3 == 0 ? "self" : "presenter",
                             profile: "strong", coverage: "likely_uncovered", fitScore: 4 + (n % 5),
                             tier: "mid", fitReason: "r", matchedClientName: nil,
                             possibleMatchSource: nil, possibleMatchName: nil,
                             status: n < 545 ? .new : (contacted ? .contacted : .drafted))
            p.presenter = "Ensemble \(n % 90) Presents"
            p.location = "New York, NY"
            p.runNights = [date]
            ctx.insert(p)
            if contacted {
                p.recipients.append(Recipient(id: "r-\(n)", email: "r\(n)@example.com", name: "Contact \(n)",
                                              role: "press", provenance: .presenter))
            }
            rows.append(p)
        }
        try? ctx.save()
        return rows
    }

    private static func median(_ work: () -> Void) -> Double {
        var runs: [Double] = []
        for _ in 0..<5 {
            let start = DispatchTime.now().uptimeNanoseconds
            work()
            runs.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        return runs.sorted()[2]
    }

    private struct Costs {
        let arm: Double
        let queue: Double
        let archive: Double
        let due: Double
        let sources: Double
    }

    // Every surface's derivation, as its call site runs it, and what re-arming its inputs costs.
    private func measure(_ rows: [Prospect], sources: [WatchedSource], inquiries: [Inquiry],
                         now: Date) -> Costs {
        var key = ScopeFingerprint()
        key.add(rows)
        func arm() { withObservationTracking { key.sources.armAll() } onChange: {} }
        func queue() {
            _ = QueueRenderPass.make(QueueRenderPass.Inputs(
                allProspects: QueueRenderPass.Corpus(rows), inquiries: inquiries, orgAnswers: [],
                sources: sources, context: .at(EasternDate.dayString(from: now), now: now),
                focusedStage: .scout, focusedKeys: nil, requestedCardKeys: []))
        }
        func archive() { _ = QueueModel.scope(from: rows, answers: [], sources: sources, cardKeys: []) }
        func due() {
            _ = DueWork.countAndNextChange(prospects: rows, inquiries: inquiries, now: now, replyRunAlive: false)
        }
        func sourcesSheet() {
            _ = SourcesRenderPass.make(SourcesRenderPass.Inputs(
                prospects: SourcesRenderPass.Corpus(rows), sources: sources, searchQuery: "",
                context: StageContext(now: now, geo: .none, clients: .none)))
        }
        // Warm every path once, so no reading below is the one that faults the rows in.
        arm(); queue(); archive(); due(); sourcesSheet()
        return Costs(arm: Self.median(arm), queue: Self.median(queue), archive: Self.median(archive),
                     due: Self.median(due), sources: Self.median(sourcesSheet))
    }

    @Test func eachSurfacesChoiceIsTheCheaperOne() throws {
        let ctx = ModelContext(try container())
        let rows = seed(ctx)
        var sources: [WatchedSource] = []
        for n in 0..<Self.sourceCount {
            let s = WatchedSource(sourceId: "src-\(n)", orgName: "Ensemble \(n)",
                                  listingsURL: "https://org\(n).example/events", kind: .html)
            ctx.insert(s)
            sources.append(s)
        }
        try ctx.save()
        let costs = measure(rows, sources: sources, inquiries: [],
                            now: Date(timeIntervalSince1970: 1_785_000_000))
        print("scope-refetch-cost: arm \(costs.arm) ms, queue \(costs.queue) ms, archive \(costs.archive) ms, "
              + "due \(costs.due) ms, sources \(costs.sources) ms over \(rows.count) shows")

        // THE POSITIVE CONTROL: arming nothing is free and would make every comparison below pass.
        #expect(costs.arm > 0.5, Comment(rawValue:
            "re-arming \(rows.count) shows took \(costs.arm) ms, so it walked nothing and every ratio below "
            + "is against zero"))
        // `.serveWhenNothingChanged`: QueueView and ArchiveView.
        #expect(costs.arm < costs.queue, Comment(rawValue:
            "re-arming (\(costs.arm) ms) costs more than the queue pass (\(costs.queue) ms), so serving the "
            + "refetch is no longer a saving and QueueView should rebuild"))
        #expect(costs.arm < costs.archive, Comment(rawValue:
            "re-arming (\(costs.arm) ms) costs more than the Archive scope (\(costs.archive) ms), so "
            + "ArchiveView should rebuild"))
        // `.rebuild`: RootView's Due count and the Sources sheet.
        #expect(costs.due < costs.arm, Comment(rawValue:
            "the Due count (\(costs.due) ms) now costs more than re-arming (\(costs.arm) ms), so RootView "
            + "should serve its refetch instead of deriving again"))
        #expect(costs.sources < costs.arm, Comment(rawValue:
            "the Sources pass (\(costs.sources) ms) now costs more than re-arming (\(costs.arm) ms), so "
            + "SourcesView should serve its refetch instead of deriving again"))
    }

    // The live store, opt in: the numbers #4252's PR quotes, and the refetch it asked to be measured.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: StoreLocation.storeURL(
        appSupport: StoreLocation.appSupport, isDebugBuild: false).path), "no live store on this machine"))
    func measureAgainstTheLiveStore() throws {
        guard ProcessInfo.processInfo.environment["MEASURE_QUEUE_LIVE_STORE"] != nil else {
            print("scope-refetch-cost-live: not measured. Set TEST_RUNNER_MEASURE_QUEUE_LIVE_STORE=1.")
            return
        }
        let dir = try sandboxes.make(named: "scope-refetch-live")
        guard let clone = try LiveStoreClone.makeClone(in: dir) else {
            throw LiveStoreClone.Refusal.backupFailed("no live store on this machine")
        }
        let c = try ModelContainer(for: AppSchema.schema, configurations: [
            ModelConfiguration(schema: AppSchema.schema, url: clone, cloudKitDatabase: .none)])
        let ctx = ModelContext(c)
        let rows = try ctx.fetch(FetchDescriptor<Prospect>())
        let sources = try ctx.fetch(FetchDescriptor<WatchedSource>())
        let inquiries = try ctx.fetch(FetchDescriptor<Inquiry>())
        let costs = measure(rows, sources: sources, inquiries: inquiries, now: Date())
        let recipients = rows.reduce(0) { $0 + $1.recipients.count }

        // #4252 item 2: the refetch after a save, in the SAME context the way `@Query` does it, against a
        // narrow fetch that reads three columns and none of the archived lists.
        func refetchAfterSave(_ descriptor: FetchDescriptor<Prospect>) -> Double {
            var runs: [Double] = []
            for i in 0..<5 {
                rows[i].fitReason += " "
                try? ctx.save()
                let start = DispatchTime.now().uptimeNanoseconds
                _ = ((try? ctx.fetch(descriptor)) ?? []).count
                runs.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            }
            return runs.sorted()[2]
        }
        let full = refetchAfterSave(FetchDescriptor<Prospect>())
        var narrow = FetchDescriptor<Prospect>()
        narrow.propertiesToFetch = [\Prospect.naturalKey, \Prospect.statusRaw, \Prospect.performanceDate]
        let narrowMs = refetchAfterSave(narrow)
        let archived = Self.median {
            for p in rows {
                _ = p.runNights.count; _ = p.sourceIds.count; _ = p.runSourceURLs.count
                _ = p.nightStartTimes.count; _ = p.droppedRunNights.count; _ = p.pitchedRunNights.count
                _ = p.skippedRunNights.count; _ = p.performanceStartTimes.count
            }
        }
        print("""
            scope-refetch-cost-live: \(rows.count) shows, \(recipients) recipients, \(sources.count) sources
              re-arming every stored property   \(costs.arm) ms
              queue pass                        \(costs.queue) ms
              Archive scope                     \(costs.archive) ms
              Due count                         \(costs.due) ms
              Sources sheet pass                \(costs.sources) ms
              refetch after a save              \(full) ms full, \(narrowMs) ms three columns
              every archived list on every show, warm: \(archived) ms
            """)
    }
}
