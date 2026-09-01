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
// #2760 moved the reachability check onto `.check`: its files, its announce, its results fingerprint, its
// last-run stamp, its archive, its watcher and its takeover are all its own. The EXCLUSION between the two
// is deliberately unchanged and still in force, because #2765 owns the one genuine domain conflict (a
// draft written against a contact a check is midway through replacing). So this phase makes concurrency
// SAFE; #2765 is what turns it on. Named here rather than left to be rediscovered, because a deliberately
// inactive half is indistinguishable from a forgotten one (L65).
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
    // #3010: which shows this slot's live run is holding, so the other launch can drop the overlap rather
    // than two paid runs both taking one show. Deliberately NOT inside the marker: `prep-run.sh` truncates
    // that at startup, so anything written there dies with the run's first second. See `RunCoverage`.
    func coversURL(in support: URL) -> URL { support.appendingPathComponent("\(rawValue)-covers.json") }
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

    // The bare NAMES, for the one caller that needs a name rather than a path: the archive copies these
    // files into a folder of its own. Derived from the same builders above against a neutral base, so a
    // rename cannot reach the path and miss the name.
    private static let nameBase = URL(fileURLWithPath: "/")
    var queueFileName: String { queueURL(in: Self.nameBase).lastPathComponent }
    var resultsFileName: String { resultsURL(in: Self.nameBase).lastPathComponent }
    var archiveFolderName: String { archivesDirectory(in: Self.nameBase).lastPathComponent }

    // MARK: - The archive

    // #1878 keeps each paid run's work-list and results in a dated folder. #2760 gives each slot its own,
    // for two reasons that are separate defects. One folder with one `keep` means a busy night of checks
    // evicts the prep archives #1616's learner reads. And the folder is named for the RUN (from its own
    // `generatedAt`), so two runs stamped in the same second land on one name, at which point the second
    // reads as `alreadyArchived` and its evidence is silently dropped. Separate folders make both
    // impossible rather than unlikely.
    func archivesDirectory(in support: URL) -> URL {
        support.appendingPathComponent("\(rawValue)-run-archives", isDirectory: true)
    }

    // How many of this slot's runs are kept. Its own value rather than a shared constant, so one rotation
    // can be retuned without silently changing how much of the other's history survives. Both are 30
    // today, which is what `prep-run-archives` has held since #1878.
    var archiveKeep: Int { 30 }

    // #3357 Phase 1.2 / #3346: the RAW event streams, in their own dated directory with their own keep.
    //
    // Why a SECOND directory rather than more files in the one above. `DatedFolderRotation.prune` rotates
    // whole FOLDERS by one keep, so a single folder holding both gives one of the two consumers a
    // lifetime nobody chose, silently on both sides: at 10 the queue and results history collapses from
    // 30 to 10, which is exactly the defect #2760 was filed to fix, and at 30 the streams stay for three
    // times their budget. Two directories make both impossible rather than unlikely, which is the answer
    // #2760 already established here for this same question (L285, L191).
    func eventArchivesDirectory(in support: URL) -> URL {
        support.appendingPathComponent("\(rawValue)-run-event-archives", isDirectory: true)
    }

    // Deliberately FEWER runs than the pair above, and the sizes are why. Measured 2026-09-01: the seven
    // surviving stream files total 1.7 MB, mean 252 KB, against archived run folders of 20 to 224 KB.
    // Ten runs of streams is roughly 17 MB.
    //
    // Reader: a same-week diagnosis of a run that went wrong. Nobody reads these months later, which is
    // what makes a shorter keep the right trade rather than a compromise.
    var eventArchiveKeep: Int { 10 }

    // MARK: - The stored state

    // #2760: the keys are per slot for the same reason the files are. `prep.consumedResultsFingerprint`
    // decides `anIngestIsStillToCome`, which chooses between filling blanks and writing the `.noEmailFound`
    // FLOOR over a real answer with a 90 day freshness stamp locking the show out of a re-check (#1623).
    // Two slots ping-ponging one key makes it describe the wrong file.
    //
    // `.prep` reproduces today's exact key, so an upgrade does not re-ingest the last run on first launch.
    var resultsConsumedKey: String { "\(rawValue).consumedResultsFingerprint" }

    // Half of `RunKind.of` and half of `DetachedRunOutcome.phase`. Shared, a check launched after a prep
    // moves the prep's own start stamp, and the prep's finished run is then judged against a moment that
    // belongs to a run it knows nothing about. `.prep` keeps today's key for the same upgrade reason.
    var lastRunStartedAtKey: String { "\(rawValue)LastRunStartedAt" }

    // Every stored key this slot owns, labelled, on the same reasoning as `allPaths`: a collision check
    // written out beside the list it is checking only ever checks the entries somebody remembered (L96).
    func allDefaultsKeys() -> [String: String] {
        [
            "resultsConsumed": resultsConsumedKey,
            "lastRunStartedAt": lastRunStartedAtKey,
        ]
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
            "covers": coversURL(in: support),
            "runLog": runLogURL(in: support),
            "events": eventsURL(in: support),
            "eventsFIFO": eventsFIFOURL(in: support),
            "chunkLog": chunkLogURL(chunk: 0, in: support),
            "chunkEvents": chunkEventsURL(chunk: 0, in: support),
            "chunkEventsFIFO": chunkEventsFIFOURL(chunk: 0, in: support),
            "archives": archivesDirectory(in: support),
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
