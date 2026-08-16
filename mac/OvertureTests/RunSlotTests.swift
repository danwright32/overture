import Testing
import Foundation

// #2763 (phase 1 of #2620): one owner for every file a detached prep-style run touches.
//
// A reachability check and a Prep run share one set of fixed filenames, so the single-runner lock is
// preventing a FILENAME collision rather than a conflict in the work. `RunSlot` is what makes the two
// separable: it computes every path from the slot, in one place, so nothing has to remember the list.
//
// `.prep` must keep today's exact names. Nothing on disk moves, and a run in flight when Dan updates is
// not orphaned.
@Suite("Every run file has one owner (#2763)")
struct RunSlotTests {

    private let support = URL(fileURLWithPath: "/tmp/overture-runslot-tests", isDirectory: true)

    // The names that exist on Dan's Mac right now. Written out as literals ON PURPOSE: a test that
    // derived them the way the code does would agree with the code however the code changed, which is a
    // check whose two sides come from one lookup (L70). These are the strings a stale file, a runbook, a
    // doc and a shell script all already name.
    @Test("the prep slot keeps every filename it has today")
    func prepKeepsTodaysNames() {
        let prep = RunSlot.prep
        #expect(prep.queueURL(in: support).lastPathComponent == "overture-prep-queue.json")
        #expect(prep.resultsURL(in: support).lastPathComponent == "overture-prep-results.json")
        #expect(prep.progressURL(in: support).lastPathComponent == "overture-prep-progress.json")
        #expect(prep.markerURL(in: support).lastPathComponent == "prep-running")
        #expect(prep.cancelURL(in: support).lastPathComponent == "prep-cancel")
        #expect(prep.chunkDirectoryURL(in: support).lastPathComponent == "prep-chunks")
        #expect(prep.claudePIDURL(in: support).lastPathComponent == "prep-claude-pid")
        #expect(prep.stallStateURL(in: support).lastPathComponent == "prep-stall-state")
        #expect(prep.runLogURL(in: support).lastPathComponent == "prep-run.log")
        #expect(prep.eventsURL(in: support).lastPathComponent == "prep-run-events.jsonl")
        #expect(prep.eventsFIFOURL(in: support).lastPathComponent == "prep-run-events.fifo")
        #expect(prep.chunkLogURL(chunk: 3, in: support).lastPathComponent == "prep-run.chunk-3.log")
        #expect(prep.chunkEventsURL(chunk: 3, in: support).lastPathComponent == "prep-run-events.chunk-3.jsonl")
        #expect(prep.chunkEventsFIFOURL(chunk: 3, in: support).lastPathComponent == "prep-events-chunk-3.fifo")
    }

    // The point of the type. Derived over `allPaths` rather than listed, so a path added later is covered
    // without anybody remembering to add it here (L96): the hand-written list in this plan's first draft
    // had already missed the two FIFOs and the chunk logs.
    @Test("no two slots can share a path")
    func slotsNeverCollide() {
        var seen: [String: RunSlot] = [:]
        for slot in RunSlot.allCases {
            for (label, url) in slot.allPaths(in: support) {
                let name = url.lastPathComponent
                if let other = seen[name] {
                    Issue.record("\(slot) and \(other) both use \(name) (\(label))")
                }
                seen[name] = slot
            }
        }
        // And the sweep really did look at something, so an empty dictionary cannot pass as agreement
        // (L98: finding nothing is not a pass).
        #expect(seen.count >= 14 * RunSlot.allCases.count)
    }

    @Test("every slot answers for the same set of paths")
    func everySlotCoversTheSameSet() {
        let labels = RunSlot.allCases.map { Set($0.allPaths(in: support).keys) }
        for set in labels {
            #expect(set == labels[0], "a slot answers for a different set of files than its siblings")
        }
    }

    // MARK: what the runner is told

    // Absent means prep, and that is not laziness. The runner script is NOT in the app bundle: it is
    // resolved from a UserDefaults path into the git checkout, and `update-overture.sh` fast-forwards
    // the checkout BEFORE the 90 second rebuild, so a new script routinely meets an old app that names no
    // slot. Refusing there would kill Prep in that window, and the death would land in a log nobody is
    // reading. An UNKNOWN value is a different thing and is refused.
    @Test("an absent slot is the prep slot, and an unknown one is refused")
    func theSlotIsReadLeniently() {
        #expect(RunSlot(environmentValue: nil) == .prep)
        #expect(RunSlot(environmentValue: "") == .prep)
        #expect(RunSlot(environmentValue: "prep") == .prep)
        #expect(RunSlot(environmentValue: "check") == .check)
        #expect(RunSlot(environmentValue: "Prep") == nil, "case is not guessed at")
        #expect(RunSlot(environmentValue: "probe") == nil)
        #expect(RunSlot(environmentValue: "prep ") == nil)
    }

    @Test("the slot the app hands the runner is the one the runner reads back")
    func theEnvironmentRoundTrips() {
        for slot in RunSlot.allCases {
            let env = RunSlot.environment(base: [:], slot: slot)
            #expect(RunSlot(environmentValue: env[RunSlot.environmentKey]) == slot)
        }
    }
}
