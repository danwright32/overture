import Foundation

// #2763 (phase 1 of #2620): which set of files a detached prep-style run owns.
//
// A reachability check and a Prep run are different work over different shows, and they were given ONE
// set of files, every one a fixed name with no run identity in it: the queue, the results, the N of M
// counter, the chunk directory, the logs, the lock and the cancel sentinel. So the single-runner lock is
// preventing a FILENAME COLLISION rather than a conflict in the work, and a check started from Scout
// takes the Prep slot away for up to ten minutes.
//
// TWO SLOTS rather than a generated id per run, which was the issue's own sketch. An id buys generality
// nothing asks for and leaves an unbounded set of directories to reap. What the two real constraints
// describe is exactly two slots: there is one DRAFTING run, forever, because the once-per-run voice step
// rewrites `overture-voice-guidance.md` and several claudes doing that at once would race on one file;
// and there is one CHECKING run, because a second would race its own results.
//
// `.prep` returns today's exact filenames. Nothing on disk moves and no run in flight at an update is
// orphaned.
//
// SHIPPED WITH ONE LIVE USER. In this phase the app hands every run the `.prep` slot, so `.check`'s paths
// exist and nothing writes them yet: the check keeps sharing the prep slot's files, and the exclusion
// between the two is unchanged. #2760 is what moves the check onto its own slot, and #2765 is what lets
// the two run at once. Named here rather than left to be rediscovered, because a deliberately inactive
// half is indistinguishable from a forgotten one (L65).
enum RunSlot: String, CaseIterable, Sendable {
    case prep
    case check

    // MARK: - The files

    // Every name is built from the raw value, so `.prep` reproduces the strings that are already written
    // into `prep-run.sh`, `docs/prep-runbook.md`, `docs/contracts.md` and Dan's Application Support
    // folder, and a second slot cannot accidentally be given one of them.
    func queueURL(in support: URL) -> URL { support.appendingPathComponent("overture-\(rawValue)-queue.json") }
    func resultsURL(in support: URL) -> URL { support.appendingPathComponent("overture-\(rawValue)-results.json") }
    func progressURL(in support: URL) -> URL { support.appendingPathComponent("overture-\(rawValue)-progress.json") }
    func markerURL(in support: URL) -> URL { support.appendingPathComponent("\(rawValue)-running") }
    func cancelURL(in support: URL) -> URL { support.appendingPathComponent("\(rawValue)-cancel") }
    func chunkDirectoryURL(in support: URL) -> URL { support.appendingPathComponent("\(rawValue)-chunks") }
    func claudePIDURL(in support: URL) -> URL { support.appendingPathComponent("\(rawValue)-claude-pid") }
    func stallStateURL(in support: URL) -> URL { support.appendingPathComponent("\(rawValue)-stall-state") }
    func runLogURL(in support: URL) -> URL { support.appendingPathComponent("\(rawValue)-run.log") }
    func eventsURL(in support: URL) -> URL { support.appendingPathComponent("\(rawValue)-run-events.jsonl") }
    func eventsFIFOURL(in support: URL) -> URL { support.appendingPathComponent("\(rawValue)-run-events.fifo") }
    func chunkLogURL(chunk: Int, in support: URL) -> URL {
        support.appendingPathComponent("\(rawValue)-run.chunk-\(chunk).log")
    }
    func chunkEventsURL(chunk: Int, in support: URL) -> URL {
        support.appendingPathComponent("\(rawValue)-run-events.chunk-\(chunk).jsonl")
    }
    func chunkEventsFIFOURL(chunk: Int, in support: URL) -> URL {
        support.appendingPathComponent("\(rawValue)-events-chunk-\(chunk).fifo")
    }

    // Every path this slot owns, labelled. Exists so the collision check can be DERIVED rather than
    // written out beside the list it is checking: a hand-written registry only ever checks the entries
    // somebody remembered, and the entries you remembered are the ones already safe (L96).
    //
    // The chunk paths are sampled at one index. They are a family rather than a single file, and the
    // question being asked of them (can two slots collide on this name) is answered by any one member.
    func allPaths(in support: URL) -> [String: URL] {
        [
            "queue": queueURL(in: support),
            "results": resultsURL(in: support),
            "progress": progressURL(in: support),
            "marker": markerURL(in: support),
            "cancel": cancelURL(in: support),
            "chunkDirectory": chunkDirectoryURL(in: support),
            "claudePID": claudePIDURL(in: support),
            "stallState": stallStateURL(in: support),
            "runLog": runLogURL(in: support),
            "events": eventsURL(in: support),
            "eventsFIFO": eventsFIFOURL(in: support),
            "chunkLog": chunkLogURL(chunk: 0, in: support),
            "chunkEvents": chunkEventsURL(chunk: 0, in: support),
            "chunkEventsFIFO": chunkEventsFIFOURL(chunk: 0, in: support),
        ]
    }

    // MARK: - How the runner is told

    // The slot travels in the ENVIRONMENT, not as an argument, and that is a compatibility decision
    // rather than a style one.
    //
    // The runner script does not ship inside the app bundle. It is resolved from a UserDefaults path
    // into the git checkout (`docs/prep-runbook.md`), and `mac/scripts/update-overture.sh` fast-forwards
    // the checkout BEFORE the 90 second rebuild. So a new script meets an old app that names no slot,
    // for a couple of minutes on every update and permanently for anyone who only pulls. An argument
    // would be missing there; the environment simply carries the default. `DetachedRunner` already
    // threads `OVERTURE_SUPPORT_DIR` this way and passes no arguments at all.
    static let environmentKey = "OVERTURE_RUN_SLOT"

    static func environment(base: [String: String], slot: RunSlot) -> [String: String] {
        var env = base
        env[environmentKey] = slot.rawValue
        return env
    }

    // ABSENT means prep. UNKNOWN is refused (nil), because those are different facts: an old app that
    // says nothing means the run it has always launched, while a value nobody recognises means the two
    // halves disagree about what a slot is, and guessing there is how a run writes another run's files.
    init?(environmentValue: String?) {
        guard let raw = environmentValue, !raw.isEmpty else {
            self = .prep
            return
        }
        guard let slot = RunSlot(rawValue: raw) else { return nil }
        self = slot
    }
}
