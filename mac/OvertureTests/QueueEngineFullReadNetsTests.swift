import Foundation
import SwiftData
import Testing

// #4358 slice E4, the cutover's precondition. The queue engine reads EVERY row again, on the main actor, when one
// of its nets fires: a save naming a model `AppSchemaInputClass` does not classify (`unclassifiedSaves`), an insert
// the unique key merged into a stored row (`insertsMergedAway`), a read that threw (`unreadRows`), and a save
// through another context whose identifiers never reached it (`foreignSaves` with no attributed rows). That read
// cost 794.9 ms at 1x and 3,237.1 ms at 4x when slice E1a measured it, so one net firing on an ordinary path is a
// freeze the cutover would ship. The 2026-10-06 status on #4358 asked for the counters over a day of real use
// before the cutover; a day of real use cannot happen while nothing in the app builds the engine, so this drives
// the nearest thing: the app's own entry points and actions, through the app's own functions, with the engine
// attached to the store and its turns scheduled the way the app schedules them (the next main actor turn, so they
// interleave with a landing's awaits exactly as they will in the app).
//
// Two arms over ONE set of steps (`RealUseSteps`), so the guard and the measurement cannot drift apart:
//   * `QueueEngineFullReadNetsTests`, in every run: the synthetic landing corpus (invented shows, L222) through all
//     three entry points that land shows, then every ordinary action, asserting no net fires and nothing reads the
//     whole store; and, in the same fixture, a merged insert and a foreign save that MUST trip theirs (L159), so
//     a quiet net is known to be a net that can speak.
//   * `QueueEngineNetsRealUseProbeTests`, opt in: the frozen 1x and 4x live store inputs of #4327 step 0.0 (the
//     real arm's archive), a real landing of the recorded results plus the same actions, printing every counter
//     and the engine's main actor time per step. Counts and durations only, never a name (L222).

/// What the engine counted while one step of real use ran, and the main actor time its turns took.
struct EngineNetReading: CustomStringConvertible {
    let step: String
    /// Whether the step found something to act on and did it. A step that did nothing measures nothing (L159).
    let exercised: Bool
    let turns: Int
    let rowsChanged: Int
    let fullReads: Int
    let foreignSaves: Int
    let unclassifiedSaves: Int
    let insertsMergedAway: Int
    let unreadRows: Int
    let turnMs: Double
    let longestTurnMs: Double

    var netsFired: Int { foreignSaves + unclassifiedSaves + insertsMergedAway + unreadRows }

    var description: String {
        let name = step.padding(toLength: 26, withPad: " ", startingAt: 0)
        guard exercised else { return "\(name) NOT EXERCISED: nothing in the store to act on" }
        return String(format: "%@ turns %3d  rows changed %5d  full reads %d  foreign %d  unclassified %d  "
                      + "merged inserts %d  unread %d  engine turns %8.1f ms (longest %7.1f)",
                      name, turns, rowsChanged, fullReads, foreignSaves, unclassifiedSaves, insertsMergedAway,
                      unreadRows, turnMs, longestTurnMs)
    }
}

/// The app's schedule (`QueueEngineTurns.nextTurn`: the next main actor turn), with each turn timed and the turns
/// still owed counted, so a step can wait for the engine to have taken in everything it caused.
@MainActor
final class EngineAppTurns {
    private(set) var owed = 0
    private(set) var turnMs: [Double] = []

    var schedule: QueueEngineSchedule {
        { [weak self] work in
            self?.owed += 1
            Task { @MainActor in
                let started = Phase0.now()
                work()
                self?.turnMs.append(Phase0.ms(since: started))
                self?.owed -= 1
            }
        }
    }

    /// Waits for every owed turn, and any those ask for, to have run.
    func settle() async -> Bool {
        await waitUntil("the engine's owed turns", timeout: .seconds(300)) { owed == 0 }
    }
}

/// One store with the engine attached, and every step's reading.
@MainActor
final class EngineNetRun {
    struct Unsettled: Error, CustomStringConvertible {
        let step: String
        var description: String { "the engine still owed turns five minutes after \(step)" }
    }

