import Foundation

// #4130: this arriving show lands on a night a presenter was ALREADY written to about, in the same
// room, and neither card says so.
//
// THE CASE, measured on the live store 2026-09-21 and re-read from a clone on 2026-09-22. Prospect 344,
// "Morahan Arts End of Year Showcase (6th Annual)", presenter Morahan Arts, is `contacted` and was sent
// on 2026-07-18. The scout then inserted prospect 1561, "Sixth Annual End of Year Showcase", the same
// presenter, the same night (2027-05-23) and the same room, status `new`. Neither card mentions the
// other, so the queue invites a second pitch to a presenter already written to.
//
// WHY NEITHER EXISTING GUARD REACHES IT. `DuplicateContactGuard` compares ADDRESSES, and a freshly
// inserted row has no `Recipient` rows at all until a paid check has been made, so its warning arrives
// only after the money is spent. The title rules cannot reach it either: `isSameNightVariant` (#3330's
// tag) and `isSameShowTitle` (the ingest arms) both refuse this pair, and #4032 deliberately gives up on
// a title that diverges past a subtitle.
//
// THE PRESENTER IS LOAD BEARING, and this is where the issue's own direction had to be corrected before
// anything was built. It asks for "the same night and the same folded venue" with no third test.
// Measured over the 2026-09-22 clone, that rule tags 39 rows, and 36 of them are at The Green Room 42
// and 54 Below, cabaret rooms that run several DIFFERENT acts on one night. A note claiming a duplicate
// on every one of those is noise on the commonest shape in the store (L104). Adding the presenter, who
// is the person actually written to and therefore the whole of the harm, takes it to exactly ONE row:
// 1561, the case the issue is about.
//
// A STATEMENT, NEVER A MERGE, for the reason #901 flags a date clash rather than dropping the show, and
// the reason #3330 tags rather than refuses: a wrong refusal at ingest loses a card that never reached a
// screen, so the failure would be invisible by construction.
//
// ALREADY SENT, never merely drafted. `sentAt` is what "reached the outside world" means here, and the
// sentence it draws says PITCHED. A drafted row has had a contact check paid for but nothing has left
// the Mac, so counting it would make the card claim more than the check measured (L11). Measured on the
// same clone: 48 rows are `contacted` and every one carries a `sentAt`, 34 are `drafted` and none does,
// and including the drafted ones changes the tagged population by nothing at all today.
enum AlreadyPitchedNight {

    // One stored row as this rule reads it.
    struct Stored {
        let key: String
        let presenter: String?
        let performanceDate: String?
        let venue: String?
        let sentAt: Date?
    }

    // The natural key of the stored row that was already pitched for this night, or nil.
    //
    // The FIRST match in the order given, and the caller hands them in a stable order, exactly as
    // `LookalikeOnArrival` does: the tag is a pointer to one row, and what Dan needs is that a pitch
    // already went out for this night and which card carries it.
    static func amongStored(_ stored: [Stored], presenter: String?, performanceDate: String?,
                            venue: String?, excludingKey: String) -> String? {
        guard let performanceDate, !performanceDate.isEmpty else { return nil }
        let who = foldedPresenter(presenter)
        // An unnamed presenter would fold to the empty string and match every other unnamed row, which
        // on this store is 443 rows whose presenter was drained to nil because it WAS the room (#1766).
        guard !who.isEmpty else { return nil }
        let room = foldedVenue(venue)
        return stored.first { candidate in
            candidate.key != excludingKey
                && candidate.sentAt != nil
                && candidate.performanceDate == performanceDate
                && foldedVenue(candidate.venue) == room
                && foldedPresenter(candidate.presenter) == who
        }?.key
    }

    // EXACT folded equality, not `GroupNameMatch.isConfident`, which accepts token containment. The
    // sentence this draws names the presenter and says it was already pitched, so the two rows have to
    // be about the SAME presenter rather than one whose name contains the other's ("Morahan Arts"
    // against "Morahan Arts Center" is two organisations and one of them has not been written to).
    // The fold itself is `GroupNameMatch`'s, shared rather than spelled again (L370), so accents,
    // punctuation and casing are handled exactly as every other name comparison in the app handles them.
    private static func foldedPresenter(_ raw: String?) -> String {
        guard let raw else { return "" }
        return GroupNameMatch.tokens(raw).joined(separator: " ")
    }

    // The same fold the natural key is built through, so two spellings of one room are one room here as
    // well. Read from `VenueNormalization` rather than spelled again (L370).
    private static func foldedVenue(_ raw: String?) -> String {
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return "" }
        return VenueNormalization.normalizeForKey(raw).lowercased()
    }
}
