import Foundation

// #986: counting whether a source names WHERE its shows are.
//
// #970's gate reads exactly one thing: the `location` string the extract run reports per event
// (EventPlace.resolve takes location + Discipline and never sees the venue). No location resolves
// .unknown, which is kept and flagged: the safe answer, and also the answer a source gets when the run has
// silently stopped reporting locations. From the queue those two are identical, and that indistinguishability
// is what cost the entire first #970 plan. So each run records how many of a source's shows named a place,
// and whether it had ever placed before it (WatchedSource.lastPlacedCount / hadPlacedBeforeLastRun), which
// is what tells a venue calendar that never places apart from an artist page that has stopped.
//
// #1029: this used to also turn that count into a Dan-facing line in the Sources sheet ("N of M shows say
// where they are..."). Dan did not understand why it mattered ("I do not understand what that matters"), so
// the sentence and its generator were removed. The count itself stays, recorded on every run for #970's
// drift detection; it simply no longer speaks to Dan.
//
// A pure function, never a computation inside the SwiftUI body: a rule computed in a view is a rule no test
// can reach, and two have already drifted here under a green suite (#863, #885).
enum SourcePlacement {

    // #986/#1005: how many of a run's kept shows named WHERE they are. ONE rule, shared by both ingest
    // paths (the native Carnegie sweep and the agent extract run), so neither can drift on what "said
    // where" means. Blank is not a place: the runbook (§3a) asks for the page's words verbatim, and a page
    // rendering an empty location field must not read as one that named somewhere.
    static func placedCount(locations: [String?]) -> Int {
        locations.filter {
            !($0 ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
    }
}
