import Foundation

// #2453: WHO wrote this row's presenter, and the one rule that reads it.
//
// The field is the target of everything Dan can act on: the producer axes score it, the classifier reads
// it for the genre word, and the contact hunt is aimed at it. Until now it had exactly one writer, the
// scout, so an ordinary re-read could overwrite it blind and nothing was lost that the same page could
// not put back. `ScoutService.apply` did precisely that.
//
// That stops being safe the moment anything else writes the field, and two passes in this milestone are
// about to: #2454 sweeps stored rows for a producer-shaped name, and #2456 pays a model to name the
// organisation behind 278 unanswered (title, venue) pairs. Both write exactly the rows an ordinary scout
// re-read empties, because the boundary guard `ExtractedEventGuard.presenterThatIsNotTheRoom` drains a
// listing that bills its own room, and a Green Room 42 listing does that every night. Written today, an
// answer would be gone by the next run of that source, with no trace it was ever answered, so the next
// batch would select and pay for the same show again.
//
// So the field records where its value came from, and the re-read consults that.
enum PresenterSource: String, Codable, Sendable, CaseIterable {
    // An ordinary listing read. The page is the source of truth for this value, so the next read of the
    // same page owns it, including a read that finds the page now names nobody.
    case scout
    // A deterministic pass over rows already stored (#2454).
    case sweep
    // A batched model answer, paid for once (#2456).
    case aiBatch
    // Dan, by hand.
    case dan

    // The whole question the guard asks. Only the scout's own answer is the scout's to withdraw.
    var survivesAnOrdinaryReRead: Bool {
        switch self {
        case .scout:                    return false
        case .sweep, .aiBatch, .dan:    return true
        }
    }
}

enum PresenterProvenance {
    // May an ordinary scout re-read that names nobody empty this row's presenter?
    //
    // WHAT AN UNSTAMPED ROW MEANS, and why that direction is the safe one. Every presenter in the store
    // predates this field, and every one of them was written by the scout: `ScoutService` was the only
    // writer the field has ever had (`RoomPresenterSweep` only ever cleared it). So an absent stamp is
    // read as `scout`, which is what those rows measurably are. That keeps today's behaviour for every
    // existing row rather than changing it silently, and it leaves the room-name corrections still able
    // to reach them. The other direction would have frozen several hundred unreviewed presenters, room
    // names among them, against the very passes that exist to fix them.
    //
    // An UNREADABLE stamp is the opposite case and is deliberately not folded into it: something took the
    // trouble to record a provenance this build cannot name. The two mistakes are not symmetric. Keeping a
    // presenter this build does not understand costs a stale name on one row; erasing it destroys an
    // answer nothing can reconstruct (L5), so an unreadable stamp fails in the keeping direction.
    static func survivesAnOrdinaryReRead(presenter: String?, storedSource: String?) -> Bool {
        // A blank name is nothing to protect, whatever it is stamped with. Whitespace counts as blank for
        // the same reason it does in OrganiserNaming: the extraction boundary writes an empty string
        // rather than nil in places, so a nil-only test would miss the commonest row in this class.
        guard !OrganiserNaming.onlyTheActIsNamed(presenter: presenter) else { return false }
        let raw = (storedSource ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return false }                        // unstamped: written by the scout
        guard let known = PresenterSource(rawValue: raw) else { return true }   // stamped, just not by a name this build knows
        return known.survivesAnOrdinaryReRead
    }
}