    let context: ModelContext
    let engine: CountsEngine
    private let turns: EngineAppTurns
    private(set) var readings: [EngineNetReading] = []

    init(context: ModelContext) {
        self.context = context
        let turns = EngineAppTurns()
        self.turns = turns
        // The app's clock and schedule; notification centres of the test's own, so no real wake or day change
        // reaches it; a private save counter; the verifier only when asked, so a step's counts are its own.
        engine = QueueEngine(context: context, derivation: EngineDerivations.counts(), saves: StoreSaveCount(),
                             clock: .system,
                             events: QueueEngineSystemEvents(workspace: NotificationCenter(), system: NotificationCenter()),
                             schedule: turns.schedule, verifier: QueueEngineVerifierSetup(triggers: .byHand))
    }

    /// Runs `work`, waits for the engine to take in what it caused, and records what the engine counted.
    @discardableResult
    func step(_ name: String, _ work: () async throws -> Bool) async throws -> EngineNetReading {
        let before = engine.counters
        let first = turns.turnMs.count
        let exercised = try await work()
        guard await turns.settle() else { throw Unsettled(step: name) }
        let after = engine.counters
        let times = Array(turns.turnMs[first...])
        let reading = EngineNetReading(
            step: name, exercised: exercised, turns: after.turns - before.turns,
            rowsChanged: after.rowsChanged - before.rowsChanged, fullReads: after.fullReads - before.fullReads,
            foreignSaves: after.foreignSaves.times - before.foreignSaves.times,
            unclassifiedSaves: after.unclassifiedSaves.times - before.unclassifiedSaves.times,
            insertsMergedAway: after.insertsMergedAway.times - before.insertsMergedAway.times,
            unreadRows: after.unreadRows.times - before.unreadRows.times,
            turnMs: times.reduce(0, +), longestTurnMs: times.max() ?? 0)
        readings.append(reading)
        return reading
    }

    /// What one forced verification said. `received` false is no verdict at all, never a match (L98).
    struct Verdict: CustomStringConvertible {
        let received: Bool
        let matches: Int
        let factMismatches: Int
        let outputMismatches: Int
        let other: String

        var description: String {
            guard received else { return "UNMEASURED: no verdict in two minutes" }
            return "matches \(matches), fact mismatches \(factMismatches), output mismatches \(outputMismatches), "
                + other
        }
    }

    /// The verifier's verdict on the engine's facts against a fresh read of the saved store, once asked for.
    func verify() async -> Verdict {
        let before = engine.verifierCounts
        func verdicts(_ c: QueueEngineVerifierCounts) -> Int {
            c.matches + c.factMismatches + c.outputMismatches + c.superseded + c.cancelled
                + c.unmeasured.values.reduce(0, +)
        }
        engine.verifyNow()
        let received = await waitUntil("the verifier's verdict", timeout: .seconds(120)) {
            verdicts(engine.verifierCounts) > verdicts(before)
        }
        let c = engine.verifierCounts
        return Verdict(received: received, matches: c.matches - before.matches,
                       factMismatches: c.factMismatches - before.factMismatches,
                       outputMismatches: c.outputMismatches - before.outputMismatches,
                       other: "superseded \(c.superseded - before.superseded), cancelled "
                           + "\(c.cancelled - before.cancelled), unmeasured \(c.unmeasured)")
    }
}

/// A sender that records nothing and reaches nothing: the send path's network half, answered at once (L2).
private struct NoNetworkSender: MailSender {
    func send(_ mail: OutgoingMail) async throws -> SentReceipt {
        SentReceipt(threadId: "probe-thread", messageID: "<probe@example.org>")
    }
}

/// A page fetch a corpus landing made, which has no page to fetch: said as itself, never as another failure (L11).
private struct ReachedForTheNetwork: Error, CustomStringConvertible {
    let url: URL
    var description: String { "the native sweep reached for the network: \(url)" }
}

/// A native source's read, answered with events in hand.
private struct EventsInHand: SourceExtractor {
    let events: [ExtractedEvent]
    func extract() async throws -> ExtractedListing { ExtractedListing(events: events, verdict: .upcomingListings) }
}

