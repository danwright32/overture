import Foundation

// #3014 (phase 6 of #2765). The shows a live run is on, cached, for the ONE reader that needs them on the
// render path: the organisation fan-out.
//
// Two constraints shape this, and both come from the red-team on #2765's plan.
//
// IT MUST NOT READ THE DISK WHILE THE SCREEN IS DRAWING. `QueueModel.items(from:)` re-derives on every
// render, and `QueueRenderPassCostTests` already refused a ninth whole-store sweep for the same reason.
// Two JSON decodes and two file-modification reads per render pass would reintroduce exactly what #1965
// and #1774 removed. So the value is cached and refreshed on the events the app already sees.
//
// AND A RUN ENDING HAS NO STORE WRITE TO HANG A REBUILD ON. A run that is cancelled or dies writes nothing
// to SwiftData, so nothing would re-derive the queue and the block could outlive the run that caused it
// (L175). Refreshing here on run start and run end supplies the trigger the view could not.
//
// WHAT IT BLOCKS, AND WHEN, is narrower than "any live run", deliberately. The conflict is a check writing
// a NEW organisation answer that moves onto a show a prep is drafting. With no check running, no new org
// answer can appear, the fan-out is static, and blocking anything would only hide badges Dan should see:
// that is the regression the first draft would have shipped, firing on 100% of preps rather than on the
// concurrent case. So this is non-empty only when a CHECK is live, and then it holds what the PREP is on.
@MainActor
enum LiveRunHoldings {

    private static var cached: Set<String> = []

    // What the fan-out must not move onto. Empty whenever there is nothing to protect against.
    static var current: Set<String> { cached }

    // Re-read from disk. Called at run start, run end and the dead-run sweep, never from a view body.
    static func refresh(support: URL = StoreLocation.handoffDirectory, now: Date = Date()) {
        cached = holdings(support: support, now: now)
    }

    // Pure enough to test: the rule, given the two files, with no caching in the way.
    static func holdings(support: URL, now: Date) -> Set<String> {
        // Nothing can change an organisation's answer unless a check is running, so nothing is blocked.
        guard PrepQueueService.isRunning(slot: .check,
                                         markerURL: RunSlot.check.markerURL(in: support),
                                         now: now) else { return [] }
        // A prep's coverage is what the check could pull the ground from under.
        //
        // `.unreadable` yields EMPTY here rather than refusing, and that is the opposite of the choice
        // `heldByOtherRun` makes at a launch, on purpose. There, refusing costs a run that has not started
        // and protects paid work. Here, refusing would mean blanking every inherited badge on the queue,
        // which is a worse answer for Dan than showing one that is momentarily stale, and there is no
        // launch to stop. The launch path is where this class of failure is caught.
        if case .holds(let keys) = RunCoverage.read(slot: .prep, in: support, now: now) { return keys }
        return []
    }
}
