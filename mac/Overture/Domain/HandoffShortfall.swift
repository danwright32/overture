import Foundation

// Which items a detached run was GIVEN and never answered. Shared by every handoff that hands a work-list
// out and reads results back: Prep (#876) and reply-classify (#1018).
//
// A run that returns results for 3 of the 5 items it was queued used to have the 3 ingested and the other
// 2 passed over in silence. They keep their un-processed state, so the next run picks them up again and
// nothing is lost, but Dan was never told. An item the model chokes on every single time would be retried
// forever, silently, and the only symptom is a pill whose count never quite goes down. Self-healing is not
// the same as visible.
//
// The APP wrote the queue, so it already knows what it asked for. This is that comparison, and nothing
// more: it never synthesizes a result. An empty result invented here would CLAIM the run researched an
// item and found nobody, about an item nobody ever looked at (#868). This is why the check is app-side and
// not a script-side guard like scout's: reply and prep results have no per-item failure worth
// synthesizing, whereas scout's per-source results latch a content hash.
enum HandoffShortfall {

    // The queued keys these results never answered, in the order they were queued.
    //
    // Generic over the key, because the two callers key differently and correctly so: Prep by naturalKey
    // (one item per show), reply-classify by (naturalKey, recipientId) (two contacts on one show are two
    // independent items, and a dropped recipient whose show came back for a sibling must still be named).
    //
    // Returns nothing at all unless the results can actually BE an answer to this queue, which is the
    // whole difficulty of the issue. startPrep/startClassify write a fresh queue but leave the PREVIOUS
    // run's results file on disk, so a run that dies without ever writing results (#868's exact case)
    // leaves a new queue sitting beside stale results. Diffing those two would announce that every item
    // the run was given had been dropped, about a run that never began work. A warning that cries wolf is
    // worse than no warning, and the dead run is already reported loudly on its own path.
    //
    // So results that PREDATE the queue are not an answer to it, and raise no alarm. Same shape as
    // DetachedRunOutcome.phase, which decides a run produced results by comparing the results file's
    // modification time against the run's start: the app trusts the filesystem's clock over anything a
    // model wrote inside the file.
    static func missingKeys<Key: Hashable>(queuedKeys: [Key],
                                           answeredKeys: [Key],
                                           queueGeneratedAt: Date?,
                                           resultsModifiedAt: Date?) -> [Key] {
        // We cannot know what was asked, or what answered, so we must not claim anything was dropped.
        guard let queueGeneratedAt, let resultsModifiedAt else { return [] }
        guard resultsModifiedAt >= queueGeneratedAt else { return [] }

        let answered = Set(answeredKeys)
        var seen = Set<Key>()
        // An answer for an item that was never queued is a DIFFERENT failure (Outcome.unmatchedKeys) and
        // must not cancel out one that genuinely went missing, so this only ever subtracts.
        return queuedKeys.filter { answered.contains($0) ? false : seen.insert($0).inserted }
    }

    // The one sentence a shortfall says to Dan, shared by every handoff that can come back short (Prep
    // #876, reply-classify #1018) so the two cannot word the same promise two ways. The promise is a real
    // one, not a reassurance: an un-answered item is re-queued by its builder next run, so "they'll be
    // retried" states what the app will actually do.
    static func retryNote(count: Int) -> String {
        "\(count) didn't come back, they'll be retried"
    }
}