/// Every step of real use the probe drives, each through the function the app's own control calls, each saying
/// whether it found something to act on. Shared by both arms, so the guard drives what the probe measures.
@MainActor
enum RealUseSteps {
    static func shows(_ context: ModelContext) throws -> [Prospect] {
        Prospect.inKeyOrder(try context.fetch(FetchDescriptor<Prospect>()))
    }

    /// Keep: the first untriaged show, through the Keep control's own call.
    static func keep(_ context: ModelContext) throws -> Bool {
        let all = try shows(context)
        guard let show = all.first(where: { $0.status == .new }) else { return false }
        ProspectMutations.setStatus(QueueItem(show), .queued, nil, shows: all, context: context,
                                    feedback: ActionFeedback(), undoLabel: "Keep")
        return show.status == .queued
    }

    /// Dismiss one show for a reason, through the reason menu's call.
    static func dismiss(_ context: ModelContext, export: DayOffEditing.Export) throws -> Bool {
        let all = try shows(context)
        guard let show = all.first(where: { $0.status == .new }) else { return false }
        ProspectMutations.dismissForReason(QueueItem(show), .notAFit, shows: all, context: context,
                                           feedback: ActionFeedback(), offer: DayOffOfferRequest(), export: export)
        return show.status == .dismissed
    }

    /// Dismiss a whole night: the first night holding two or more untriaged shows.
    static func dismissNight(_ context: ModelContext, export: DayOffEditing.Export) throws -> Bool {
        let all = try shows(context)
        let nights = Dictionary(grouping: all.filter { $0.status == .new && $0.performanceDate != nil }) {
            $0.performanceDate ?? ""
        }
        guard let night = nights.keys.sorted().first(where: { (nights[$0]?.count ?? 0) >= 2 }),
              let rows = nights[night] else { return false }
        ProspectMutations.dismissAll(rows.map(\.naturalKey), reason: .pitchingOtherShows, dateLabel: night,
                                     nightDate: night, shows: all, context: context, feedback: ActionFeedback(),
                                     export: export)
        return rows.allSatisfy { $0.status == .dismissed }
    }

    /// Edit a kept show's draft, through the editor's save.
    static func editDraft(_ context: ModelContext) throws -> Bool {
        let all = try shows(context)
        guard let show = all.first(where: { $0.status == .queued && $0.sentAt == nil }) else { return false }
        let body = "We would love to photograph the show. Probe draft \(all.count)."
        ProspectMutations.saveDraft(QueueItem(show), "Photographs of your show", body, shows: all, context: context,
                                    feedback: ActionFeedback())
        return show.draftBody == body
    }

    /// Keep a show still ahead of us, draft it, add a contact by hand, approve and send: the Keep control, the
    /// editor's save, the Add contact control, the approval, then the send path with its network answered at
    /// once. Its own show, because the send gate refuses a show whose last night has passed or whose date
    /// clashes, and the steps before it take the first untriaged show whatever its date.
    static func send(_ context: ModelContext, now: Date) async throws -> Bool {
        let all = try shows(context)
        let today = EasternDate.today(now)
        guard let show = all.first(where: {
            $0.status == .new && !$0.hasUnclearedConflict
                && !EasternDate.lastNightHasPassed(performanceDate: $0.performanceDate, runEndDate: $0.runEndDate,
                                                   today: today)
        }) else { return false }
        let feedback = ActionFeedback()
        ProspectMutations.setStatus(QueueItem(show), .queued, nil, shows: all, context: context, feedback: feedback)
        ProspectMutations.saveDraft(QueueItem(show), "Photographs of your show",
                                    "Hello,\n\nI would love to photograph the show.\n\nBest,\nDan", shows: all,
                                    context: context, feedback: feedback)
        ProspectMutations.addRecipientManually(QueueItem(show), email: "probe-contact@example.org", name: nil,
                                               shows: all, context: context, feedback: feedback)
        // Approve, as `approveAndSend` does for a drafted show, then the send itself.
        ProspectMutations.setStatus(QueueItem(show), .approved, nil, shows: all, context: context, feedback: feedback)
        let sent = await SendService.sendNext(show, now: now, sender: NoNetworkSender())
        try context.save()
        if !sent {
            let gate = show.recipients.map { "\($0.sendState) sendable \($0.isSendablePending(today: today))" }
            print("engine-nets: the send refused: status \(show.status), contacts \(gate)")
        }
        return sent && show.sentAt != nil
    }

