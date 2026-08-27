import Testing
import Foundation
import SwiftData

// #1769: what a finished reachability check TELLS Dan when it did not answer everything it was given.
//
// A check spends real time (77 shows is the better part of an hour) and runs as up to ten concurrent claudes, one
// per chunk of the work-list. A chunk that dies partway leaves the shows it never reached with no answer,
// and #1594 deliberately leaves those shows UNSTAMPED so the next check picks them up again rather than
// locking them out for 90 days. That self-healing was invisible: `settleReachabilityProbe` computed the
// shortfall and threw it away (the whole ingest Outcome was discarded, and markProbed's own count went to
// an NSLog nothing surfaces), so a run that answered 69 of 77 read as a clean pass.
//
// Self-healing is not the same as visible (the #876 lesson, one surface further along).
@MainActor
@Suite("What a partial reachability check reports (#1769)")
struct ReachabilityRunReportTests {

    // A run that answered everything says nothing at all. An alert that fires on an ordinary run is one
    // Dan learns to scroll past, and this slot is "does something need me" (L36).
    @Test func aCompleteCheckSaysNothing() {
        #expect(ReachabilityRunSummary.attentionMessage(requested: 77, answered: 77, outcome: nil) == nil)
        #expect(ReachabilityRunSummary.attentionMessage(requested: 1, answered: 1, outcome: nil) == nil)
    }

    // THE POINT OF THE ISSUE. Eight shows went missing inside a 77-show check, and the run reported as a
    // clean pass.
    @Test func aCheckThatMissedShowsNamesHowManyAndSaysTheyAreStillUnchecked() throws {
        let message = try #require(
            ReachabilityRunSummary.attentionMessage(requested: 77, answered: 69, outcome: nil))
        #expect(message.contains("8 of 77 shows"))
        #expect(message.contains("still unchecked"))
        #expect(message.hasPrefix("Reachability: "))
    }

    // The promise has to be one the app keeps. A Prep run's shortfall says "they'll be retried" because
    // PrepQueueBuilder genuinely re-queues an undrafted prospect. NOTHING re-checks reachability by
    // itself: Dan has to pick those dates again. Borrowing that sentence here would be a false promise
    // about money and time, which is exactly the class of defect L21 is about.
    @Test func theCheckNeverPromisesAnAutomaticRetry() throws {
        let message = try #require(
            ReachabilityRunSummary.attentionMessage(requested: 77, answered: 69, outcome: nil))
        #expect(!message.contains("retried"))
        #expect(!message.contains("retry"))
    }

    @Test func oneMissedShowReadsAsSingular() throws {
        let message = try #require(
            ReachabilityRunSummary.attentionMessage(requested: 5, answered: 4, outcome: nil))
        #expect(message.contains("1 of 5 shows never got an answer and is still unchecked"))
    }

    // A single-show check (a lone stale re-check, or a date with one candidate) must not read "1 of 1
    // show", which is the kind of line that makes the whole surface look unfinished.
    @Test func aOneShowCheckThatMissedItDoesNotCountToItself() throws {
        let message = try #require(
            ReachabilityRunSummary.attentionMessage(requested: 1, answered: 0, outcome: nil))
        #expect(message == "Reachability: the show you checked never got an answer and is still unchecked")
    }

    // FAILURE PATH. The shortfall is not the only thing the check path used to drop on the floor: the
    // whole ingest Outcome was discarded, so a failed save (Dan waited the better part of an hour and the answers may not
    // have persisted) and a runaway web-call count were invisible too. Fix the class, not the instance
    // (L30), and reuse Prep's existing wording rather than writing a second copy of it.
    @Test func aFailedSaveIsReportedAlongsideTheShortfall() throws {
        var outcome = PrepImporter.Outcome()
        outcome.saveFailed = true
        let message = try #require(
            ReachabilityRunSummary.attentionMessage(requested: 77, answered: 69, outcome: outcome))
        #expect(message.contains("8 of 77 shows"))
        #expect(message.contains("couldn't save"))
    }

    // And a run that answered every show can still have something wrong with it, so the shortfall is not
    // the gate on whether anything is said.
    @Test func aCompleteCheckStillReportsAConcernFromItsOutcome() throws {
        var outcome = PrepImporter.Outcome()
        outcome.saveFailed = true
        let message = try #require(
            ReachabilityRunSummary.attentionMessage(requested: 77, answered: 77, outcome: outcome))
        #expect(message.contains("couldn't save"))
        #expect(!message.contains("never got an answer"))
    }

    // A results file carrying MORE answers than were asked for is a different failure (it has its own
    // `unmatchedKeys` note) and must never read as a negative shortfall.
    @Test func moreAnswersThanAskedForIsNotAShortfall() {
        #expect(ReachabilityRunSummary.attentionMessage(requested: 3, answered: 5, outcome: nil) == nil)
    }
}

