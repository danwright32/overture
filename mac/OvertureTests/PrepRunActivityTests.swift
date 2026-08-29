import Testing
import Foundation
import SwiftData

// #1938: an app with no Prep run happening is not allowed to keep asking whether one has started.
//
// The watcher sat in a loop that stat'ed the Prep run marker every three seconds for the whole life of
// the window, whether or not a run had ever started. #1923 removed exactly this shape from the reply
// side, and the machinery it built is not reply specific: a run the app starts is an EVENT, and a run a
// previous launch left in flight is caught by one stat when the activity is first built.
//
// The poll survives inside `followUntilFinished`, because a detached run ends without telling anyone, and
// it exists only while a run is genuinely in flight.
@MainActor
@Suite("An idle app stops watching the Prep run marker (#1938)")
struct PrepRunActivityTests {
    @MainActor private final class Marker {
        private(set) var stats = 0
        var alive: Bool
        init(alive: Bool) { self.alive = alive }
        func isRunning(_ now: Date) -> Bool {
            stats += 1
            return alive
        }
    }

    @MainActor private final class Sleeper {
        private(set) var waits = 0
        private let onWait: @MainActor (Int) -> Void
        init(onWait: @escaping @MainActor (Int) -> Void = { _ in }) { self.onWait = onWait }
        func sleep(_ seconds: TimeInterval) async {
            waits += 1
            onWait(waits)
        }
    }

