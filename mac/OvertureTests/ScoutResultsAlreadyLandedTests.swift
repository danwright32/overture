import Testing
import Foundation
import SwiftData

// #4336 (A7): calendar results that have already landed are refused as their own outcome, "already landed",
// carrying the first landing's time, and never reported as a landing that found nothing.
//
// The key is the results file's content hash (the run identity A6 builds on), recorded on a `LandingRun`
// row carried by the landing's closing save. The reattach path reaches the same file at `defaultURL` again
// in ordinary use, and a kept copy can be offered after its own landing saved, so both are covered here.
// A deadline the test never lets pass, so a waiting landing waits for the holder rather than the clock (L524).
@MainActor
private final class Deadlines {
    private var pending: [CheckedContinuation<Void, Never>] = []
    func sleep(_ d: Duration) async { await withCheckedContinuation { pending.append($0) } }
    func passAll() {
        let all = pending
        pending = []
        all.forEach { $0.resume() }
    }
}

@MainActor
@Suite("Calendar results that already landed are refused as already landed (#4336)")
final class ScoutResultsAlreadyLandedTests {
    private let sandboxes = TemporarySandboxes()
    private let firstLanding = Date(timeIntervalSince1970: 1_790_000_000)
    private let secondLanding = Date(timeIntervalSince1970: 1_790_090_000)

    private func container() throws -> ModelContainer { try TestModelContainer.inMemory(AppSchema.models) }

    private static func night(_ n: Int) -> String {
        EasternDate.dayString(from: Calendar(identifier: .gregorian).date(byAdding: .day, value: 20 + n, to: Date())!)
    }

    private static func results(_ label: String) -> ScoutExtractResults {
        ScoutExtractResults(version: 1, generatedAt: "2026-07-12T00:00:00Z",
                            results: [ScoutExtractResult(
                                sourceId: "org", verdict: .upcomingListings,
                                events: (0..<2).map { k in
                                    ScoutExtractEvent(title: "Recital \(label) \(k)", presenter: "Recital \(label) \(k)",
                                                      venue: "Merkin Hall", performanceDate: night(k),
                                                      sourceUrl: "https://\(label).example/r\(k)")
                                },
                                note: nil)])
    }

    @discardableResult
    private func htmlSource(in ctx: ModelContext) -> WatchedSource {
        let s = WatchedSource(sourceId: "org", orgName: "Org org", listingsURL: "https://org.example/events", kind: .html)
        s.venueLocation = "New York, NY"
        s.lastContentHash = "old"
        ctx.insert(s)
        return s
    }

    private func land(_ data: Data, at now: Date, into ctx: ModelContext,
                      flight: LandingSingleFlight = LandingSingleFlight(sleep: { _ in }),
                      pending: PendingScoutIngests,
                      check: AlreadyLandedCheck = .lookUp,
                      saveClosing: @escaping (ModelContext) throws -> Void = { try $0.save() })
        async throws -> ScoutExtractLanding.Landed {
        await ScoutExtractLanding.land(data, try ScoutExtractResultsDecoder.decode(data), clients: [], history: [],
                                       blocked: .empty, today: ScoutTestClock.beforeAllFixtures, now: now,
                                       landings: flight, pending: pending, alreadyLanded: check,
                                       saveClosing: saveClosing, into: ctx)
    }

    private func titles(_ c: ModelContainer) throws -> [String] {
        try ModelContext(c).fetch(FetchDescriptor<Prospect>()).map(\.groupName)
    }

    private func source(_ c: ModelContainer) throws -> WatchedSource {
        try #require(try ModelContext(c).fetch(FetchDescriptor<WatchedSource>()).first)
    }

