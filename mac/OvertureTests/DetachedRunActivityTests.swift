import Testing
import Foundation

// #1923: what an app with nothing happening is allowed to pay.
//
// The queue's reply-run line refreshed on a one-second timer and each tick asked the filesystem whether
// a reply-classify run was alive, on the main thread, for as long as the window was open, whether or not
// a run had ever started. #1917 removed the expensive half of that tick (the progress file is no longer
// opened and decoded every second); this is the half that survived. A second watcher in RootView polled
// the same marker every three seconds, forever, for the same reason.
//
// Neither could simply be deleted: the stat is what NOTICED a run starting. So the noticing moved to the
// two moments the app genuinely learns something, and nothing polls in between:
//
//   - a run the app itself starts is an EVENT (ReplyClassifyService announces it), costing no stat at all
//   - a run left in flight by a previous launch is caught by ONE stat, when this object is first built
//
// The poll still exists, unchanged, inside `followUntilFinished`, because a detached run ends without
// telling anyone. It is confined to the window where a run is actually in flight, which is the whole
// point: an idle surface pays nothing.
@MainActor
@Suite("An idle app stops watching the reply-run marker (#1923)")
struct DetachedRunActivityTests {
    // Stands in for the run marker on disk, counting every stat, so a test can assert what sitting still
    // COSTS rather than only what it answers.
    @MainActor private final class Marker {
        private(set) var stats = 0
        var alive: Bool
        init(alive: Bool) { self.alive = alive }
        func isRunning(_ now: Date) -> Bool {
            stats += 1
            return alive
        }
    }

    // Counts the waits a follow loop makes and lets the test change the world between them, so the loop
    // is driven through a real run's lifetime without a real second passing.
    @MainActor private final class Sleeper {
        private(set) var waits = 0
        private let onWait: @MainActor (Int) -> Void
        init(onWait: @escaping @MainActor (Int) -> Void = { _ in }) { self.onWait = onWait }
        func sleep(_ seconds: TimeInterval) async {
            waits += 1
            onWait(waits)
        }
    }

    // The state Overture sits in essentially all the time: no run, and nothing watching for one.
    @Test func anIdleAppStatsTheMarkerOnceAndThenNotAtAll() async {
        let marker = Marker(alive: false)
        let sleeper = Sleeper()
        let activity = DetachedRunActivity(liveness: marker.isRunning, sleep: sleeper.sleep)

        #expect(activity.isRunning == false)
        #expect(marker.stats == 1)   // the one stat: a run a previous launch left in flight

        // And a watcher asking to follow a run gets an immediate no, with no poll behind it.
        #expect(await activity.followUntilFinished() == false)
        #expect(marker.stats == 1)
        #expect(sleeper.waits == 0)
    }

    // The run Dan starts is an event the app already knows about (it wrote the marker itself), so
    // noticing it costs no stat at all. This is what lets the polling stop.
    @Test func aRunTheAppStartedIsNoticedWithoutAStat() {
        let marker = Marker(alive: false)
        let activity = DetachedRunActivity(liveness: marker.isRunning, sleep: { _ in })

        activity.runStarted()

        #expect(activity.isRunning)
        #expect(marker.stats == 1)   // still just the one from launch
    }

    // The other way a run can be live: it was already going when this launch opened (a detached run
    // outlives the app). The single stat at construction is what catches that one, and it is why the app
    // can then stop looking.
    @Test func aRunAlreadyInFlightAtLaunchIsCaughtByThatOneStat() {
        let marker = Marker(alive: true)
        let activity = DetachedRunActivity(liveness: marker.isRunning, sleep: { _ in })

        #expect(activity.isRunning)
        #expect(marker.stats == 1)
    }

    // While a run IS in flight the poll is exactly what it always was, and it is what notices the run
    // ENDING. Without this the suite could be satisfied by an activity that never looks again, which
    // would leave a spinner sitting over a run that finished.
    @Test func aLiveRunIsPolledUntilItEndsAndThenTheWatchStops() async {
        let marker = Marker(alive: true)
        let sleeper = Sleeper(onWait: { n in if n == 3 { marker.alive = false } })
        let activity = DetachedRunActivity(liveness: marker.isRunning, sleep: sleeper.sleep)

        #expect(await activity.followUntilFinished() == true)

        #expect(activity.isRunning == false)
        #expect(sleeper.waits == 3)
        #expect(marker.stats == 4)   // one at launch, then one after each wait
    }

    // A start reaches a watcher that is already waiting. This is the load-bearing half of dropping the
    // poll: the completion watcher is what ingests the finished drafts, so a start it sleeps through is
    // #435 all over again, a reply drafted and invisible until the next launch.
    @Test(.timeLimit(.minutes(1))) func aStartedRunWakesAWaitingWatcher() async {
        let activity = DetachedRunActivity(liveness: { _ in false }, sleep: { _ in })
        let starts = activity.runStarts()
        let watcher = Task { @MainActor in
            for await _ in starts { return true }
            return false
        }

        activity.runStarted()

        #expect(await watcher.value)
    }

    // And a run already in flight when the watcher attaches is delivered at once, rather than the
    // watcher waiting forever for a start that has already happened.
    @Test(.timeLimit(.minutes(1))) func aWatcherAttachingDuringARunIsToldAtOnce() async {
        let activity = DetachedRunActivity(liveness: { _ in true }, sleep: { _ in })
        let starts = activity.runStarts()

        let watcher = Task { @MainActor in
            for await _ in starts { return true }
            return false
        }

        #expect(await watcher.value)
    }

    // Every run, not just the first. The watcher attaches once for the life of the window, so a signal
    // that fires once would quietly strand every reply drafted after the first run of the session.
    @Test(.timeLimit(.minutes(1))) func eachRunInTurnWakesTheSameWatcher() async {
        let marker = Marker(alive: false)
        let activity = DetachedRunActivity(liveness: marker.isRunning, sleep: { _ in })
        var starts = activity.runStarts().makeAsyncIterator()

        activity.runStarted()
        #expect(await starts.next() != nil)

        #expect(await activity.followUntilFinished())   // the marker is gone: that run has ended
        activity.runStarted()

        #expect(await starts.next() != nil)
    }
}
