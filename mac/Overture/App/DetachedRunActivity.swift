import Foundation
import Observation

// #1923: whether a detached run is in flight, held as one fact the app is TOLD rather than one it keeps
// asking the filesystem for.
//
// It used to be asked. The queue's reply-run line wrapped a one-second TimelineView whose every tick
// stat'ed the run marker, on the main thread, for as long as the window was open, whether or not a
// reply-classify run had ever started; RootView's completion watcher stat'ed the same file every three
// seconds, forever, for the same reason. #1917 removed the expensive half of the queue's tick (the
// progress file is no longer opened and JSON-decoded every second) and said what was left: the stat
// cannot simply be deleted, because it is what NOTICES a run starting.
//
// So the noticing moved to the two moments the app genuinely learns something:
//
//   - a run the app starts is an EVENT. ReplyClassifyService.startClassify announces it, after the launch
//     succeeds, so no surface has to go looking to find out. It costs nothing.
//   - a run left in flight by a PREVIOUS launch (a detached run outlives the app) is caught by exactly one
//     stat, when this object is first built.
//
// The poll survives, unchanged, inside `followUntilFinished`, because a detached run ends without telling
// anyone: the marker going stale is the only word of it. It is now confined to the window where a run is
// actually in flight, which is the whole point of the milestone this belongs to. An idle surface pays
// nothing.
//
// @Observable, like GmailConnection (#1770), so the surfaces reading it re-render when a run really starts
// or ends rather than because they happened to be rebuilt. It must be read only by SMALL views: reading
// `isRunning` inside QueueView's own body would put a whole-store derivation behind every run, which is
// the defect #1774 and #1922 just removed. QueueInvalidationGuardTests pins that.
//
// Session state, deliberately not persisted: it describes what is happening in this second, and one
// surviving a relaunch would be a spinner over a run that ended days ago.
@MainActor
@Observable
final class DetachedRunActivity {
    // The reply-classify run (the classify + drafter run behind "Draft a reply").
    static let replyClassify = DetachedRunActivity(
        liveness: { ReplyClassifyService.isRunning(now: $0) })

    // #1938: the Prep run, and the reachability check that shares its runner and its marker. The scout's
    // detached read still polls its own; this type is not reply-specific, so it can move here the same way.
    static let prep = DetachedRunActivity(
        liveness: { PrepQueueService.isRunning(now: $0) })

    private let liveness: @MainActor (Date) -> Bool
    private let sleep: @MainActor (TimeInterval) async -> Void
    private let pollInterval: TimeInterval

    // True while a run is believed to be in flight. Free to read.
    private(set) var isRunning: Bool

    // Watchers waiting to be told a run has begun. @ObservationIgnored: nothing renders from these, and a
    // watcher attaching must not invalidate a view.
    @ObservationIgnored private var listeners: [UUID: AsyncStream<Void>.Continuation] = [:]

    // `sleep` is injected on the LeadIntakeModel precedent so a test can drive a whole run's lifetime
    // without a real second passing; `liveness` so it can count what sitting still costs.
    init(liveness: @escaping @MainActor (Date) -> Bool,
         sleep: @escaping @MainActor (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
         pollInterval: TimeInterval = 1,
         now: Date = Date()) {
        self.liveness = liveness
        self.sleep = sleep
        self.pollInterval = pollInterval
        self.isRunning = liveness(now)   // the one stat: a run a previous launch left in flight
    }

    // The app just launched a run. No stat: it wrote the marker itself, so it already knows.
    func runStarted() {
        guard !isRunning else { return }   // the run being followed, not a new one
        isRunning = true
        wake()
    }

    // Told once each time a run becomes live, including immediately if one already is when the watcher
    // attaches (a run in flight at launch must not leave the watcher waiting for a start that has already
    // happened). Awaiting this costs nothing at all: there is no timer behind it.
    func runStarts() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        listeners[id] = continuation
        continuation.onTermination = { _ in
            Task { @MainActor [weak self] in self?.listeners[id] = nil }
        }
        if isRunning { continuation.yield() }
        return stream
    }

    // Follow a live run to its end, and report whether one was actually followed. THIS is the poll, and it
    // exists only while a run is in flight: nothing here runs while the app is idle.
    //
    // The Bool is what keeps the caller honest. Its caller ingests the run's results when this returns
    // true, so returning false for "there was no run" and for "the window is closing" is what stops a
    // finished run being ingested twice, or a torn-down app ingesting at all.
    @discardableResult
    func followUntilFinished() async -> Bool {
        guard isRunning else { return false }
        while isRunning {
            if Task.isCancelled { return false }
            await sleep(pollInterval)
            if Task.isCancelled { return false }
            refresh()
        }
        return true
    }

    // The one stat that notices a run ENDING. Private: a detached run's death is the only thing left that
    // has to be discovered by looking, and it can only happen while `followUntilFinished` is watching.
    private func refresh(now: Date = Date()) {
        let live = liveness(now)
        guard live != isRunning else { return }   // never a write for an unchanged value: that is a render
        isRunning = live
        if live { wake() }
    }

    private func wake() {
        for continuation in listeners.values { continuation.yield() }
    }
}
