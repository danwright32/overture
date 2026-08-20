import Testing
import Foundation
import SwiftData

// #3009. `reachability-probe-run.json` is deliberately ONE file for both slots (`RunSlot.swift:186`), and
// it is ALSO what decides what a finished PREP was. That is safe only while one run can be alive, which
// is exactly the premise #2765 removes.
//
// Found by the red-team on #2765's plan-lite, 2026-08-20, and verified against the code before this suite
// was written. Two failures, in opposite directions, neither of them about show overlap:
//
//   1. `startPrep` calls `settleAnyCheckBefore` unconditionally. It reaches `settleOrphanedProbe`, whose
//      only gate is the marker EXISTING, never the run being dead, and then clears the marker
//      unconditionally. So a prep launched during a live check destroys that check's record: its paid
//      answers are never stamped and the shows are paid for again. That is #1594 restored.
//
//   2. A prep finishing while a check is live is settled through the SHARED marker, so it reads the
//      CHECK's keys against the PREP's results, ingests with `isProbe: true`, short circuits before draft
//      handling and discards every draft the prep wrote. The `#2760` comment at `PrepQueueService:451`
//      names this hazard and calls it "the exact hazard this phase creates".
//
// The rule both halves need is the same one #2980 applied to the runner: run identity is CARRIED, never
// deduced from which files happen to be lying around. Here the evidence is the check slot's own marker: a
// live check owns the shared probe marker, whatever else is on disk.
//
// Every negative below has its POSITIVE control in the same fixture (L159): a suite asserting only that
// something did not happen is satisfied by a fixture in which it could not have happened.
@MainActor
@Suite("A live check is not settled by a prep (#3009)")
struct LiveCheckIsNotSettledByAPrepTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, OrgReachabilityAnswer.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func dir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "live-check-3009-\(UUID().uuidString)")!
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

    // The check's own record, sitting at the shared path exactly as `startReachabilityProbe` leaves it.
    private func writeCheckMarker(_ support: URL, keys: Set<String>, startedAt: Date) throws {
        let marker = ReachabilityProbeMarker(keys: keys,
                                             startedAt: ISO8601DateFormatter().string(from: startedAt),
                                             lookups: keys.count)
        try ReachabilityProbeMarker.write(marker, to: PrepQueueService.probeRunURL(in: support))
    }

    // A LIVE check: its slot marker exists and has just been touched, so `isRunning(slot: .check)` is true
    // against `markerStaleAfter`. This is the whole difference between the two halves of every test below.
    private func makeCheckLive(_ support: URL) throws {
        try Data().write(to: RunSlot.check.markerURL(in: support))
    }

    private func writePrepResults(_ support: URL, key: String) throws {
        let results = PrepResults(version: 10, generatedAt: "2026-08-20T00:00:00Z",
                                  results: [PrepResult(naturalKey: key)])
        try JSONEncoder().encode(results).write(to: RunSlot.prep.resultsURL(in: support))
    }

    private func markerExists(_ support: URL) -> Bool {
        FileManager.default.fileExists(atPath: PrepQueueService.probeRunURL(in: support).path)
    }

    // MARK: - 1. A prep launch must not settle or clear a LIVE check

    @Test func aPrepLaunchLeavesALiveChecksRecordAlone() throws {
        let ctx = ModelContext(try container())
        let key = newProspect(ctx, group: "Aurora Strings")
        let d = dir()
        let now = Date()
        try writeCheckMarker(d, keys: [key], startedAt: now)
        try makeCheckLive(d)

        let report = PrepQueueService.settleAnyCheckBefore(prepRunIn: ctx, now: now, support: d,
                                                           defaults: freshDefaults())

        #expect(report == nil, "a LIVE check is not a finished one and must not be settled")
        #expect(markerExists(d),
                "the live check's record was destroyed: its paid answers can now never be stamped (#1594)")
    }

    // THE POSITIVE CONTROL, in the same fixture. Without it the assertion above is satisfied by any
    // fixture in which nothing could have been settled anyway.
    @Test func aPrepLaunchStillSettlesACheckThatHasActuallyEnded() throws {
        let ctx = ModelContext(try container())
        let key = newProspect(ctx, group: "Aurora Strings")
        let d = dir()
        let now = Date()
        try writeCheckMarker(d, keys: [key], startedAt: now)
        // No check-slot marker: the run ended and the runner removed it, which is the ordinary case.

        let report = PrepQueueService.settleAnyCheckBefore(prepRunIn: ctx, now: now, support: d,
                                                           defaults: freshDefaults())

        #expect(report != nil, "an ENDED check must still be settled before a prep starts, as today")
        #expect(!markerExists(d), "and its marker cleared, so it cannot relabel the prep about to run")
    }

    // MARK: - 2. A finished prep must not be read through a LIVE check's marker

    @Test func aFinishedPrepIsNotReadAsACheckWhileAnotherCheckIsLive() throws {
        let ctx = ModelContext(try container())
        let checkKey = newProspect(ctx, group: "Borealis Quartet")
        let prepKey = newProspect(ctx, group: "Cascade Ensemble")
        let d = dir()
        let now = Date()
        // The live check's marker names the CHECK's shows. The prep's results name the prep's.
        try writeCheckMarker(d, keys: [checkKey], startedAt: now)
        try makeCheckLive(d)
        try writePrepResults(d, key: prepKey)

        let report = PrepQueueService.settleReachabilityProbe(slot: .prep, support: d,
                                                              into: ctx, now: now,
                                                              defaults: freshDefaults())

        #expect(report == nil,
                "the prep was settled through a live CHECK's marker, so it ingests as a probe and every draft it wrote is discarded")
        #expect(markerExists(d), "and the live check's marker was cleared out from under it")
    }

    // THE POSITIVE CONTROL. The same marker, the same results, the same call, with the check slot NOT
    // live: the leftover-marker settle that #1809 added must still happen.
    @Test func aFinishedPrepIsStillSettledThroughALeftoverMarkerWhenNoCheckIsLive() throws {
        let ctx = ModelContext(try container())
        let checkKey = newProspect(ctx, group: "Borealis Quartet")
        let prepKey = newProspect(ctx, group: "Cascade Ensemble")
        let d = dir()
        let now = Date()
        try writeCheckMarker(d, keys: [checkKey], startedAt: now)
        try writePrepResults(d, key: prepKey)

        let report = PrepQueueService.settleReachabilityProbe(slot: .prep, support: d,
                                                              into: ctx, now: now,
                                                              defaults: freshDefaults())

        #expect(report != nil,
                "with no live check, a leftover marker is still the #1809 case and must still settle")
    }
}
