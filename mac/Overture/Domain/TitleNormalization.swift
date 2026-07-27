import Foundation

// #1590: the title half of the natural key, folded the way VenueNormalization already folds the venue
// half, and deliberately shaped as its mirror: one normalization per key half, both called from
// Prospect.makeNaturalKey, rather than a second ad-hoc fold living inside the key function.
//
// The gap this closes. #1064 and #1498 taught the key that "The Cutting Room" and "The Cutting Room, 44
// East 32nd Street, New York, NY" are one venue. Nothing ever taught it the same about a title, so a
// source that respelled one show minted a whole second card for the same night, and because the two rows
// were first seen on different scout days, RunGrouping (which only ever compares shows inside ONE batch)
// could never see them together. The key is the only thing that joins across days.
//
// LIVE-STORE-CLAIM verified=2026-07-27 measure="new dated prospects; date+venueKey buckets holding >1 row; groups whose titles differ only by punctuation/accent/case"
// Measured on the live store 2026-07-27: of 571 new dated shows, 88 date-and-venue buckets held more than
// one row, and 10 of those groups were ONE show whose titles differed only in the ways folded here:
//   - an accent ("A Summer Soiree" versus "A Summer Soiree" with the acute),
//   - three dots versus a single ellipsis character ("S'Wonderful..." versus "S'Wonderful" + U+2026),
//   - a long dash versus a plain hyphen ("Coming Out - An Evening" versus the em dash spelling),
//   - brackets versus an exclamation mark ("Jalopy Open Mic Every Wednesday!" versus "(Every Wednesday)"),
//   - a stray comma ("Stringband, called by" versus "Stringband called by"),
//   - case ("AUGUST!" versus "August").
// Each duplicate is also a duplicate PAID reachability lookup since milestone 32, so this is not only a
// second glance for Dan.
//
// SCOPE, and why it is only the punctuation class. This fold is a canonical FUNCTION, because it feeds a
// UNIQUE column: it can only fuse two titles that reduce to the same string. It therefore cannot merge one
// show billed two ways ("Fleetwood Mac: Stripped" versus the same plus "(Broadway Sings)"), which is a
// similarity JUDGMENT and lives in SameNightTitleVariantMerge instead. Keeping the two apart is the point:
// nothing that deletes a row should rest on a judgment the key silently made.
enum TitleNormalization {

    // The canonical form used for the KEY. Expects text that has ALREADY been through
    // Prospect.canonicalize (HTML entities decoded, NFC, lowercased, whitespace folded); the caller owns
    // that order, and it matters: stripping punctuation before "&amp;" is decoded would leave the token
    // "amp" behind and split the very rows #25 taught this key to join.
    static func normalizeForKey(_ canonicalized: String) -> String {
        let folded = stripPunctuation(foldAccents(canonicalized))
        // A title made only of punctuation folds to nothing. Falling back to its own canonical text keeps
        // two such shows distinct; an empty string would key every one of them onto a single row.
        return folded.isEmpty ? canonicalized : folded
    }

    // Matches GroupNameMatch's fold, including the fixed locale, so the result never depends on Dan's
    // system settings.
    private static func foldAccents(_ s: String) -> String {
        s.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }

    // Every character that is not a letter, a digit, or whitespace becomes a space, then runs of
    // whitespace collapse. Deliberately Unicode-aware (Character.isLetter, not an a-to-z range): a title
    // in a non-Latin script would otherwise strip to nothing and fall back to its raw text, which is
    // correct but pointlessly gives up the fold for every such show.
    private static func stripPunctuation(_ s: String) -> String {
        let spaced = String(s.map { ch in
            (ch.isLetter || ch.isNumber || ch.isWhitespace) ? ch : " "
        })
        return spaced.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