// The other half of the claim: the settle path has to HAND the counts out, or the sentence above is a
// guard nobody wired (L3). Before #1769 `settleReachabilityProbe` returned a bare Bool and the count
// existed only inside an NSLog.
@MainActor
@Suite("A settled check hands its shortfall out (#1769)")
struct ReachabilityProbeReportWiringTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func newProspect(_ ctx: ModelContext, group: String) -> String {
        let key = Prospect.makeNaturalKey(groupName: group, performanceDate: "2026-09-12", venue: "Weill Recital Hall")
        let p = Prospect(naturalKey: key, groupName: group, discipline: "music", venue: "Weill Recital Hall",
                         performanceDate: "2026-09-12", sourceListingURL: nil,
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
        UserDefaults(suiteName: "probe-report-\(UUID().uuidString)")!
    }

    // L2: every file the ingest reads points inside this test's own temp directory. Left at their defaults
    // these three reached Dan's LIVE prep queue and his real Downbeat export, so the Outcome under test
    // depended on what happened to be on the Mac running it: the first red run of this suite printed four
    // of his actual August shows inside `missingKeys`.
    private func settle(_ d: URL, marker: URL, results: URL, ctx: ModelContext, now: Date,
                        defaults: UserDefaults) -> ReachabilityRunReport? {
        PrepQueueService.settleReachabilityProbe(slot: .check, 
            markerURL: marker, resultsURL: results,
            queueURL: d.appendingPathComponent("no-queue.json"),
            downbeatURL: d.appendingPathComponent("no-downbeat.json"),
            historyURL: d.appendingPathComponent("no-history.json"),
            into: ctx, now: now, defaults: defaults)
    }