    private func container() throws -> ModelContainer {
        try ModelContainer(
            for: Schema([Prospect.self, PromotedProducer.self, DemotedHouse.self, Recipient.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    @discardableResult
    private func kept(_ ctx: ModelContext, group: String) -> Prospect {
        let key = Prospect.makeNaturalKey(groupName: group, performanceDate: "2026-09-11", venue: "The Room")
        let p = Prospect(naturalKey: key, groupName: group, discipline: "other", venue: "The Room",
                         performanceDate: "2026-09-11", sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .queued)
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    private func tmp(_ prefix: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    }

    // The state Overture sits in nearly all the time: no Prep run, and nothing watching for one.
    @Test func anIdleAppStatsThePrepMarkerOnceAndThenNotAtAll() async {
        let marker = Marker(alive: false)
        let sleeper = Sleeper()
        let activity = DetachedRunActivity(liveness: marker.isRunning, sleep: sleeper.sleep)

        #expect(activity.isRunning == false)
        #expect(marker.stats == 1)   // the one stat: a run a previous launch left in flight
        #expect(await activity.followUntilFinished() == false)
        #expect(marker.stats == 1)
        #expect(sleeper.waits == 0)
    }

    // The Prep activity is its own, not the reply one under another name. Without this a Prep run and a
    // reply run would share one liveness answer, so either could open the other's takeover and ingest the
    // other's results. Asserted by identity rather than by reading isRunning, which is a live answer about
    // this Mac and would make the test's verdict depend on whether a run happens to be going.
    @Test func thePrepActivityIsItsOwnAndNotTheReplyOne() {
        #expect(DetachedRunActivity.prep !== DetachedRunActivity.replyClassify)
    }

    // A Prep run started from ANY surface announces itself, which is what lets the idle app stop looking.
    // The announce lives at the service, so a per-row Re-prep (which reaches the service directly, with no
    // view call at all) cannot forget it.
    @Test func aStartedPrepRunAnnouncesItself() async throws {
        let ctx = ModelContext(try container())
        kept(ctx, group: "Nightingale Quartet")
        let queueURL = tmp("q"), markerURL = tmp("m")
        defer { try? FileManager.default.removeItem(at: queueURL); try? FileManager.default.removeItem(at: markerURL) }
        var announced = 0

        _ = try await PrepQueueService.startPrep(from: ctx, now: Date(), queueURL: queueURL,
                                                 markerURL: markerURL, render: { _ in "" },
                                                 announce: { announced += 1 }, launch: {})

        #expect(announced == 1)
    }

    // The failure path. A launch that never happened announces nothing: an announced run with nothing
    // behind it would open the takeover over a run that does not exist, and send the watcher off to
    // ingest results no run ever wrote.
    @Test func aFailedPrepLaunchAnnouncesNothing() async throws {
        struct LaunchFailed: Error {}
        let ctx = ModelContext(try container())
        kept(ctx, group: "Nightingale Quartet")
        let queueURL = tmp("q"), markerURL = tmp("m")
        defer { try? FileManager.default.removeItem(at: queueURL); try? FileManager.default.removeItem(at: markerURL) }
        var announced = 0

        await #expect(throws: LaunchFailed.self) {
            _ = try await PrepQueueService.startPrep(from: ctx, now: Date(), queueURL: queueURL,
                                                     markerURL: markerURL, render: { _ in "" },
                                                     announce: { announced += 1 },
                                                     launch: { throw LaunchFailed() })
        }

        #expect(announced == 0)
    }

    // A start refused because one is already running announces nothing either: the run it would announce
    // is the one already being followed.
    @Test func aRefusedDoublePrepStartAnnouncesNothing() async throws {
        let ctx = ModelContext(try container())
        kept(ctx, group: "Nightingale Quartet")
        let queueURL = tmp("q"), markerURL = tmp("m")
        defer { try? FileManager.default.removeItem(at: queueURL); try? FileManager.default.removeItem(at: markerURL) }
        var announced = 0
        _ = try await PrepQueueService.startPrep(from: ctx, now: Date(), queueURL: queueURL,
                                                 markerURL: markerURL, render: { _ in "" },
                                                 announce: { announced += 1 }, launch: {})

        await #expect(throws: (any Error).self) {
            _ = try await PrepQueueService.startPrep(from: ctx, now: Date(), queueURL: queueURL,
                                                     markerURL: markerURL, render: { _ in "" },
                                                     announce: { announced += 1 }, launch: {})
        }

        #expect(announced == 1)
    }

    // The reachability check runs on the same runner and writes the same marker, so it announces too.
    // Without this a check would run entirely unwatched: no takeover, and its paid answers never settled.
    @Test func aStartedReachabilityCheckAnnouncesItself() async throws {
        let ctx = ModelContext(try container())
        let p = kept(ctx, group: "Nightingale Quartet")
        let queueURL = tmp("q"), markerURL = tmp("m"), probeURL = tmp("p")
        defer {
            for url in [queueURL, markerURL, probeURL] { try? FileManager.default.removeItem(at: url) }
        }
        var announced = 0

        _ = try await PrepQueueService.startReachabilityProbe(keys: [p.naturalKey], from: ctx, now: Date(),
                                                              queueURL: queueURL, markerURL: markerURL,
                                                              probeRunURL: probeURL,
                                                              render: { _ in "" },
                                                              announce: { announced += 1 }, launch: {})

        #expect(announced == 1)
    }
}

// The wiring the existing #1143 guard does not cover: where the announcement comes FROM. That guard owns
// the watcher's own shape, so this does not restate it.
@Suite("A Prep run announces itself from the service, not from its call sites (#1938)")
struct PrepRunAnnounceWiringTests {
    private var service: String { SourceGuardHelper.source("Overture/Integration/PrepQueueService.swift") }
    private var activity: String { SourceGuardHelper.source("Overture/App/DetachedRunActivity.swift") }

    // Both start paths announce, at the service rather than at their call sites, so no surface that can
    // launch a run is able to leave it unwatched. A per-row Re-prep reaches the service with no view call
    // at all, which is exactly the call site that would have been missed.
    // #2760: each announces to its OWN slot's activity. One shared object opened `runStarted()` with
    // `guard !isRunning else { return }`, so a check launched during a live prep announced to nobody and
    // was never followed or settled.
    @Test func bothStartPathsAnnounceFromTheServiceItself() {
        #expect(!service.isEmpty)
        #expect(service.contains("announce: @MainActor () -> Void = { DetachedRunActivity.prep.runStarted() }"))
        #expect(service.contains("announce: @MainActor () -> Void = { DetachedRunActivity.check.runStarted() }"))
        #expect(service.components(separatedBy: "announce()").count - 1 >= 2)
    }

    // And the shared activity reads the Prep marker. Asserted here because the behavioural version of this
    // would have to read a live answer about this Mac.
    @Test func theSharedActivityIsBuiltOnThePrepMarker() {
        #expect(activity.contains("static let prep = DetachedRunActivity("))
        #expect(activity.contains("liveness: { PrepQueueService.isRunning(slot: .prep, now: $0) }"))
        // #2760: and the check's own, on the check slot's marker.
        #expect(activity.contains("static let check = DetachedRunActivity("))
        #expect(activity.contains("liveness: { PrepQueueService.isRunning(slot: .check, now: $0) }"))
    }
}
