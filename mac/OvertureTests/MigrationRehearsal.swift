import Foundation

// #3035: how a migration rehearsal starts, and what it says when it cannot.
//
// The four dry runs rehearse a schema change against a clone of Dan's real store, which is right: a
// migration that has only ever met fresh fixtures is a migration nobody has tried. Each of them had TWO
// silent exits, `guard fm.fileExists(atPath: live.path) else { return }` and
// `guard let copy = try LiveStoreClone.makeClone(in: tmpDir) else { return }`, so a run that examined 936
// real prospects and a run that never opened a file produced the same green tick and the same nothing on
// screen. These are the guards standing between a schema change and Dan's only copy of his queue, and the
// same suite already spent months flaking for a reason nobody looked at (#2930); a rehearsal that quietly
// stopped running would be found the same way, which is to say not at all until a migration went wrong.
//
// It reports rather than FAILS, deliberately. A fresh clone and a CI runner genuinely have no live store,
// so a gate there would be red for everyone who has not run the app, which is a gate nobody could go green
// on and which would be switched off within a day (L93). What a skip gets is a voice.
//
// The two non-rehearsing outcomes are kept apart for L11's reason: "this machine has no live store" is an
// ordinary machine, and "the clone could not be taken" is a rehearsal that TRIED and could not, which is
// worth somebody's attention. One word for both would say neither.
enum MigrationRehearsal {
    // The one string to search a run's log for. Kept as a constant so the sentence can be reworded without
    // the thing looking for it going quiet.
    static let marker = "MIGRATION REHEARSAL"

    enum Start: Equatable {
        // A clone to measure. The only case that proceeds.
        case rehearse(URL)
        // No live store on this machine. Ordinary, and said out loud.
        case skipped(String)
        // There IS a live store and a consistent copy could not be taken.
        case cloneFailed(String)
    }

    // `clone` is injected for the reason `LiveStoreClone`'s own header gives about seams: the interesting
    // branches here are the two that DO NOT happen on a machine with a healthy store, and a fixture that
    // can only ever exercise the third proves nothing about them (L140). Production callers pass nothing
    // and get the real clone.
    static func begin(_ label: String, liveStore: URL?, into dir: URL,
                      clone: (URL, URL) throws -> URL? = { _, dir in
                          try LiveStoreClone.makeClone(in: dir)
                      }) throws -> Start {
        guard let liveStore, FileManager.default.fileExists(atPath: liveStore.path) else {
            return .skipped("\(marker) SKIPPED (\(label)): no live store on this machine, so this "
                            + "migration was rehearsed against nothing. Expected on a fresh clone or a "
                            + "CI runner; on Dan's Mac it means the store is not where it is looked for.")
        }
        guard let copy = try clone(liveStore, dir) else {
            return .cloneFailed("\(marker) NOT RUN (\(label)): there is a live store, and a consistent "
                                + "copy of it could not be taken, so nothing was rehearsed. This is not "
                                + "the ordinary skip.")
        }
        return .rehearse(copy)
    }

    // What every caller does with the two non-rehearsing cases: say it, then stop. Held here so four
    // suites cannot drift into four different ways of being quiet.
    static func report(_ said: String) {
        print(said)
    }
}