    // The #1594 scenario at the scale #1765 makes possible: a chunk stops partway, and the shows it never
    // reached come back with no record. The settle now says so instead of only leaving them unstamped.
    @Test func aCheckThatStoppedPartwayReportsTheShowsItNeverReached() throws {
        let ctx = ModelContext(try container())
        let keys = ["Aurora Strings", "Boreal Brass", "Cinder Quartet", "Delta Winds", "Ember Voices"]
            .map { newProspect(ctx, group: $0) }
        let d = dir()
        let markerURL = d.appendingPathComponent("probe-run.json")
        let resultsURL = d.appendingPathComponent("results.json")
        try ReachabilityProbeMarker.write(ReachabilityProbeMarker(keys: Set(keys), startedAt: "s"), to: markerURL)
        try writeResults(resultsURL, PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: keys[0], contacts: [], draft: nil),
            PrepResult(naturalKey: keys[1], contacts: [], draft: nil),
        ]))

        let report = try #require(settle(d, marker: markerURL, results: resultsURL, ctx: ctx,
                                        now: Date(timeIntervalSince1970: 1_780_000_000),
                                        defaults: freshDefaults()))

        #expect(report.requested == 5)
        #expect(report.answered == 2)
        #expect(report.unanswered == 3)
        let message = try #require(report.attentionMessage)
        #expect(message.contains("3 of 5 shows"))
    }

    // A check that answered everything hands back a report with nothing to say, so the caller writes no
    // status line at all rather than an empty "Reachability:".
    @Test func aCompleteCheckHandsBackAReportWithNothingToSay() throws {
        let ctx = ModelContext(try container())
        let a = newProspect(ctx, group: "Aurora Strings")
        let d = dir()
        let markerURL = d.appendingPathComponent("probe-run.json")
        let resultsURL = d.appendingPathComponent("results.json")
        try ReachabilityProbeMarker.write(ReachabilityProbeMarker(keys: [a], startedAt: "s"), to: markerURL)
        try writeResults(resultsURL, PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: a, contacts: [], draft: nil),
        ]))

        let report = try #require(settle(d, marker: markerURL, results: resultsURL, ctx: ctx,
                                        now: Date(timeIntervalSince1970: 1_780_000_000),
                                        defaults: freshDefaults()))

        #expect(report.unanswered == 0)
        // Scoped to the shortfall clause, not to a nil message. The injected paths above have no Downbeat
        // export behind them, so the run legitimately carries the #754 "a past client may have read as
        // cold" note, and asserting nil here would be asserting the absence of a warning that SHOULD fire.
        // The nil case is pinned in the summary suite above, where the Outcome is fully controlled.
        #expect(report.attentionMessage?.contains("never got an answer") != true)
    }

    // A run that died before writing anything is the worst case and the one most worth naming: every show
    // it was given is unanswered.
    @Test func aRunThatDiedBeforeWritingResultsReportsEveryShowUnanswered() throws {
        let ctx = ModelContext(try container())
        let keys = ["Aurora Strings", "Boreal Brass"].map { newProspect(ctx, group: $0) }
        let d = dir()
        let markerURL = d.appendingPathComponent("probe-run.json")
        try ReachabilityProbeMarker.write(ReachabilityProbeMarker(keys: Set(keys), startedAt: "s"), to: markerURL)

        let report = try #require(settle(d, marker: markerURL,
                                        results: d.appendingPathComponent("results.json"), ctx: ctx,
                                        now: Date(timeIntervalSince1970: 1_780_000_000),
                                        defaults: freshDefaults()))

        #expect(report.requested == 2)
        #expect(report.answered == 0)
        #expect(try #require(report.attentionMessage).contains("2 of 2 shows"))
    }

    // Not a probe at all: no marker, so the caller falls through to the normal Prep ingest. nil, never a
    // report claiming a check ran.
    @Test func noMarkerMeansNoReport() throws {
        let ctx = ModelContext(try container())
        let d = dir()
        #expect(settle(d, marker: d.appendingPathComponent("absent.json"),
                       results: d.appendingPathComponent("results.json"), ctx: ctx,
                       now: Date(), defaults: freshDefaults()) == nil)
    }

    // The re-settle path (a relaunch after the ingest but before the marker cleared). consumeIfNew skips
    // the ingest and returns no Outcome at all, so the shortfall must NOT be derived from it: it comes
    // from the marker against the results file, which is on disk either way. Without this the second
    // settle would report a complete run about the same partial one.
    @Test func aReSettleStillReportsTheShortfallWithNoIngestOutcome() throws {
        let ctx = ModelContext(try container())
        let keys = ["Aurora Strings", "Boreal Brass", "Cinder Quartet"].map { newProspect(ctx, group: $0) }
        let d = dir()
        let markerURL = d.appendingPathComponent("probe-run.json")
        let resultsURL = d.appendingPathComponent("results.json")
        let defaults = freshDefaults()
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        try writeResults(resultsURL, PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: keys[0], contacts: [], draft: nil),
        ]))
        try ReachabilityProbeMarker.write(ReachabilityProbeMarker(keys: Set(keys), startedAt: "s"), to: markerURL)
        _ = settle(d, marker: markerURL, results: resultsURL, ctx: ctx, now: now, defaults: defaults)
        // The marker is back, as a relaunch mid-settle would leave it. The results file is unchanged, so
        // consumeIfNew will refuse to ingest it a second time.
        try ReachabilityProbeMarker.write(ReachabilityProbeMarker(keys: Set(keys), startedAt: "s"), to: markerURL)

        let report = try #require(settle(d, marker: markerURL, results: resultsURL, ctx: ctx,
                                        now: now.addingTimeInterval(60), defaults: defaults))

        #expect(report.answered == 1)
        #expect(report.unanswered == 2)
        #expect(try #require(report.attentionMessage).contains("2 of 3 shows"))
    }
}
