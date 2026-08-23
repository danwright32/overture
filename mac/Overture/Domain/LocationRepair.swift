import Foundation
import SwiftData

// #2790: the rows already in the store that hold a location the CURRENT rules would not write.
//
// #2568 and #2566 both changed what `EventLocationFill` will write, and neither reaches a stored row.
// `LocationBackfill` fills a BLANK location and never rewrites one, which is deliberate and right on its
// own terms (a page's own words and anything Dan corrected must survive every launch), so a row holding
// a WRONG location is exactly the row it skips. `ScoutService`'s upsert does rewrite on re-emit, but a
// source whose page bytes are unchanged is skipped entirely, so a listing that has stopped changing, or
// a show already past, is never re-read. Every fix in this area is forward only, which is the same gap
// #1600, #1693 and #1744 each had to close with a launch pass of their own.
//
// THE NARROW RULE THAT MAKES THIS SAFE. A stored location is a candidate only when the shipping
// predicate now REFUSES it. Two things it must never touch: a location the rules still accept, however
// odd it looks, because re-deriving those is a second opinion nobody asked for; and a blank, which is
// `LocationBackfill`'s and always has been, because one row with two passes writing it is a field with
// two homes (L83).
//
// WHAT IT CANNOT DISTINGUISH, said out loud rather than assumed. `Prospect` carries no stamp saying
// where its location came from, so this cannot ask "was this machine written". It is justified by the
// refusal alone: a value the current rules would never write is not one Dan typed either, unless he
// typed a room description into the field, and the live store was checked for that shape before this
// shipped. That is a weaker warrant than a provenance stamp would give, which is why the candidate rule
// is the narrowest one that reaches the defect rather than the widest one that could be defended.
enum LocationRepair {

    // Whether the current rules would refuse to write this exact string as a location.
    //
    // Asked through `EventLocationFill`'s OWN published-location predicate rather than a second
    // judgement written here, so the repair and the ingest cannot disagree about what is acceptable
    // (L16). A blank is never a candidate.
    static func wouldNotBeWritten(location: String?) -> Bool {
        let stored = (location ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // A blank is `LocationBackfill`'s and always has been. This line is NOT load-bearing today and
        // says so rather than reading as protection: `acceptsAsPublishedLocation("")` already answers
        // true, so a blank falls out below anyway, and mutate.sh reports SURVIVED on removing it (L1).
        // It stays because the two rules answer different questions and nothing obliges the published
        // location rule to go on accepting an empty string; if it ever stopped, every blank row in the
        // store would become a candidate for a pass that must never touch one, and one row with two
        // passes writing it is a field with two homes (L83).
        guard !stored.isEmpty else { return false }
        return !EventLocationFill.acceptsAsPublishedLocation(stored)
    }

    static func wouldNotBeWrittenToday(_ p: Prospect) -> Bool {
        wouldNotBeWritten(location: p.location)
    }

    // The launch pass. Returns how many rows it moved, so a caller can report what it actually did.
    //
    // It RE-DERIVES rather than merely clearing, and where re-derivation yields nothing it clears to
    // blank. Clearing is the safe direction and not a loss: an unplaced show is KEPT and flagged (#970),
    // where the wrong place it withdraws was hiding one. Two of the five rows this was written for are
    // hidden right now for a reason that is not true.
    //
    // A room Dan has ANSWERED FOR is skipped outright, before the refusal is even asked. His answer
    // outranks every rule, and re-deriving a row he has already settled would be the pass overruling him
    // on the strength of a predicate about a string he did not write.
    //
    // Idempotent: a row it clears has a blank location, which is no longer a candidate, and
    // `LocationBackfill` then owns it exactly as it owns every other blank. The two passes never write
    // the same row in the same launch, because the candidate rule and the backfill's rule are opposites.
    @discardableResult
    static func run(in context: ModelContext) -> Int {
        guard let rows = try? context.fetch(FetchDescriptor<Prospect>()) else { return 0 }
        let answers = roomAnswers(in: context)
        var moved = 0
        for p in rows where wouldNotBeWrittenToday(p) {
            let roomKey = VenuePlaces.canonicalKey(for: p.venue)
            // Dan's own answer for this room outranks every rule, including this one.
            if let roomKey, answers.contains(roomKey) { continue }
            // The SCOUT's title, for `LocationBackfill`'s reason: the tour-title rule reads a convention
            // the SOURCE writes, and a row Dan has retitled by hand no longer carries it.
            //
            // `published: nil`, because the published value IS the refused one. Passing it back would ask
            // the rules to reconsider the string they have already declined.
            let rederived = EventLocationFill.location(title: p.scoutGroupName ?? p.groupName,
                                                       venue: p.venue,
                                                       published: nil,
                                                       roomAnswer: nil)
            p.location = rederived
            moved += 1
        }
        return moved
    }

    // Dan's own answers, by room identity, read once per pass rather than per row. The same shape
    // `LocationBackfill` uses and for its reason: a fetch inside the loop would pay for the whole table
    // on every stored show.
    private static func roomAnswers(in context: ModelContext) -> Set<String> {
        let answers = (try? context.fetch(FetchDescriptor<VenuePlaceAnswer>())) ?? []
        return Set(answers
            .filter { !$0.location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map(\.venueKey))
    }
}
