import Foundation

// #1663: which source's genre a row keeps when two of them disagree.
//
// `ScoutExtractIngest` loops per source and calls `ScoutService.apply` once each, so with two sources the
// second one to run used to win outright. The provenance three lines away is a union, with a comment
// explaining why a replace there would be wrong; the classification was a replace with no rule at all.
//
// The distinction that resolves it is NOT stored-versus-incoming. `apply` also runs for the SAME source on
// every scout, so "keep what is stored" would be deterministic and wrong: a venue that fixes a bad title on
// its own page could never move the row off the genre that title produced. What matters is whether this is
// a source correcting ITSELF or a different source disagreeing, and a row cannot tell those apart without
// remembering who decided. That is why `Prospect.disciplineGenreSourceKey` exists: the recorded decider is
// not an alternative to a precedence rule, it is what makes one expressible.
//
// The rule is monotone: a row moves from unread to read and never oscillates between two read genres. That
// matters beyond tidiness, because a genre picks the GEOGRAPHIC rule (`Discipline.staysInTheBoroughs`), so
// a genre that flips run to run is a show that appears and disappears from the queue run to run.
enum GenrePrecedence {

    // The key a row records for whoever set its genre. Sorted and joined so the same set of sources always
    // produces the same key regardless of the order the run reports them in.
    static func sourceKey(_ sourceIds: [String]) -> String {
        sourceIds.sorted().joined(separator: ",")
    }

    // True when the incoming classification should replace the stored one.
    //
    // `storedKey` empty covers every row written before this shipped, plus rows created by Prep and by the
    // hand-added lead path, none of which recorded a decider. Those take the incoming answer, which is
    // exactly today's behaviour, and get their provenance stamped on the way through so the next run has
    // the fact this rule needs.
    static func takesIncoming(storedDiscipline: String, storedKey: String?,
                              incomingDiscipline: String, incomingKey: String) -> Bool {
        let stored = (storedKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if stored.isEmpty { return true }
        // The same source may always correct itself, including correcting a genre back to unreadable.
        if stored == incomingKey { return true }
        // A different source: it may only fill a blank, never overwrite a genre that was actually read.
        return storedDiscipline == Discipline.other.rawValue
            && incomingDiscipline != Discipline.other.rawValue
    }
}