    /// Log a direct hire inquiry, as the inquiry sheet does.
    static func logInquiry(_ context: ModelContext) throws -> Bool {
        InquiryIntake.create(source: .contactForm, name: "Robin Example", email: "robin@example.org",
                       eventName: "Probe Gala", performanceDate: nil, venue: nil, notes: nil, in: context)
        try context.save()
        return true
    }

    /// Mark an organisation as a producer, a small table insert.
    static func promoteProducer(_ context: ModelContext) -> Bool {
        ProducerOverrideEditing.promote("Invented Probe Presents", into: context) == .promoted
    }

    /// Strike a contact address on a show, a small table insert.
    static func refuseContact(_ context: ModelContext) throws -> Bool {
        guard let show = try shows(context).first else { return false }
        ContactRefusal.refuse(email: "struck-probe@example.org", scope: .show(show.naturalKey), in: context)
        try context.save()
        return true
    }

    /// Never show this town again, a small table insert.
    static func excludeTown(_ context: ModelContext) -> Bool {
        ExcludedTownEditing.exclude(town: "Probeville", into: context) == .added
    }

    /// The reconcile tick's laps that write the store (bookings with the score settle, conflicts, retirement),
    /// against the export at `exportURL`. Its Gmail and OmniFocus laps reach outside services and are left out.
    static func reconcile(_ context: ModelContext, exportURL: URL, now: Date) -> Bool {
        let scheduler = ReconcileScheduler(context: context, replyRunAlive: { _ in false })
        let rows = StoreRows.fetch(from: context)
        scheduler.reconcileBookings(now: now, from: exportURL, rows: rows)
        scheduler.reapplyConflicts(now: now, from: exportURL, prospects: rows.liveProspects)
        scheduler.retireShowsThatOpened(now: now)
        return true
    }

    /// Add a lead: one pasted page, its read answered at once with `events`, through the Add lead sheet's model.
    static func pasteLead(_ context: ModelContext, url: String, events: [ScoutExtractEvent], today: String,
                          now: Date) async throws -> Bool {
        guard let page = URL(string: url) else { return false }
        let leadId = LeadIntakeModel.sourceId(for: page)
        let answer = ScoutExtractResults(version: 1, generatedAt: today + "T12:00:00Z", results: [
            ScoutExtractResult(sourceId: leadId, verdict: .upcomingListings, events: events, note: nil),
        ])
        let html = LandingOracleCorpus.leadPage
        let model = LeadIntakeModel(
            defaults: ScratchDefaults.make("QueueEngineFullReadNets.lead"),
            fetch: { FetchedPage(normalizedHTML: html, finalURL: $0.absoluteString, contentHash: "probe-" + leadId) },
            pin: { _, name in URL(fileURLWithPath: "/dev/null/probe-\(name).html") }, launch: { _ in },
            readResults: { $0 == leadId ? answer : nil }, isRunAlive: { false })
        model.urlText = url
        await model.start(into: context, now: now, today: today, pollEvery: 0, giveUpAfter: 0, sleep: { _ in })
        guard case .added = model.phase else { return false }
        try context.save()
        return true
    }

    /// Every ordinary action, in the order a morning's triage takes them.
    static func actions(on run: EngineNetRun, export: DayOffEditing.Export, exportURL: URL, now: Date) async throws {
        let context = run.context
        try await run.step("keep") { try keep(context) }
        try await run.step("dismiss") { try dismiss(context, export: export) }
        try await run.step("dismiss a night") { try dismissNight(context, export: export) }
        try await run.step("edit a draft") { try editDraft(context) }
        try await run.step("add contact and send") { try await send(context, now: now) }
        try await run.step("log an inquiry") { try logInquiry(context) }
        try await run.step("mark a producer") { promoteProducer(context) }
        try await run.step("strike an address") { try refuseContact(context) }
        try await run.step("exclude a town") { excludeTown(context) }
        try await run.step("reconcile laps") { reconcile(context, exportURL: exportURL, now: now) }
    }
}

