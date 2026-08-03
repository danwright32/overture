import Foundation

// #1699: what ONE card can honestly say about the curtain time of a run that plays several nights.
//
// A multi-night run collapses to a single card showing a date range ("Jul 23 to 25"), so any time printed
// beside that range is a claim about EVERY night of the run, not about the opening one. Reading the time
// off the representative night would state something true of one night and unverified for the rest, which
// is the shape of defect #1699's own comment warns about: a line that looks like information and is
// actually a guess.
//
// Dan's rule (2026-08-02, choosing from the rendered options): all nights agreeing states the time;
// nights that differ say "Times vary"; a run nobody published a time for says nothing at all and keeps
// reading exactly like today's card. That last case is the majority and is deliberately NOT folded into
// "varies", because "the source never said" and "the nights differ" are different facts and only one of
// them is about the show.
enum RunStartTimes: Equatable, Sendable {
    case none                 // no night published a time; the card says nothing, as it does today
    case same([String])       // every night starts at the same time(s); state them
    case varies               // the nights genuinely differ; say so rather than pick one

    // Decided from EVERY night of the run, in "HH:mm".
    //
    // A night's times are compared as a SET: the same performances listed in a different order are the
    // same schedule, and two feeds ordering a double bill differently must not read as a disagreement.
    // A night with no published time does not agree with a night that has one, so a partly published run
    // varies rather than promoting the one time it happens to know to the whole run.
    static func across(_ nights: [[String]]) -> RunStartTimes {
        guard let first = nights.first else { return .none }
        guard nights.allSatisfy({ Set($0) == Set(first) }) else { return .varies }
        return first.isEmpty ? .none : .same(first)
    }
}
