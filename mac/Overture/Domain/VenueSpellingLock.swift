import Foundation

// #1848: one page, read on two days, naming its own room two ways.
//
// THE CASE, measured 2026-07-29 for #1761. One source page named its room "Jalopy Theatre" the first
// time and "Jalopy Theater" six days later, and the same page produced "Roulette" one day and "Roulette
// Intermedium" another. Nothing about the page changed: the reading step is a prompt rather than code,
// so it gives a different answer on a different day, and that is permanent variance (L27).
//
// WHY IT COSTS SOMETHING. The venue is one of the natural key's three fields, so a second spelling is a
// second key, a second card, a second paid contact lookup and a place in the queue, all before #1761's
// launch merge sweeps it up. 6 of the 25 duplicate rows that measurement found arrived in a single day's
// scout, so this generates work continuously. Making the answer stable is cheaper than merging it after.
//
// WHAT THIS DOES. It converts a judgement into a LOOKUP, which is what the issue asks for: when a source
// sends a room spelled one slip away from a spelling the SAME source has already used, the stored
// spelling stands. Nothing is guessed and nothing new is invented; the only values it can produce are
// ones that source has already published.
//
// WHAT IT DELIBERATELY DOES NOT COVER, said out loud rather than left to be discovered (L93). "Roulette"
// against "Roulette Intermedium" is the other half of the live evidence and is NOT locked here: a
// spelling with an extra word is how a building names a SECOND ROOM ("Jalopy Theatre" and "Jalopy
// Tavern"), so a rule that folded them would merge two real rooms, which is the one direction this
// milestone has refused every time. #4020 owns that question.
//
// SCOPED TO ONE SOURCE, because that is the whole claim: this page has already told Overture how it
// spells its own room. Two different sources spelling a room differently is a different question, and
// the venue fold and the merge passes already answer it.
enum VenueSpellingLock {

    // The spelling to store, given what this source has already used. Returns the incoming value
    // unchanged unless a stored spelling is one slip away from it.
    //
    // ONE SLIP means one character different or two adjacent characters swapped. The swap is not a
    // refinement: the live pair this exists for, "Jalopy Theatre" against "Jalopy Theater", IS a swap,
    // and a plain edit distance scores it as two edits, so a rule without it answers no to the only
    // case measured (see `GroupNameMatch.differsByOneSlipInOneWord`).
    //
    // DETERMINISTIC where more than one stored spelling qualifies: the most used wins, and an exact tie
    // is broken alphabetically. A rule that took whichever row the store happened to return first would
    // give a different answer on different launches for the same data (L343).
    static func locked(_ incoming: String?, spellingsUsedBySource used: [String]) -> String? {
        guard let incoming, !incoming.trimmingCharacters(in: .whitespaces).isEmpty else { return incoming }
        // An exact match needs nothing: the source is spelling it the way it always has.
        guard !used.contains(incoming) else { return incoming }

        var countsBySpelling: [String: Int] = [:]
        for spelling in used where GroupNameMatch.differsByOneSlipInOneWord(spelling, incoming) {
            countsBySpelling[spelling, default: 0] += 1
        }
        let best = countsBySpelling.sorted {
            $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
        }.first
        return best?.key ?? incoming
    }
}
