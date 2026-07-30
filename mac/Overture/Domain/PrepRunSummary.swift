import Foundation

// What a finished Prep run TELLS Dan, derived purely from its outcome.
//
// Extracted from RootView.ingestPrep (#876). It lived inside the SwiftUI body, which is precisely the
// shape #863 warns about: a rule computed in a view is a rule no test can reach, and two of those have
// already drifted here under a green suite. The sentences Dan actually reads are worth testing, so they
// live where a test can read them too.
enum PrepRunSummary {

    // In the order Dan should hear them: what he GOT, then what he KEPT, then what went wrong. A run's
    // good news first, so a summary is not read as a failure when it mostly worked.
    static func notes(for outcome: PrepImporter.Outcome) -> [String] {
        routineNotes(for: outcome) + concernNotes(for: outcome)
    }

    // The good-news tally: nothing for Dan to act on, and already visible in the queue itself (a drafted
    // show reads as drafted there too). Split out so a "does something need me" slot (the toolbar status
    // line) can drop this half and keep only concernNotes below.
    private static func routineNotes(for outcome: PrepImporter.Outcome) -> [String] {
        var notes: [String] = []
        if outcome.drafted > 0 { notes.append("\(outcome.drafted) drafted") }
        if outcome.skippedEdited > 0 { notes.append("\(outcome.skippedEdited) kept your edits") }
        return notes
    }

    // What the run is telling him went differently than it should have.
    //
    // #1769: a reachability check shares this runner, this results file and this Outcome, so it shares
    // these sentences too rather than growing a second near-identical set that would drift. It opts OUT of
    // one of them: `includeRetryNote`. The shortfall sentence below promises an automatic retry, which is
    // TRUE for a Prep run (PrepQueueBuilder re-queues an undrafted prospect) and FALSE for a check
    // (nothing re-checks reachability by itself; Dan has to pick those dates again). Same fact, different
    // promise, so the check states it its own way in ReachabilityRunSummary and suppresses this one.
    static func concernNotes(for outcome: PrepImporter.Outcome, includeRetryNote: Bool = true) -> [String] {
        var notes: [String] = []
        // #1721: a run that reached the web far more than expected. Said in LOOKUPS and shows, never in
        // dollars: Dan is on a Max plan and a dollar figure there is both meaningless and alarming.
        //
        // Speaks ONLY when the count is complete AND over the allowance. An incomplete count makes no
        // claim in either direction, because a partial figure cannot show a run was fine and must not be
        // reported as its total. Silence on an ordinary run is the point: his measured normal is 5 to 9
        // lookups per show against a cap of 15, and an alert that fires on a routine run gets ignored
        // (L36).
        if let web = outcome.webCalls, web.recorded, web.overCap == true, let total = web.total {
            let shows = web.items == 1 ? "1 show" : "\(web.items) shows"
            notes.append("\(total) web lookups for \(shows), more than expected")
        }
        if !outcome.unmatchedKeys.isEmpty { notes.append("\(outcome.unmatchedKeys.count) didn't match") }
        // #876: shows the run was GIVEN and never answered. Left silent, they sit in "ready to prep" run
        // after run with no explanation, and a show the model chokes on every time is retried forever
        // with no symptom but a Prep count that never quite goes down.
        //
        // The promise is a real one, not a reassurance: an un-drafted prospect is re-queued by
        // PrepQueueBuilder, so "they'll be retried" states what the app will actually do next.
        if includeRetryNote, !outcome.missingKeys.isEmpty {
            notes.append(HandoffShortfall.retryNote(count: outcome.missingKeys.count))
        }
        if outcome.saveFailed { notes.append("couldn't save, try again") }
        // #754: the performer matcher ran against missing or unreadable reference data, so a past client
        // may have read as a cold lead. Silent here means invisible forever.
        if let matchDataWarning = outcome.matchDataWarning { notes.append(matchDataWarning) }
        return notes
    }

    // The two facts auditing the voice guidance file afterwards can add, shared by both callers below so
    // the two sentences exist in exactly one place each.
    private static func voiceGuidanceNotes(voiceGuidanceLeaked: Bool, guidanceNotesRestored: Bool) -> [String] {
        var notes: [String] = []
        // #249: the distiller put a real name into the voice guidance, and that section is quarantined
        // so it can never feed a future draft. Dan has to know it happened.
        if voiceGuidanceLeaked { notes.append("voice guidance leaked a name, quarantined") }
        // #251: the run altered or dropped Dan's hand-written notes and they were restored from the
        // pre-run backup.
        if guidanceNotesRestored { notes.append("restored your guidance notes") }
        return notes
    }

    // #885: the rest of it. #876 extracted `notes(for:)` and left two more conditional notes, the
    // "Prep: " prefix and the join in RootView's body, so a test of this type could pass while the
    // sentence Dan actually reads was assembled somewhere it could not see.
    //
    // The two extra facts are not part of the run's Outcome (they come from auditing the voice guidance
    // file afterwards), so they are passed in rather than reached for.
    static func notes(for outcome: PrepImporter.Outcome,
                      voiceGuidanceLeaked: Bool, guidanceNotesRestored: Bool) -> [String] {
        self.notes(for: outcome) + voiceGuidanceNotes(voiceGuidanceLeaked: voiceGuidanceLeaked,
                                                       guidanceNotesRestored: guidanceNotesRestored)
    }

    // Dan (2026-07-18): what belongs in the toolbar's shared status slot, which also carries an unattended scout's
    // warning. That slot is for "does something need me", not a running tally, so this drops
    // routineNotes ("N drafted", "N kept your edits": already visible in the queue, nothing to act on)
    // and keeps only concernNotes plus the two voice-guidance facts, every one of them the run telling
    // Dan something didn't go as expected. A run with nothing to report says nothing at all, rather than
    // showing an empty "Prep:" with a blank after it.
    static func attentionMessage(for outcome: PrepImporter.Outcome,
                                 voiceGuidanceLeaked: Bool, guidanceNotesRestored: Bool) -> String? {
        let notes = concernNotes(for: outcome)
            + voiceGuidanceNotes(voiceGuidanceLeaked: voiceGuidanceLeaked,
                                 guidanceNotesRestored: guidanceNotesRestored)
        guard !notes.isEmpty else { return nil }
        return "Prep: " + notes.joined(separator: " · ")
    }
}
