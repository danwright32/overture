import Foundation

// #885: what a finished SCOUT tells Dan, derived purely from its outcome.
//
// The sibling of PrepRunSummary, and it should have been written at the same time. #876 extracted the
// Prep half of RootView's summaries and left the scout's own two in the body, where no test can read
// them. Same file, same shape, same risk.
enum ScoutRunSummary {

    // What it FOUND first, then what is new. A zero is left out rather than shown as "0 new": a summary
    // padded with zeroes is a summary Dan learns to skim, and the counts that matter are the non-zero ones.
    //
    // "0 found" is deliberately NOT left out. A scout that found nothing has to say so, or a run that
    // did nothing looks exactly like a run that never happened.
    //
    // #1533 dropped the third part, "N unsure". It counted the classifications the rules called uncertain,
    // which on the live store was three quarters of every run, and it pointed at a badge that has now been
    // retired: a count of something Dan can neither act on nor read anywhere else is noise in a line whose
    // whole job is to be scannable.
    static func summary(for outcome: ScoutService.Outcome) -> String {
        var parts = ["\(outcome.found) found"]
        if outcome.inserted > 0 { parts.append("\(outcome.inserted) new") }
        return parts.joined(separator: " · ")
    }

    // The watched-calendar ingest (#802). "Added" is inserted PLUS updated: a show already in the queue
    // whose details changed is something this run did, and that rule was a bare bit of arithmetic in a
    // view body.
    //
    // The zero case is its own sentence, never "0 from watched calendars": a quiet calendar is the
    // NORMAL state (5 of the 7 sites in the #770 spike, in July) and must not read as a failure.
    static func watchedCalendarSummary(for outcome: ScoutService.Outcome) -> String {
        let added = outcome.inserted + outcome.updated
        return added > 0 ? "\(added) from watched calendars" : "Nothing new on the watched calendars"
    }
}
