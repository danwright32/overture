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
}