// MARK: - The guard, in every run, on the synthetic corpus

@Suite("#4358 E4: a landing and every ordinary action leave the engine's full-read nets quiet")
@MainActor
final class QueueEngineFullReadNetsTests {

    private static let noExport = URL(fileURLWithPath: "/dev/null/no-downbeat-export.json")

    private static var export: DayOffEditing.Export {
        let loaded = DownbeatBridge.loadWithHealth(from: noExport, now: LandingOracleCorpus.now)
        return (loaded.bookings, loaded.blockedDates, loaded.health)
    }

    /// A seeded synthetic store with the engine attached and started.
    private func started(kind: SourceKind = .html) async throws -> EngineNetRun {
        let container = try TestModelContainer.inMemory(AppSchema.models)
        try LandingOracleCorpus.seed(into: container.mainContext, kind: kind)
        let run = EngineNetRun(context: container.mainContext)
        try await run.step("start") {
            run.engine.start()
            return true
        }
        return run
    }

    private func expectQuiet(_ run: EngineNetRun) {
        for reading in run.readings.dropFirst() {
            #expect(reading.exercised, "\(reading.step) found nothing to act on, so it measured nothing")
            #expect(reading.netsFired == 0 && reading.fullReads == 0,
                    "\(reading.step) tripped a full-read net on an ordinary path: \(reading)")
        }
    }

    @Test func theExtractIngestAndEveryActionAfterItLeaveTheNetsQuiet() async throws {
        let run = try await started()
        try await run.step("scout landing (ingest)") {
            _ = await ScoutExtractIngest.ingest(LandingOracleCorpus.results(), clients: [], history: [],
                                                blocked: .empty, today: LandingOracleCorpus.today,
                                                now: LandingOracleCorpus.now, into: run.context)
            try run.context.save()
            return true
        }
        try await RealUseSteps.actions(on: run, export: Self.export, exportURL: Self.noExport,
                                       now: LandingOracleCorpus.now)
        expectQuiet(run)
    }

    @Test func theNativeSweepLeavesTheNetsQuiet() async throws {
        if let refusal = LandingOracleCorpus.handoffInputsRefusal() {
            Issue.record(Comment(rawValue: refusal))
            return
        }
        let run = try await started(kind: .squarespaceFeed)
        let byId = Dictionary(uniqueKeysWithValues: LandingOracleCorpus.sources.map { ($0.id, $0) })
        try await run.step("scout landing (runScout)") {
            let outcome = try await ScoutService.runScout(
                into: run.context, depth: .watchOnly, extractor: EventsInHand(events: []),
                extractorRegistry: { source in
                    EventsInHand(events: source.flatMap { byId[$0.sourceId] }?.events.map(\.asExtractedEvent) ?? [])
                },
                fetch: { url, _, _ in throw ReachedForTheNetwork(url: url) },
                pin: { _, id in URL(fileURLWithPath: "/dev/null/probe-\(id).html") }, launch: { _ in },
                now: LandingOracleCorpus.now, defaults: ScratchDefaults.make("QueueEngineFullReadNets.runScout"))
            try run.context.save()
            return outcome.sources.contains { if case .ingested = $0.state { return true } else { return false } }
        }
        expectQuiet(run)
    }

    @Test func theLeadPasteLeavesTheNetsQuiet() async throws {
        if let refusal = LandingOracleCorpus.handoffInputsRefusal() {
            Issue.record(Comment(rawValue: refusal))
            return
        }
        let run = try await started()
        for source in LandingOracleCorpus.sources {
            try await run.step("add a lead (\(source.id))") {
                try await RealUseSteps.pasteLead(run.context, url: source.listingsURL, events: source.events,
                                                 today: LandingOracleCorpus.today, now: LandingOracleCorpus.now)
            }
        }
        expectQuiet(run)
    }

    // The positive control, in the same fixture (L159): an insert the unique key merges into a stored row trips its
    // net and costs exactly one full read. Without it, every quiet reading above could be a net that never speaks.
    @Test func anInsertMergedIntoAStoredRowTripsItsNetInTheSameFixture() async throws {
        let run = try await started()
        let reading = try await run.step("merged insert") {
            guard let stored = try RealUseSteps.shows(run.context).first else { return false }
            run.context.insert(Prospect(naturalKey: stored.naturalKey, groupName: stored.groupName, discipline: "music",
                                        venue: stored.venue, performanceDate: stored.performanceDate,
                                        sourceListingURL: nil, priorRelationship: "none", production: "self",
                                        profile: "strong", coverage: "likely_uncovered", fitScore: 5, tier: "mid",
                                        fitReason: "merged", matchedClientName: nil, possibleMatchSource: nil,
                                        possibleMatchName: nil, ingestedAt: LandingOracleCorpus.now))
            try run.context.save()
            return true
        }
        #expect(reading.insertsMergedAway == 1 && reading.fullReads == 1,
                "a merged insert must trip its net and read the store once: \(reading)")
    }

    // The foreign save net, in the same fixture: a save through a second context is counted (and, attributed, costs
    // no full read since slice E2). The two nets with no control here cannot be produced by a save the app can make:
    // `unclassifiedSaves` needs a model `AppSchemaInputClass` lacks, which `AppSchemaInputClassTests` refuses, and
    // `unreadRows` needs a store read that throws, which E1a's intake suite stubs. What each of them costs is the
    // full read, and `fullReads` is the quantity every step above asserts, proven to speak by the control above.
    @Test func aSaveThroughAnotherContextTripsItsNetInTheSameFixture() async throws {
        let run = try await started()
        let reading = try await run.step("foreign save") {
            let other = ModelContext(run.context.container)
            guard let show = try other.fetch(FetchDescriptor<Prospect>()).first else { return false }
            show.fitReason = "written through another context"
            try other.save()
            return true
        }
        #expect(reading.foreignSaves == 1 && reading.fullReads == 0,
                "a foreign save must be counted, attributed, with no full read: \(reading)")
    }
}

