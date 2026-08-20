import Foundation

// #3010 (phase 1 of #2765, itself phase 4 of #2620). Which shows a live run is holding.
//
// A reachability check and a Prep run may not both take the same show: a draft written against a contact
// the check is midway through replacing is the one genuine domain conflict between them. So each run
// publishes its own coverage as it launches, and the other launch reads it and drops the overlap.
//
// WHY A SEPARATE FILE, when #2765's own text said to put the keys in the run's in-flight marker. Measured
// rather than assumed (L82): `mac/scripts/prep-run.sh` does `: > "$MARKER"` at startup, which truncates
// the marker, so anything the app wrote there is destroyed seconds after the run begins. The heartbeat
// (`heartbeat_touch_or_stop` in `lib/run-heartbeat.sh`) uses `touch` and preserves contents, so only the
// startup line is the problem, but a design that survives only until somebody re-adds a truncation is not
// a design. Keeping them apart also keeps liveness (the marker's modification time) and content (these
// keys) in files whose lifecycles genuinely differ, and needs no change to the runner at all.
//
// The marker is still the AUTHORITY on whether the slot is live. This file is only ever read through it.
enum RunCoverage: Equatable, Sendable {

    // Nothing is running in that slot, so nothing is held. A leftover covers file from a run that ended
    // reads as this: it must never exclude anything, or last night's prep silently holds its shows for
    // ever and the refusal names a run that finished yesterday (L121, L68).
    case noLiveRun

    // A live run holding exactly these keys, `alsoAnswersFor` included: a grouped check item answers for
    // several shows and holds all of them.
    case holds(Set<String>)

    // The slot is LIVE and its coverage cannot be established: the file is absent, unreadable, or does not
    // parse. This is a REFUSAL, never permission.
    //
    // It is the whole reason this is three cases and not a `Set<String>?`. Four states would otherwise
    // collapse into one answer: nothing running; a live run holding keys; a live run whose file is
    // corrupt; and a live run that has taken its lock but not yet published. Folding the last two into
    // "excludes nothing" is the fail-OPEN direction (L105, L42), on the one control that stops two paid
    // runs colliding, and an empty answer arrives exactly when the thing has gone wrong. A caller that
    // meets this must refuse its launch and say which file and which slot, because a launch that cannot
    // tell what the other run holds cannot safely take anything (L11, L98).
    case unreadable

    // MARK: - Reading

    // MainActor-isolated because it asks `PrepQueueService.isRunning`, which is. Deliberately, rather
    // than reaching past it to `DetachedRunner.isRunning` with a staleness of its own: "how long untouched
    // means dead" must have ONE definition, or this drifts from the launch guard it exists to serve and
    // the two disagree about whether a run is alive (L107). Every real caller is a launch, which is
    // already on the main actor.
    @MainActor
    static func read(slot: RunSlot, in support: URL, now: Date,
                     markerURL: URL? = nil, coversURL: URL? = nil,
                     recorder: HandoffReadFailures = .shared) -> RunCoverage {
        // The marker first and always. Coverage is a claim ABOUT a run, so it means nothing without one,
        // and asking the file first is what would let a leftover hold shows for ever.
        guard PrepQueueService.isRunning(slot: slot,
                                         markerURL: markerURL ?? slot.markerURL(in: support),
                                         now: now) else { return .noLiveRun }
        let url = coversURL ?? slot.coversURL(in: support)
        // Through the shared reader, not a hand-rolled `try? Data(contentsOf:)`. #2879 made that rule
        // repo-wide, and `HandoffFileReadTests.noAppSourceSwallowsAFileRead` caught this file breaking it:
        // a `try?` makes a file the app COULD NOT READ identical to one that is not there at every caller,
        // which is the same collapse this type exists to prevent, one level down. It also routes the
        // reason into `HandoffReadFailures`, so a corrupt covers file is REPORTED rather than only
        // refused.
        //
        // Absent and corrupt both answer `.unreadable` here, and that is not the collapse #2879 forbids:
        // this read is already inside `isRunning`, so both mean the same single fact, that a LIVE run's
        // coverage cannot be established. What #2879 requires is that the two be told apart where the
        // difference exists, and `HandoffFile` does exactly that on the way past, recording the reason.
        switch HandoffFile.read(at: url, recorder: recorder, decode: { data in
            try JSONDecoder().decode(Set<String>.self, from: data)
        }) {
        case .read(let keys): return .holds(keys)
        case .absent, .unreadable: return .unreadable
        }
    }

    // MARK: - Writing

    // Throws rather than swallowing, deliberately, and unlike its best-effort neighbours in `startPrep`.
    // A run whose coverage was not published holds shows nobody can see, so the exclusion is silently off
    // for the whole of it, and nothing anywhere reports that. The launch must fail loud instead (L12).
    static func write(keys: Set<String>, slot: RunSlot, in support: URL, coversURL: URL? = nil) throws {
        let url = coversURL ?? slot.coversURL(in: support)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONEncoder().encode(keys).write(to: url, options: .atomic)
    }

    // Best effort on purpose, and safe: with the marker already gone the read is `.noLiveRun` whatever is
    // left here, and with the marker still present it is `.unreadable`, which refuses. Neither leaks a
    // hold. That asymmetry is why the runner's EXIT trap must remove the marker BEFORE this file: the
    // reverse order leaves a crash window of marker-live plus covers-absent, and a caller that treated
    // that as "holds nothing" would let both runs take the same show.
    static func clear(slot: RunSlot, in support: URL, coversURL: URL? = nil) {
        try? FileManager.default.removeItem(at: coversURL ?? slot.coversURL(in: support))
    }
}
