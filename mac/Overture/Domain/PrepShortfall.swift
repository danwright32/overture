import Foundation

// #876: which shows a Prep run was given and never answered.
//
// A run that returns results for 3 of the 5 shows it was queued used to have the 3 ingested and the other
// 2 passed over in silence. They keep their un-drafted state, so the next run picks them up again and
// nothing is lost, but Dan was never told. A show the model chokes on every single time would be retried
// forever, silently, and the only symptom is a Prep pill whose count never quite goes down. Self-healing
// is not the same as visible.
//
// The APP wrote the queue, so it already knows what it asked for. This is that comparison, and nothing
// more: it never synthesizes a result. An empty prep result invented here would CLAIM the run researched a
// show and found nobody, about a show nobody ever looked at (#868).
enum PrepShortfall {

    // The queued keys these results never answered, in the order they were queued.
    //
    // Returns nothing at all unless the results can actually BE an answer to this queue, which is the
    // whole difficulty of the issue. `startPrep` writes a fresh queue but leaves the PREVIOUS run's
    // results file on disk, so a run that dies without ever writing results (#868's exact case) leaves a
    // new queue sitting beside stale results. Diffing those two would announce that every show the run
    // was given had been dropped, about a run that never began work. A warning that cries wolf is worse
    // than no warning, and the dead run is already reported loudly on its own path.
    //
    // So results that PREDATE the queue are not an answer to it, and raise no alarm. Same shape as
    // DetachedRunOutcome.phase, which decides a run produced results by comparing the results file's
    // modification time against the run's start: the app trusts the filesystem's clock over anything a
    // model wrote inside the file.
    static func missingKeys(queuedKeys: [String],
                            answeredKeys: [String],
                            queueGeneratedAt: Date?,
                            resultsModifiedAt: Date?) -> [String] {
        // We cannot know what was asked, or what answered, so we must not claim anything was dropped.
        guard let queueGeneratedAt, let resultsModifiedAt else { return [] }
        guard resultsModifiedAt >= queueGeneratedAt else { return [] }

        let answered = Set(answeredKeys)
        var seen = Set<String>()
        // An answer for a show that was never queued is a DIFFERENT failure (Outcome.unmatchedKeys) and
        // must not cancel out one that genuinely went missing, so this only ever subtracts.
        return queuedKeys.filter { answered.contains($0) ? false : seen.insert($0).inserted }
    }
}