// MARK: - The measurement, opt in, on the frozen live store inputs

// OPT IN: it copies the frozen inputs of Dan's store (#4327 step 0.0, read only, checked against their MANIFEST)
// and runs a stopwatch, which measures whatever else the machine is doing (L224). Without the variable it says it
// did not run, rather than passing silently (L98):
//
//   TEST_RUNNER_MEASURE_4358_PRECONDITION=1 \
//   TEST_RUNNER_MEASURE_4275_INPUTS=~/.overture-oracle/4275-frozen-inputs-20260929-rescaled-20261005 \
//   mac/scripts/run-tests-locked.sh -only-testing:OvertureTests/QueueEngineNetsRealUseProbeTests
//
// Debug, one pass per size with the load average printed beside it. Every step is the same one the guard above
// drives, so the probe and the guard cannot be about different things.
@Suite("#4358 E4 precondition: the engine's full-read nets over real use (opt in, frozen live store inputs)")
@MainActor
final class QueueEngineNetsRealUseProbeTests {

    private let sandboxes = TemporarySandboxes()
    private static let env = ProcessInfo.processInfo.environment

    @Test func theNetsOverALandingAndAMorningsActionsAtOneAndFourTimes() async throws {
        guard Self.env["MEASURE_4358_PRECONDITION"] != nil else {
            print("engine-nets: not measured. Set TEST_RUNNER_MEASURE_4358_PRECONDITION=1 to run it.")
            return
        }
        guard let inputs = Self.env["MEASURE_4275_INPUTS"] else {
            Issue.record("UNMEASURED: TEST_RUNNER_MEASURE_4275_INPUTS must name the frozen inputs archive")
            return
        }
        let archive = URL(fileURLWithPath: (inputs as NSString).expandingTildeInPath)
        guard let manifest = LandingOracle.manifest(at: archive.appendingPathComponent("MANIFEST")) else {
            Issue.record("UNMEASURED: the frozen inputs carry no readable MANIFEST")
            return
        }
        if let refusal = LandingOracle.inputsRefusal(archive: archive, manifest: manifest) {
            Issue.record(Comment(rawValue: refusal))
            return
        }
        guard let today = manifest.facts["today"], let nowText = manifest.facts["now"],
              let now = ISO8601DateFormatter().date(from: nowText) else {
            Issue.record("UNMEASURED: the MANIFEST does not pin today and now")
            return
        }
        let inputNames = ["overture-scout-extract-results.json", "downbeat-export.json", "overture-history.json"]
        for size in ["x1", "x4"] {
            // Every run copies the archive afresh; the archive itself is never opened (L487).
            let work = try sandboxes.make(named: "engine-nets-\(size)")
            let storeNames = manifest.sha256.keys.filter { $0.hasPrefix(size + "/") }.sorted()
            guard let storeName = storeNames.first(where: { $0.hasSuffix(".store") }) else {
                Issue.record(Comment(rawValue: "UNMEASURED: the MANIFEST names no \(size) store"))
                return
            }
            for name in storeNames + inputNames {
                let to = work.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: to.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: archive.appendingPathComponent(name), to: to)
                try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: to.path)
            }
            let frozen = try ScoutExtractResultsDecoder.decode(
                Data(contentsOf: work.appendingPathComponent("overture-scout-extract-results.json")))
            guard let factor = Int(size.dropFirst()) else {
                Issue.record(Comment(rawValue: "UNMEASURED: \(size) names no corpus factor"))
                return
            }
            let results = ScaledCorpus.results(frozen, factor: factor)
            let container = try Phase0.openContainer(at: work.appendingPathComponent(storeName))
            let context = container.mainContext
            context.autosaveEnabled = false
            let exportURL = work.appendingPathComponent("downbeat-export.json")
            let loaded = DownbeatBridge.loadWithHealth(from: exportURL, now: now)
            let existing = Prospect.inKeyOrder(try context.fetch(FetchDescriptor<Prospect>()))
            let history = LocalHistory.forMatching(existing: existing,
                                                   importedFrom: work.appendingPathComponent("overture-history.json"))
            let blocked = ScoutService.blockedCalendar(export: (loaded.bookings, loaded.blockedDates, loaded.health),
                                                       context: context)
            let run = EngineNetRun(context: context)
            try await run.step("start") {
                run.engine.start()
                return true
            }
            try await run.step("scout landing (ingest)") {
                _ = await ScoutExtractIngest.ingest(results, clients: loaded.clients, history: history,
                                                    blocked: blocked, today: today, now: now, into: context)
                try context.save()
                return true
            }
            let leadEvents = frozen.results.first { !$0.events.isEmpty }?.events ?? []
            try await run.step("add a lead") {
                try await RealUseSteps.pasteLead(context, url: "https://lead-probe.example.org/season", events: leadEvents,
                                                 today: today, now: now)
            }
            try await RealUseSteps.actions(on: run, export: (loaded.bookings, loaded.blockedDates, loaded.health),
                                           exportURL: exportURL, now: now)
            let verdict = await run.verify()
            let fired = run.readings.dropFirst().filter { $0.netsFired > 0 || $0.fullReads > 0 }
            print("""
                engine-nets [\(size)] \(Phase0.load())
                  shape \(Phase0.shape(existing))
                \(run.readings.map { "  " + $0.description }.joined(separator: "\n"))
                  steps after the start that tripped a net or read the whole store: \(fired.count)
                  verifier after every step: \(verdict)
                """)
            #expect(fired.isEmpty, "a step of real use tripped a full-read net: \(fired)")
            // A step with nothing to act on fires no net either, so a quiet reading counts only when it ran (L159).
            let idle = run.readings.filter { !$0.exercised }.map(\.step)
            #expect(idle.isEmpty, "steps that found nothing to act on, so measured nothing: \(idle)")
            // A MATCH, never merely an outcome: superseded, cancelled and unmeasured say nothing about the facts.
            #expect(verdict.received && verdict.matches == 1 && verdict.factMismatches == 0
                        && verdict.outputMismatches == 0,
                    "the engine's facts did not verify against a fresh read: \(verdict)")
        }
    }
}
