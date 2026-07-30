import Testing
import Foundation
import SwiftData
@testable import Overture

// #1809, with #1677 and the remaining half of #1676. One defect class: a reachability check that did not
// finish leaves Dan paying twice, silently.
//
// Three ingredients, each confirmed in code before this suite was written:
//
//   1. A check is only ever settled while a run is LIVE. `settleReachabilityProbe`'s only callers sit
//      inside `watchPrepRun`, which runs only while `isRunning` is true. The runner is detached and
//      removes its own run marker on exit, so a check that finishes while Overture is closed is never
//      settled, now or ever.
//   2. Nothing clears the leftover marker. `startPrep` does not.
//   3. So the NEXT Prep run finds the stale marker, is read as a check, and ingests with `isProbe: true`,
//      which short-circuits before any draft handling. Every draft that run wrote is discarded.
//
// #1765 is what made this likely rather than theoretical: a check went from a 40-lookup ceiling (about 11
// minutes) to unbounded (Dan's own was 21), so the window in which he quits mid-check got much wider.
@MainActor
@Suite("A check that did not finish (#1809)")
struct UnfinishedCheckTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, OrgReachabilityAnswer.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func newProspect(_ ctx: ModelContext, group: String) -> String {
        let key = Prospect.makeNaturalKey(groupName: group, performanceDate: "2026-09-12", venue: "Weill Recital Hall")
        let p = Prospect(naturalKey: key, groupName: group, discipline: "music", venue: "Weill Recital Hall",
                         performanceDate: "2026-09-12", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .new)
        ctx.insert(p)
        try? ctx.save()
        return key
    }

    private func dir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func writeResults(_ url: URL, _ results: PrepResults) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(results).write(to: url)
    }

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "unfinished-\(UUID().uuidString)")!
    }

    // INGREDIENT 1. A check finished while Overture was closed. Its marker and its results are both on
    // disk, and no run is in flight. The paid answers must still land.
    @Test func aCheckThatFinishedWhileOvertureWasClosedStillSettles() throws {
        let ctx = ModelContext(try container())
        let a = newProspect(ctx, group: "Aurora Strings")
        let d = dir()
        let markerURL = d.appendingPathComponent("probe-run.json")
        let resultsURL = d.appendingPathComponent("results.json")
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        try ReachabilityProbeMarker.write(ReachabilityProbeMarker(keys: [a], startedAt: "s"), to: markerURL)
        try writeResults(resultsURL, PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: a, contacts: [PrepContact(name: "Jane", role: "Mgr",
                                                             email: "jane@aurora.org",
                                                             method: "named_decision_maker",
                                                             confidence: "high", formUrl: nil,
                                                             provenance: "act")], draft: nil),
        ]))

        let report = PrepQueueService.settleOrphanedProbe(
            markerURL: markerURL, resultsURL: resultsURL,
            queueURL: d.appendingPathComponent("no-queue.json"),
            downbeatURL: d.appendingPathComponent("no-downbeat.json"),
            historyURL: d.appendingPathComponent("no-history.json"),
            into: ctx, now: now, defaults: freshDefaults())

        #expect(report != nil, "a leftover check must settle when nothing is running")
        let pa = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == a })).first
        #expect(pa?.reachabilityProbedAt == now)
        #expect(pa?.recipients.first?.email == "jane@aurora.org")
        #expect(try ReachabilityProbeMarker.read(from: markerURL) == nil, "and the marker is consumed")
    }

    // THE EXPENSIVE ONE. A stale check marker is on disk and Dan starts a normal Prep run. That run must
    // be ingested as a PREP run and keep its drafts. Read as a check, every draft is silently discarded
    // and he pays for a run that produced nothing he can see.
    @Test func aStaleCheckMarkerDoesNotMakeAPrepRunLoseItsDrafts() throws {
        let ctx = ModelContext(try container())
        let a = newProspect(ctx, group: "Aurora Strings")
        let d = dir()
        let markerURL = d.appendingPathComponent("probe-run.json")
        // The orphan, from a check that was never settled.
        try ReachabilityProbeMarker.write(ReachabilityProbeMarker(keys: [a], startedAt: "old"), to: markerURL)

        // Starting a Prep run must leave no check marker behind for the completion path to find.
        PrepQueueService.settleAnyCheckBefore(prepRunIn: ctx, now: Date(), probeRunURL: markerURL)

        #expect(try ReachabilityProbeMarker.read(from: markerURL) == nil,
                "a Prep run must not be mistakable for a check")
    }

    // The hole the first version of this fix had. A per-row Re-prep goes STRAIGHT to
    // PrepQueueService.startPrep with no RootView call at all, so a guard living in the view covered only
    // two of the three ways a Prep run begins and this path kept the whole bug. Asserted on the service,
    // which is the one place every Prep run passes through.
    @Test func everyWayAPrepRunStartsIsProtected() throws {
        let ctx = ModelContext(try container())
        let a = newProspect(ctx, group: "Aurora Strings")
        let d = dir()
        let markerURL = d.appendingPathComponent("probe-run.json")
        try ReachabilityProbeMarker.write(ReachabilityProbeMarker(keys: [a], startedAt: "old"), to: markerURL)

        // Even when the settle cannot land anything (no results file at all), the marker must not survive
        // to relabel the Prep run that is about to start.
        PrepQueueService.settleAnyCheckBefore(prepRunIn: ctx, now: Date(), probeRunURL: markerURL)

        #expect(try ReachabilityProbeMarker.read(from: markerURL) == nil)
    }

    // And the honest half of that: clearing the orphan must not THROW AWAY the check's paid answers. They
    // are settled first, so starting a Prep run lands them rather than discarding them.
    @Test func claimingTheRunAsPrepSettlesTheOrphanRatherThanDiscardingIt() throws {
        let ctx = ModelContext(try container())
        let a = newProspect(ctx, group: "Aurora Strings")
        let d = dir()
        let markerURL = d.appendingPathComponent("probe-run.json")
        let resultsURL = d.appendingPathComponent("results.json")
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        try ReachabilityProbeMarker.write(ReachabilityProbeMarker(keys: [a], startedAt: "old"), to: markerURL)
        try writeResults(resultsURL, PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: a, contacts: [], draft: nil),
        ]))

        _ = PrepQueueService.settleOrphanedProbe(
            markerURL: markerURL, resultsURL: resultsURL,
            queueURL: d.appendingPathComponent("no-queue.json"),
            downbeatURL: d.appendingPathComponent("no-downbeat.json"),
            historyURL: d.appendingPathComponent("no-history.json"),
            into: ctx, now: now, defaults: freshDefaults())

        let pa = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == a })).first
        #expect(pa?.reachabilityProbedAt == now, "the answer Dan paid for is kept, not dropped")
    }

    // No marker at all is the normal case and must stay cheap and silent: nothing to settle, no report.
    @Test func noLeftoverCheckMeansNothingToSettle() throws {
        let ctx = ModelContext(try container())
        let d = dir()
        #expect(PrepQueueService.settleOrphanedProbe(
            markerURL: d.appendingPathComponent("absent.json"),
            resultsURL: d.appendingPathComponent("results.json"),
            queueURL: d.appendingPathComponent("no-queue.json"),
            downbeatURL: d.appendingPathComponent("no-downbeat.json"),
            historyURL: d.appendingPathComponent("no-history.json"),
            into: ctx, now: Date(), defaults: freshDefaults()) == nil)
    }
}

