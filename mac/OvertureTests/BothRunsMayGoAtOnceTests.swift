import Testing
import Foundation
import SwiftData

// #3015, the phase that turns #2620 on. Dan asked the question on 2026-08-13: "does prep *have* to be
// blocked by the check? or is that just how we built it?" It was how it was built, and this is where that
// stops being true.
//
// LIFTING IS FOUR GATES, NOT ONE, which is the red-team's finding on the plan. `runInFlightRefusal` is
// only the throw, and it is the LAST of the four. Three UI gates run before it and none goes through it,
// so lifting only the throw would have shipped the feature invisible: the Prep button still hidden and
// the menu item still greyed out whenever a check was going.
//
//   1. `PrepStartGate` behind the menu item and Cmd+P, which refused for ANY live run;
//   2. `PrepQueueButton.shouldShow`, fed by a flag that was `anyRunIsRunning`;
//   3. the check controls (`ProbeSelectionBar`, the row's "Check again"), fed by the SAME flag;
//   4. `runInFlightRefusal` itself.
//
// This suite also carries the end-to-end assertions #2765 could not: its subtraction only does anything
// when the other slot is live, which was exactly the state the old exclusion refused, so a launch-level
// test was refused before it reached the code under test. That is now reachable, so it is tested here.
@MainActor
@Suite("A check and a Prep run may go at once (#3015)")
struct BothRunsMayGoAtOnceTests {

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
        UserDefaults(suiteName: "both-runs-3015-\(UUID().uuidString)")!
    }

    private func makeLive(_ slot: RunSlot, in support: URL) throws {
        try Data().write(to: slot.markerURL(in: support))
    }

    @discardableResult
    private func newProspect(_ ctx: ModelContext, group: String) -> String {
        let key = Prospect.makeNaturalKey(groupName: group, performanceDate: "2026-09-12", venue: "Weill Recital Hall")
        let p = Prospect(naturalKey: key, groupName: group, discipline: "music", venue: "Weill Recital Hall",
                         performanceDate: "2026-09-12", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .queued)
        ctx.insert(p)
        try? ctx.save()
        return key
    }

    // MARK: - Gate 4, the throw

    @Test func aCheckIsNoLongerRefusedByALivePrep() throws {
        let d = dir()
        try makeLive(.prep, in: d)
        let defaults = freshDefaults()
        PrepQueueService.recordRunStarted(slot: .prep, at: Date(), defaults: defaults)
        #expect(PrepQueueService.runInFlightRefusal(slot: .check, now: Date(), support: d,
                                                    defaults: defaults) == nil)
    }

    @Test func aPrepIsNoLongerRefusedByALiveCheck() throws {
        let d = dir()
        try makeLive(.check, in: d)
        #expect(PrepQueueService.runInFlightRefusal(slot: .prep, now: Date(), support: d,
                                                    defaults: freshDefaults()) == nil)
    }

    // THE POSITIVE CONTROLS. The slot's own lock has always meant one run at a time and still does: one
    // drafting run forever (the once-per-run voice step rewrites one file) and one checking run (a second
    // would race its own results). Without these, "no longer refused" passes on a guard simply deleted.
    @Test func aSecondPrepIsStillRefused() throws {
        let d = dir()
        try makeLive(.prep, in: d)
        let defaults = freshDefaults()
        PrepQueueService.recordRunStarted(slot: .prep, at: Date(), defaults: defaults)
        #expect(PrepQueueService.runInFlightRefusal(slot: .prep, now: Date(), support: d,
                                                    defaults: defaults) == .alreadyRunning)
    }

    @Test func aSecondCheckIsStillRefused() throws {
        let d = dir()
        try makeLive(.check, in: d)
        #expect(PrepQueueService.runInFlightRefusal(slot: .check, now: Date(), support: d,
                                                    defaults: freshDefaults()) == .checkAlreadyRunning)
    }

    // THE UPGRADE WINDOW, which is the one place two CHECKS could otherwise run at once: a check started
    // by a build older than #2760 sits in the PREP slot, so the check slot reads as empty. #2800 deletes
    // this branch once the log line proving it is taken stops appearing.
    @Test func aCheckIsStillRefusedByALegacyCheckHoldingThePrepSlot() throws {
        let d = dir()
        let defaults = freshDefaults()
        try makeLive(.prep, in: d)
        // The marker's start is well AFTER the prep slot's recorded run start, which is what
        // `RunKind.of` reads as "this run is a check", not a prep.
        PrepQueueService.recordRunStarted(slot: .prep, at: Date().addingTimeInterval(-3600), defaults: defaults)
        try ReachabilityProbeMarker.write(
            ReachabilityProbeMarker(keys: ["k"], startedAt: ISO8601DateFormatter().string(from: Date()),
                                    lookups: 1),
            to: PrepQueueService.probeRunURL(in: d))

        #expect(PrepQueueService.runInFlightRefusal(slot: .check, now: Date(), support: d,
                                                    defaults: defaults) == .checkAlreadyRunning,
                "a legacy check in the prep slot must still block a new check, or two checks race one results file")
    }

    // A live PREP does not block a check, even though the same slot blocks a legacy check. The difference
    // is what kind of run is in that slot, not that the slot is busy.
    @Test func anOrdinaryLivePrepDoesNotBlockACheck() throws {
        let d = dir()
        let defaults = freshDefaults()
        try makeLive(.prep, in: d)
        PrepQueueService.recordRunStarted(slot: .prep, at: Date(), defaults: defaults)
        #expect(PrepQueueService.runInFlightRefusal(slot: .check, now: Date(), support: d,
                                                    defaults: defaults) == nil)
    }

    // MARK: - Gate 1, the menu item and Cmd+P

    @Test func theMenuItemNoLongerRefusesWhileACheckRuns() {
        // The gate is handed the PREP slot's own question, so a live check is simply not its business.
        #expect(PrepStartGate.canStart(keptToPrep: 3, ownSlotRunInFlight: nil))
        #expect(PrepStartGate.reason(keptToPrep: 3, ownSlotRunInFlight: nil) == nil)
    }

    // THE POSITIVE CONTROL: a live PREP still refuses, and still says which run.
    @Test func theMenuItemStillRefusesWhileAPrepRuns() {
        #expect(!PrepStartGate.canStart(keptToPrep: 3, ownSlotRunInFlight: .prep))
        #expect(PrepStartGate.reason(keptToPrep: 3, ownSlotRunInFlight: .prep)?.contains("prep run") == true)
    }

    // MARK: - End to end, which #2765 could not reach

    @Test func aCheckStartedBesideALivePrepRunsAndLeavesThePrepsShowsOut() async throws {
        let ctx = ModelContext(try container())
        let heldByPrep = newProspect(ctx, group: "Aurora Strings")
        let free = newProspect(ctx, group: "Borealis Quartet")
        let d = dir()
        let defaults = freshDefaults()
        // A prep is genuinely live and holding one of the two shows.
        try makeLive(.prep, in: d)
        PrepQueueService.recordRunStarted(slot: .prep, at: Date(), defaults: defaults)
        try RunCoverage.write(keys: [heldByPrep], slot: .prep, in: d)

        var launched = false
        let count = try await PrepQueueService.startReachabilityProbe(
            keys: [heldByPrep, free], from: ctx, now: Date(), support: d, defaults: defaults,
            render: { _ in "" }, launch: { launched = true })

        #expect(launched, "the check must start: this is the whole point of the milestone")
        #expect(count == 1, "and must leave out the show the live prep is drafting")
        let queue = try JSONDecoder().decode(PrepQueue.self,
                                             from: Data(contentsOf: RunSlot.check.queueURL(in: d)))
        #expect(queue.items.map(\.naturalKey) == [free])
        // And the show it left out says so, durably (#3013).
        let dropped = ((try? ctx.fetch(FetchDescriptor<Prospect>())) ?? []).first { $0.naturalKey == heldByPrep }
        #expect(dropped?.heldBackAt != nil, "the skipped show carries no mark, so nothing on screen says why")
        #expect(dropped?.heldBackBySlot == "check")
    }

    @Test func aPrepStartedBesideALiveCheckRunsAndLeavesTheChecksShowsOut() async throws {
        let ctx = ModelContext(try container())
        let heldByCheck = newProspect(ctx, group: "Aurora Strings")
        let free = newProspect(ctx, group: "Borealis Quartet")
        let d = dir()
        try makeLive(.check, in: d)
        try RunCoverage.write(keys: [heldByCheck], slot: .check, in: d)

        var launched = false
        let count = try await PrepQueueService.startPrep(from: ctx, now: Date(), support: d,
                                                         defaults: freshDefaults(),
                                                         render: { _ in "" }, launch: { launched = true })

        #expect(launched)
        #expect(count == 1, "the prep must leave out the show the live check is replacing a contact for")
        let queue = try JSONDecoder().decode(PrepQueue.self,
                                             from: Data(contentsOf: RunSlot.prep.queueURL(in: d)))
        #expect(queue.items.map(\.naturalKey) == [free])
    }

    // The refusal for a run whose every show is held, which #2765 also could not reach through a launch.
    @Test func aRunWhoseEveryShowIsHeldRefusesAndStartsNothing() async throws {
        let ctx = ModelContext(try container())
        let only = newProspect(ctx, group: "Aurora Strings")
        let d = dir()
        try makeLive(.check, in: d)
        try RunCoverage.write(keys: [only], slot: .check, in: d)

        var launched = false
        var caught: PrepQueueService.PrepLaunchError?
        do {
            _ = try await PrepQueueService.startPrep(from: ctx, now: Date(), support: d,
                                                     defaults: freshDefaults(),
                                                     render: { _ in "" }, launch: { launched = true })
        } catch let error as PrepQueueService.PrepLaunchError {
            caught = error
        }
        // The SPECIFIC refusal, not merely that something threw. `#expect(throws:)` on the error TYPE is
        // satisfied by `nothingToPrep`, which is a different situation with a different sentence, and an
        // ineligible fixture would have passed this test while proving nothing (L140).
        #expect(caught == .everyShowHeld(runNoun: RunKind.reachabilityCheck.runNoun),
                "expected the every-show-held refusal, got \(String(describing: caught))")
        #expect(!launched, "an empty run must not be started: finding nothing to do is not success (L98)")
        #expect(!FileManager.default.fileExists(atPath: RunSlot.prep.markerURL(in: d).path),
                "and the lock must not be left held by a run that never started")
    }

    // And the fail-closed case, also unreachable before: a live slot whose holdings cannot be read stops
    // the other launch rather than letting both take the same show.
    @Test func aLiveRunWithUnreadableHoldingsStopsTheOtherLaunch() async throws {
        let ctx = ModelContext(try container())
        newProspect(ctx, group: "Aurora Strings")
        let d = dir()
        try makeLive(.check, in: d)
        try Data("not json".utf8).write(to: RunSlot.check.coversURL(in: d))

        var launched = false
        var caught: PrepQueueService.PrepLaunchError?
        do {
            _ = try await PrepQueueService.startPrep(from: ctx, now: Date(), support: d,
                                                     defaults: freshDefaults(),
                                                     render: { _ in "" }, launch: { launched = true })
        } catch let error as PrepQueueService.PrepLaunchError {
            caught = error
        }
        #expect(caught == .holdingsUnreadable(runNoun: RunKind.reachabilityCheck.runNoun),
                "expected the unreadable-holdings refusal, got \(String(describing: caught))")
        #expect(!launched)
    }
}
