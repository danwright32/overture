import Foundation

// #1769: what a finished reachability check TELLS Dan.
//
// A check is the app's most expensive action: 77 shows is about 21 minutes, and it runs as up to ten
// concurrent claudes, one per chunk of the work-list. A chunk that dies partway (a crash, an API error, a
// process running out of context, a cancel) leaves the shows it never reached with no answer.
//
// The app already KNEW that. `markProbed` computes exactly this shortfall, because #1594 needs it: a show
// the run never reached must NOT be stamped, or the badge's 90-day trust locks it out of a re-check for
// three months. That is the right behaviour and it self-heals, since the next check picks the show up
// again. But it was invisible: the count went to an NSLog nothing surfaces, and `settleReachabilityProbe`
// discarded the ingest Outcome whole. A run that answered 69 of 77 read to Dan as a clean pass.
//
// Self-healing is not the same as visible: the #876 lesson, one surface further along.
//
// Deliberately NOT solved in the runner. The scout's `results-guard.sh` synthesizes a `not_read` record
// per source it lost, and prep pointedly does not get that treatment (see the comment on
// `quarantine_unreadable_results`, and `HandoffShortfall`'s header): an invented empty prep result would
// CLAIM the run researched a show and found nobody, about a show nobody ever looked at. Worse here, since
// `PrepImporter.answeredKeys` counts every key present in `results`, a synthesized entry would read as an
// answer, get stamped, and reintroduce the exact 90-day lockout #1594 removed. The app wrote the
// work-list, so the app is where the comparison belongs.
enum ReachabilityRunSummary {

    // Nothing to report reads as nothing at all, never an empty "Reachability:". This slot is "does
    // something need me", and an alert that fires on an ordinary run is one Dan learns to scroll past (L36).
    static func attentionMessage(requested: Int, answered: Int,
                                 outcome: PrepImporter.Outcome?,
                                 stampSaveFailed: Bool = false,
                                 ledgerSaveFailed: Bool = false,
                                 stampSaveGaveUp: Bool = false) -> String? {
        var notes: [String] = []
        if let note = shortfallNote(requested: requested, answered: answered) { notes.append(note) }
        // #1677 and #1676: the answers came back and the RECORD of them did not save. Said before the
        // shortfall's siblings because it is the only note here about work Dan has already paid for that
        // he is about to pay for again.
        //
        // Both say what it costs him, not what failed inside. "couldn't save" matches the wording Prep
        // already uses for the same class of failure, so the two runs do not describe one problem two ways.
        if stampSaveFailed { notes.append(stampSaveGaveUp ? stampSaveGaveUpNote : stampSaveFailedNote) }
        if ledgerSaveFailed { notes.append(ledgerSaveFailedNote) }
        // The rest of what the run has to say about itself. Prep's own sentences, reused rather than
        // reworded, because a check shares the runner, the results file and the Outcome with it: a second
        // set of near-identical notes here is how the two would drift. The one it opts out of is the
        // shortfall retry note, replaced by the sentence above for the reason given there.
        if let outcome { notes += PrepRunSummary.concernNotes(for: outcome, includeRetryNote: false) }
        guard !notes.isEmpty else { return nil }
        return "Reachability: " + notes.joined(separator: " · ")
    }

    // #1677: the stamp did not commit, so nothing records that these lookups happened. Names the
    // consequence (it will be offered again) rather than the mechanism, and says the run is not finished,
    // because it genuinely is not: the marker is held and the settle retries.
    static let stampSaveFailedNote =
        "couldn't save what this check found, so it isn't finished and those shows may be checked again"

    // The same failure, after the last allowed attempt. It must NOT keep saying "isn't finished", because
    // by now Overture has stopped trying and nothing further will happen on its own.
    static let stampSaveGaveUpNote =
        "still couldn't save what this check found, so it has stopped trying and those shows will be checked again"

    // #1676: the ledger is what lets another show by the same producer reuse this answer instead of buying
    // its own. Without it that saving is lost, which is a different cost from the stamp's.
    static let ledgerSaveFailedNote =
        "couldn't save the producer answers, so other shows by them won't reuse this one"

    // The shows the check was given and never answered.
    //
    // It says "still unchecked" rather than Prep's "they'll be retried", and the difference is the whole
    // reason this sentence exists instead of borrowing that one. A Prep run's promise is real, because
    // PrepQueueBuilder re-queues an undrafted prospect on its own. NOTHING re-checks reachability by
    // itself: Dan has to select those dates and run it again. Telling him a 21-minute run he paid for will
    // pick itself up would be a promise the app does not keep, which is the class of defect L21 is about.
    //
    // Never negative: a results file carrying MORE answers than were asked for is a different failure with
    // its own note (`unmatchedKeys`) and must not read as a shortfall.
    //
    // Written as three whole sentences rather than one assembled from five interpolated pieces, because
    // `docs/copy-inventory.md` is generated from these literals and the assembled version landed in it as
    // " never got an answer and " plus " still unchecked": two fragments nobody can cold-read. Three
    // near-complete lines in the inventory is worth the small repetition here.
    private static func shortfallNote(requested: Int, answered: Int) -> String? {
        let unanswered = max(0, requested - answered)
        guard unanswered > 0 else { return nil }
        if requested == 1 { return "the show you checked never got an answer and is still unchecked" }
        if unanswered == 1 { return "1 of \(requested) shows never got an answer and is still unchecked" }
        return "\(unanswered) of \(requested) shows never got an answer and are still unchecked"
    }
}

// What one settled check was asked to answer, and what it actually answered.
//
// Returned by `settleReachabilityProbe` in place of the bare Bool it used to hand back, so the count that
// only ever reached a log line now reaches the caller that can put it on screen.
//
// `requested` and `answered` come from the marker against the results file, never from the ingest Outcome:
// `PrepImporter.consumeIfNew` refuses a results file it has already read, so on a re-settle (a relaunch
// after the ingest but before the marker cleared) there is no Outcome at all, and the shortfall would
// silently report a partial run as complete.
struct ReachabilityRunReport: Equatable, Sendable {
    let requested: Int
    let answered: Int
    let outcome: PrepImporter.Outcome?
    // #1677: the stamp recording WHICH shows were answered did not commit. Until it does, those lookups
    // are unrecorded and Overture will offer to pay for them again.
    var stampSaveFailed: Bool = false
    // #1676: the organisation ledger, which is what lets a sibling show reuse this answer instead of
    // buying its own, did not commit.
    var ledgerSaveFailed: Bool = false
    // #1677: the stamp failed on the LAST allowed attempt, so the run has been released rather than kept
    // for another try. A different sentence, because the two say different things about what happens next.
    var stampSaveGaveUp: Bool = false

    var unanswered: Int { max(0, requested - answered) }

    var attentionMessage: String? {
        ReachabilityRunSummary.attentionMessage(requested: requested, answered: answered, outcome: outcome,
                                                stampSaveFailed: stampSaveFailed,
                                                ledgerSaveFailed: ledgerSaveFailed,
                                                stampSaveGaveUp: stampSaveGaveUp)
    }
}