// #1677 and the remaining half of #1676: a paid answer whose SAVE failed.
//
// Both used to be invisible. `markProbed` committed with `try? context.save()`, discarding the error
// outright, and `OrgAnswerRecording.record` reported a failed ledger save to an NSLog nothing surfaces
// while returning 0, the same value it returns when there was simply nothing to record. Two opposite
// meanings sharing one signal is L53, and it is why even a caller that wanted to check could not.
@MainActor
@Suite("A paid answer that failed to save (#1677, #1676)")
struct FailedAnswerSaveTests {

    private let schema = Schema([Prospect.self, OrgReachabilityAnswer.self])

    private func seedProspect(_ ctx: ModelContext, group: String, presenter: String?) -> String {
        let key = Prospect.makeNaturalKey(groupName: group, performanceDate: "2026-09-12", venue: "Weill Recital Hall")
        let p = Prospect(naturalKey: key, groupName: group, discipline: "music", venue: "Weill Recital Hall",
                         performanceDate: "2026-09-12", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .new)
        p.presenter = presenter
        ctx.insert(p)
        return key
    }

    // "Nothing to record" and "the save failed" must not be the same answer. This is the test that would
    // have caught the ambiguity: both used to be 0.
    @Test func nothingToRecordIsNotTheSameAsAFailedSave() {
        let ctx = ModelContext(try! ModelContainer(
            for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
        let outcome = OrgAnswerRecording.record(answeredKeys: [], in: ctx, now: Date())
        #expect(outcome.written == 0)
        #expect(!outcome.saveFailed, "an empty request is not a failure")
    }

    // FAILURE PATH. The ledger save genuinely throws, against a real immutable store. Money has been spent
    // and the record of it did not land, which is precisely the case that must not be only a log line.
    @Test func aLedgerSaveThatFailsSaysSoRatherThanLoggingIt() async throws {
        var key = ""
        let outcome = try await ImmutableStoreFixture.withFailingSave(
            schema: schema,
            seed: { ctx in key = self.seedProspect(ctx, group: "Aurora Strings", presenter: "FRIGID New York") },
            body: { ctx in
                OrgAnswerRecording.record(answeredKeys: [key], in: ctx, now: Date())
            })
        #expect(outcome.saveFailed, "a failed ledger save must be reportable, not swallowed")
    }

    // #1677. The stamp's save is discarded with `try?`, so a failed stamp looks exactly like a good one and
    // the marker clears as though the answers had landed. The next thing Dan sees is a Check button
    // offering to pay again for lookups that already happened.
    @Test func aStampThatCannotBeSavedIsReportedAndDoesNotClearTheMarker() async throws {
        var key = ""
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let markerURL = d.appendingPathComponent("probe-run.json")
        let resultsURL = d.appendingPathComponent("results.json")

        let report = try await ImmutableStoreFixture.withFailingSave(
            schema: schema,
            seed: { ctx in key = self.seedProspect(ctx, group: "Aurora Strings", presenter: nil) },
            body: { ctx -> ReachabilityRunReport? in
                try ReachabilityProbeMarker.write(
                    ReachabilityProbeMarker(keys: [key], startedAt: "s"), to: markerURL)
                try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
                try JSONEncoder().encode(PrepResults(version: 2, generatedAt: "now", results: [
                    PrepResult(naturalKey: key, contacts: [], draft: nil),
                ])).write(to: resultsURL)
                return PrepQueueService.settleReachabilityProbe(
                    markerURL: markerURL, resultsURL: resultsURL,
                    queueURL: d.appendingPathComponent("no-queue.json"),
                    downbeatURL: d.appendingPathComponent("no-downbeat.json"),
                    historyURL: d.appendingPathComponent("no-history.json"),
                    into: ctx, now: Date(),
                    defaults: UserDefaults(suiteName: "failed-stamp-\(UUID().uuidString)")!)
            })

        let settled = try #require(report)
        #expect(settled.stampSaveFailed, "a failed stamp must be carried out, not discarded")
        // Dan's call (2026-07-30): the run is not finished if the record of it did not save, so it stays
        // available to settle again rather than closing out as though the stamps had landed.
        #expect(try ReachabilityProbeMarker.read(from: markerURL) != nil,
                "an unsaved settle must not clear the marker")
        #expect(try #require(settled.attentionMessage).contains("couldn't save"))
        try? FileManager.default.removeItem(at: d)
    }

    // Dan's second call (2026-07-30): retry, but do not retry forever. A store that will never accept a
    // write would otherwise re-announce on every launch indefinitely. On the last allowed attempt the run
    // is released and the sentence changes to say it has stopped, because "isn't finished" would then be
    // false: nothing further happens on its own.
    @Test func theRetryGivesUpAfterTheLastAttemptAndSaysSo() async throws {
        var key = ""
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let markerURL = d.appendingPathComponent("probe-run.json")
        let resultsURL = d.appendingPathComponent("results.json")

        let report = try await ImmutableStoreFixture.withFailingSave(
            schema: schema,
            seed: { ctx in key = self.seedProspect(ctx, group: "Aurora Strings", presenter: nil) },
            body: { ctx -> ReachabilityRunReport? in
                // One attempt short of the cap, as a run that has already failed twice would be.
                try ReachabilityProbeMarker.write(
                    ReachabilityProbeMarker(keys: [key], startedAt: "s",
                                            settleAttempts: ReachabilityProbeMarker.maxSettleAttempts - 1),
                    to: markerURL)
                try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
                try JSONEncoder().encode(PrepResults(version: 2, generatedAt: "now", results: [
                    PrepResult(naturalKey: key, contacts: [], draft: nil),
                ])).write(to: resultsURL)
                return PrepQueueService.settleReachabilityProbe(
                    markerURL: markerURL, resultsURL: resultsURL,
                    queueURL: d.appendingPathComponent("no-queue.json"),
                    downbeatURL: d.appendingPathComponent("no-downbeat.json"),
                    historyURL: d.appendingPathComponent("no-history.json"),
                    into: ctx, now: Date(),
                    defaults: UserDefaults(suiteName: "gave-up-\(UUID().uuidString)")!)
            })

        let settled = try #require(report)
        #expect(settled.stampSaveGaveUp)
        #expect(try ReachabilityProbeMarker.read(from: markerURL) == nil,
                "the last attempt releases the run rather than nagging forever")
        let message = try #require(settled.attentionMessage)
        #expect(message.contains("stopped trying"))
        #expect(!message.contains("isn't finished"), "that promise is false once it has given up")
        try? FileManager.default.removeItem(at: d)
    }

    // A marker written before `settleAttempts` existed must still decode, or the very first failed settle
    // of a paid run would throw away the run this field was added to protect.
    @Test func aMarkerFromBeforeTheRetryCountStillReads() throws {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let url = d.appendingPathComponent("probe-run.json")
        try #"{"keys":["a|2026-09-12|weill"],"startedAt":"s"}"#.data(using: .utf8)!.write(to: url)

        let marker = try #require(try ReachabilityProbeMarker.read(from: url))
        #expect(marker.keys.count == 1)
        #expect(marker.settleAttempts == nil, "absent reads as never attempted, not as a decode failure")
        try? FileManager.default.removeItem(at: d)
    }
}