    // The step's own test. The second landing of the same bytes says "already landed" with the FIRST
    // landing's time, applies nothing (the source the run would have written first is untouched), and is
    // never an ordinary landing. Seen to fail by removing the check, when the second landing lands again.
    @Test func theSecondLandingOfTheSameResultsIsRefusedWithTheFirstLandingsTime() async throws {
        let c = try container()
        let ctx = c.mainContext
        htmlSource(in: ctx)
        try ctx.save()
        let pending = PendingScoutIngests(directory: try sandboxes.make(named: "already-landed-pending"))
        let data = try JSONEncoder().encode(Self.results("twice"))

        let first = try await land(data, at: firstLanding, into: ctx, pending: pending)
        #expect(first.outcome.alreadyLandedAt == nil)
        #expect(first.outcome.inserted == 2)
        #expect(try source(c).successfulCheckCount == 1)

        // A later write to the source the second landing would overwrite first, so "applied nothing" is
        // measured on the row rather than inferred from the counts.
        let editing = ModelContext(c)
        let row = try #require(try editing.fetch(FetchDescriptor<WatchedSource>()).first)
        row.notes = "set after the first landing"
        try editing.save()

        let second = try await land(data, at: secondLanding, into: ctx, pending: pending)
        #expect(second.outcome.alreadyLandedAt == firstLanding, Comment(rawValue:
            "the second landing said: \(String(describing: second.outcome.alreadyLandedAt))"))
        #expect(second.outcome.found == 0)
        #expect(second.outcome.sources.isEmpty, "an already landed file was reported source by source")
        #expect(second.outcome.notLandedYet == nil)
        #expect(!second.outcome.saveFailed)
        #expect(try source(c).successfulCheckCount == 1, "the second landing counted another check")
        #expect(try source(c).notes == "set after the first landing", "the second landing wrote to the source")
        #expect(try titles(c).filter { $0.contains("twice") }.count == 2)
        #expect(try ModelContext(c).fetch(FetchDescriptor<LandingRun>()).count == 1)
    }

    // L157: the check made before the read phase is a judgement formed before the store is held. Two
    // landings of the same bytes that both pass it while waiting must still land once: the second is
    // refused inside its turn, and the source counts one check, not two.
    @Test func twoLandingsOfTheSameBytesWaitingTogetherLandOnce() async throws {
        let c = try container()
        let ctx = c.mainContext
        htmlSource(in: ctx)
        try ctx.save()
        let pending = PendingScoutIngests(directory: try sandboxes.make(named: "already-landed-overlap"))
        let data = try JSONEncoder().encode(Self.results("overlap"))
        let results = try ScoutExtractResultsDecoder.decode(data)
        let deadlines = Deadlines()
        let flight = LandingSingleFlight(sleep: { await deadlines.sleep($0) })
        let holder = try await flight.begin(entryPoint: .runScoutLanding, priority: .scout, deadline: .seconds(1))
        let now = firstLanding
        func landing() -> Task<ScoutExtractLanding.Landed, Never> {
            Task { @MainActor in
                await ScoutExtractLanding.land(data, results, clients: [], history: [], blocked: .empty,
                                               today: ScoutTestClock.beforeAllFixtures, now: now,
                                               landings: flight, pending: pending, into: ctx)
            }
        }
        let a = landing()
        await waitUntil("the first landing is waiting") { flight.queue.count == 1 }
        let b = landing()
        await waitUntil("the second landing is waiting") { flight.queue.count == 2 }
        holder.end()
        let outcomes = [await a.value.outcome, await b.value.outcome]

        #expect(outcomes.filter { $0.alreadyLandedAt == nil && $0.inserted == 2 }.count == 1)
        #expect(outcomes.filter { $0.alreadyLandedAt == now }.count == 1, Comment(rawValue:
            "the two landings said: \(outcomes.map { String(describing: $0.alreadyLandedAt) })"))
        #expect(try source(c).successfulCheckCount == 1, "the same results landed twice")
        #expect(try pending.list().isEmpty, "a copy kept while waiting outlived its results landing")
        deadlines.passAll()
    }

    // L5: only a landing whose closing save SUCCEEDED is recorded. A failed save never reached disk, so the
    // same results must land when offered again, even after an unrelated save on the same context, which
    // would persist a record left pending there.
    @Test func aLandingWhoseClosingSaveFailedIsNotRecordedAsLanded() async throws {
        struct SaveRefused: Error {}
        let c = try container()
        let ctx = c.mainContext
        htmlSource(in: ctx)
        try ctx.save()
        let pending = PendingScoutIngests(directory: try sandboxes.make(named: "already-landed-save-failed"))
        let data = try JSONEncoder().encode(Self.results("unsaved"))

        let failed = try await land(data, at: firstLanding, into: ctx, pending: pending,
                                    saveClosing: { _ in throw SaveRefused() })
        #expect(failed.outcome.saveFailed)
        ctx.insert(WatchedSource(sourceId: "other", orgName: "Other", listingsURL: "https://other.example/",
                                 kind: .html))
        try ctx.save()
        // #4335 (A6): the landing's record of itself now reaches the store with its first save, UNLANDED, so
        // what this asserts is that no record says these results landed.
        #expect(try ModelContext(c).fetch(FetchDescriptor<LandingRun>()).allSatisfy { $0.landedAt == nil },
                "a landing whose save failed was recorded as landed")

        let again = try await land(data, at: secondLanding, into: ctx, pending: pending)
        #expect(again.outcome.alreadyLandedAt == nil)
        #expect(!again.outcome.saveFailed)
    }

    // A record that has not landed (A6 inserts one when a landing starts) refuses nothing.
    @Test func aRecordThatHasNotLandedRefusesNothing() async throws {
        let c = try container()
        let ctx = c.mainContext
        htmlSource(in: ctx)
        let data = try JSONEncoder().encode(Self.results("started"))
        ctx.insert(LandingRun(runIdentity: PendingScoutIngests.contentHash(of: data), landedAt: nil))
        try ctx.save()
        let pending = PendingScoutIngests(directory: try sandboxes.make(named: "already-landed-unfinished"))

        let landed = try await land(data, at: firstLanding, into: ctx, pending: pending)
        #expect(landed.outcome.alreadyLandedAt == nil)
        #expect(landed.outcome.inserted == 2)
    }

    // L215: a record that cannot be read is not "never landed" and not "already landed". The results land,
    // since refusing them would lose a run to a read nothing else needed, and the degraded read is said.
    @Test func anUnreadableRecordLandsAndSaysTheReadFailed() async throws {
        struct Unreadable: Error {}
        let c = try container()
        let ctx = c.mainContext
        htmlSource(in: ctx)
        try ctx.save()
        let pending = PendingScoutIngests(directory: try sandboxes.make(named: "already-landed-unreadable"))
        let data = try JSONEncoder().encode(Self.results("unread"))

        let landed = try await land(data, at: firstLanding, into: ctx, pending: pending,
                                    check: AlreadyLandedCheck { _, _ in throw Unreadable() })
        #expect(landed.outcome.alreadyLandedAt == nil)
        #expect(landed.outcome.inserted == 2)
        #expect(landed.outcome.degradedReads.contains(.landedRuns), Comment(rawValue:
            "degraded reads: \(landed.outcome.degradedReads)"))
    }

    // The measurement seam: a probe that re-lands one frozen file passes the bypass and lands every round.
    // The positive control beside it is the first test here, which uses the real check.
    @Test func theMeasurementBypassLandsTheSameResultsAgain() async throws {
        let c = try container()
        let ctx = c.mainContext
        htmlSource(in: ctx)
        try ctx.save()
        let pending = PendingScoutIngests(directory: try sandboxes.make(named: "already-landed-bypass"))
        let data = try JSONEncoder().encode(Self.results("rounds"))
        _ = try await land(data, at: firstLanding, into: ctx, pending: pending, check: .bypassedForMeasurement)
        let again = try await land(data, at: secondLanding, into: ctx, pending: pending, check: .bypassedForMeasurement)
        #expect(again.outcome.alreadyLandedAt == nil)
        #expect(try source(c).successfulCheckCount == 2)
    }

    // A kept copy whose results already landed (its removal failed, or the app quit between the save and
    // the removal) is not counted as landing now: it is removed, and the sweep says it had already landed.
    @Test func aKeptCopyOfResultsThatAlreadyLandedIsRemovedAndSaidSo() async throws {
        let c = try container()
        let ctx = c.mainContext
        htmlSource(in: ctx)
        try ctx.save()
        let pending = PendingScoutIngests(directory: try sandboxes.make(named: "already-landed-copy"))
        let data = try JSONEncoder().encode(Self.results("kept"))
        _ = try await land(data, at: firstLanding, into: ctx, pending: pending)
        try pending.record(data, sequence: 1, now: firstLanding)

        let offered = await ScoutExtractLanding.offerPending(clients: [], history: [], blocked: .empty,
                                                            now: secondLanding,
                                                            landings: LandingSingleFlight(sleep: { _ in }),
                                                            pending: pending, into: ctx)
        #expect(offered.landed.isEmpty, "a copy of results that had already landed was counted as landing now")
        #expect(offered.alreadyLanded == [firstLanding])
        #expect(!offered.isEmpty)
        #expect(try pending.list().isEmpty, "the copy of results that had already landed was kept")
        #expect(try source(c).successfulCheckCount == 1)
        let lines = LandingOutcome.from(offered: offered, degradedLabels: [])
        #expect(lines == [.keptResultsAlreadyLanded(at: firstLanding)], Comment(rawValue: "\(lines)"))
        #expect(lines.first?.line == LandingWaitCopy.keptCopyAlreadyLanded(at: firstLanding))
    }

    // #4343 (E0): the two other ways a kept copy lands, the sweep and the idle recovery, take the same check as a
    // parameter whose default is the real lookup, so the acceptance rig can re-land one frozen file through each
    // every round. Each is asserted both ways in one test: the default still refuses (the positive control the
    // seam must never hide, L159), and only the bypass lands the same results again.
    @Test func theSweepRefusesByDefaultAndLandsAgainOnlyWithTheBypass() async throws {
        let c = try container()
        let ctx = c.mainContext
        htmlSource(in: ctx)
        try ctx.save()
        let pending = PendingScoutIngests(directory: try sandboxes.make(named: "already-landed-sweep-bypass"))
        let data = try JSONEncoder().encode(Self.results("swept"))
        _ = try await land(data, at: firstLanding, into: ctx, pending: pending)
        let flight = LandingSingleFlight(sleep: { _ in })

        try pending.record(data, sequence: 50, now: firstLanding)
        let refused = await ScoutExtractLanding.offerPending(clients: [], history: [], blocked: .empty,
                                                            now: secondLanding, landings: flight,
                                                            pending: pending, into: ctx)
        #expect(refused.alreadyLanded == [firstLanding], "the sweep's default no longer refuses a re-land")

        try pending.record(data, sequence: 60, now: firstLanding)
        let landed = await ScoutExtractLanding.offerPending(clients: [], history: [], blocked: .empty,
                                                           now: secondLanding, landings: flight,
                                                           pending: pending, alreadyLanded: .bypassedForMeasurement,
                                                           into: ctx)
        #expect(landed.alreadyLanded.isEmpty)
        #expect(landed.landed.count == 1, "the bypass did not land the kept copy again")
        #expect(try source(c).successfulCheckCount == 2)
    }

    @Test func theRecoveryRefusesByDefaultAndLandsAgainOnlyWithTheBypass() async throws {
        let c = try container()
        let ctx = c.mainContext
        htmlSource(in: ctx)
        try ctx.save()
        let root = try sandboxes.make(named: "already-landed-recovery-bypass")
        let pending = PendingScoutIngests(directory: root.appendingPathComponent("pending"),
                                          readFailures: HandoffReadFailures())
        let journals = LandingJournals(directory: root.appendingPathComponent("journals"),
                                       readFailures: HandoffReadFailures())
        let data = try JSONEncoder().encode(Self.results("recovered"))
        let hash = PendingScoutIngests.contentHash(of: data)
        _ = try await land(data, at: firstLanding, into: ctx, pending: pending)
        let flight = LandingSingleFlight(sleep: { _ in })

        // An interrupted landing of the same results, under a sequence above everything the first one stamped.
        func interrupt(at sequence: Int) throws {
            try pending.record(data, sequence: sequence, now: firstLanding)
            try journals.start(LandingJournal(runIdentity: hash, sequence: sequence, entryPoint: .scoutExtractIngest,
                                              sources: [.init(sourceId: "org", pageHash: nil)], now: firstLanding,
                                              resultsCopy: hash))
        }
        func recover(_ check: AlreadyLandedCheck?) async -> LandingRecovery.Recovered? {
            if let check {
                return await LandingRecovery.recoverNext(journals: journals, pending: pending, clients: [],
                                                         history: [], blocked: .empty, landings: flight,
                                                         now: secondLanding, sweep: { false },
                                                         alreadyLanded: check, into: ctx)
            }
            return await LandingRecovery.recoverNext(journals: journals, pending: pending, clients: [], history: [],
                                                     blocked: .empty, landings: flight, now: secondLanding,
                                                     sweep: { false }, into: ctx)
        }
        let floor = try source(c).lastTouchedSequence
        try interrupt(at: floor + 10)
        #expect(await recover(nil) == .retired(startedAt: firstLanding, finding: .finished),
                "the recovery's default no longer refuses a re-land")
        try interrupt(at: floor + 20)
        #expect(await recover(.bypassedForMeasurement) == .landed(startedAt: firstLanding, sources: 1),
                "the bypass did not land the interrupted copy again")
        #expect(try source(c).successfulCheckCount == 2)
    }

    // MARK: - What Dan reads

    // 2026-09-30 18:14 UTC is 2:14 PM in New York.
    private let landedAt = Date(timeIntervalSince1970: 1_790_792_040)

    @Test func theRefusalSaysWhenTheResultsLandedInEasternTime() {
        #expect(LandingWaitCopy.alreadyLanded(at: landedAt)
                == "These results already landed at 2:14 PM on Sep 30. Nothing new to add.")
        #expect(LandingWaitCopy.keptCopyAlreadyLanded(at: landedAt)
                == "Kept calendar results had already landed at 2:14 PM on Sep 30, so Overture removed the copy. Nothing new to add.")
    }

    // The toolbar line an ingest leaves says "already landed", never the ordinary "Nothing new" a landing
    // that found nothing says (L11).
    @Test func theIngestsSummaryLineSaysAlreadyLanded() {
        var outcome = ScoutService.Outcome(found: 0, inserted: 0, updated: 0, skipped: 0)
        #expect(ScoutRunSummary.watchedCalendarSummary(for: outcome) == "Nothing new on the watched calendars")
        outcome.alreadyLandedAt = landedAt
        #expect(ScoutRunSummary.watchedCalendarSummary(for: outcome) == LandingWaitCopy.alreadyLanded(at: landedAt))
    }

    // Informational, not a warning (L36): it shows in the summary Dan opened, last, and an unattended run
    // says nothing about it, because the reattach path reaches it in ordinary use.
    @Test func theRefusalIsAnInformationalSectionAndAnUnattendedRunSaysNothing() {
        var extract = ScoutService.Outcome(found: 0, inserted: 0, updated: 0, skipped: 0)
        extract.alreadyLandedAt = landedAt
        let empty = ScoutService.Outcome(found: 0, inserted: 0, updated: 0, skipped: 0)
        let warnings = ScoutWarnings.from(native: empty, extract: extract, finishedEmpty: nil)
        #expect(warnings.sections == [.alreadyLanded(landedAt)])
        #expect(warnings.quietLine == nil)
        #expect(ScoutWarningsPresentation.decide(warnings, auto: true) == .nothing)
        #expect(ScoutWarningsPresentation.decide(warnings, auto: false) == .popup(warnings))

        var native = empty
        native.saveFailed = true
        let both = ScoutWarnings.from(native: native, extract: extract, finishedEmpty: nil)
        #expect(both.sections.last == .alreadyLanded(landedAt))
        #expect(both.quietLine == "The scout couldn't save its results. Run it again.")
    }
}
