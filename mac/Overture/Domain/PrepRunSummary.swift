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
        var notes: [String] = []
        if outcome.drafted > 0 { notes.append("\(outcome.drafted) drafted") }
        if outcome.skippedEdited > 0 { notes.append("\(outcome.skippedEdited) kept your edits") }
        if !outcome.unmatchedKeys.isEmpty { notes.append("\(outcome.unmatchedKeys.count) didn't match") }
        // #876: shows the run was GIVEN and never answered. Left silent, they sit in "ready to prep" run
        // after run with no explanation, and a show the model chokes on every time is retried forever
        // with no symptom but a Prep count that never quite goes down.
        //
        // The promise is a real one, not a reassurance: an un-drafted prospect is re-queued by
        // PrepQueueBuilder, so "they'll be retried" states what the app will actually do next.
        if !outcome.missingKeys.isEmpty {
            notes.append("\(outcome.missingKeys.count) didn't come back, they'll be retried")
        }
        if outcome.saveFailed { notes.append("couldn't save, try again") }
        // #754: the performer matcher ran against missing or unreadable reference data, so a past client
        // may have read as a cold lead. Silent here means invisible forever.
        if let matchDataWarning = outcome.matchDataWarning { notes.append(matchDataWarning) }
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
        var notes = self.notes(for: outcome)
        // #249: the distiller put a real name into the voice guidance, and that section is quarantined
        // so it can never feed a future draft. Dan has to know it happened.
        if voiceGuidanceLeaked { notes.append("voice guidance leaked a name, quarantined") }
        // #251: the run altered or dropped Dan's hand-written notes and they were restored from the
        // pre-run backup.
        if guidanceNotesRestored { notes.append("restored your guidance notes") }
        return notes
    }

    // The whole line, or nothing at all. A run with nothing to report says nothing rather than showing
    // an empty "Prep:" with a blank after it.
    static func statusMessage(for outcome: PrepImporter.Outcome,
                              voiceGuidanceLeaked: Bool, guidanceNotesRestored: Bool) -> String? {
        let notes = notes(for: outcome, voiceGuidanceLeaked: voiceGuidanceLeaked,
                          guidanceNotesRestored: guidanceNotesRestored)
        guard !notes.isEmpty else { return nil }
        return "Prep: " + notes.joined(separator: " · ")
    }
}
