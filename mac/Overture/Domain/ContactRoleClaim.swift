import Foundation

// #3078. Whether a contact's `role` is a phrase the cited page carries, or the run's own summary of it.
//
// `PrepContact.role` is unbounded free text and the app derives nothing from it, deliberately. What
// nothing asked was whether the word the run chose appears on the page it cited, so a paraphrase reached
// the card with the same authority as a quote. The measured case, 2026-08-17 (identities redacted, L155):
// a run recorded `role: "Playwright"` for a performer whose cited page describes them as "an actor and
// writer" and contains the word "playwright" exactly once, inside the NAME OF A THEATRE in an unrelated
// regional credit.
//
// A DECLARATION, NOT A MEASUREMENT, and that is #3078's own open question answered by #2269 closing.
// Every `WebFetch` result the run receives is PROSE written by a small model against the page, so the run
// never holds the page in bytes or markdown and there is nothing at ingest to check a role against.
// Measuring it needs a fetch this app performs itself, which #2269 records as its own proposal with its
// own cost. So the run says which it is, and the card stops presenting a characterisation as a quote
// (L192: a value INFERRED from content must never be presented as the recorded fact it stands in for).
enum ContactRoleClaim {

    // TRUE is the unremarkable value and ABSENT means nobody said, which is every contact written before
    // this field and every run that has not adopted it. Absence may never read as a characterisation:
    // that would mark 270 of the 447 contacts in the archives at once, on the strength of a field none of
    // them was ever asked for (L98, L128).
    //
    // A declaration about a role that is not there claims nothing, so it marks nothing: otherwise the
    // note would land on a line with no role on it.
    static func isCharacterisation(roleQuoted: Bool?, role: String?) -> Bool {
        guard roleQuoted == false else { return false }
        return !(role ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// The one sentence, beside the rule that produces it so it reaches `docs/copy-inventory.md` and is read
// cold. It names WHOSE WORDS the role is rather than saying a field is unset, because whose words it is
// is the whole of what Dan needs in order to weigh it.
enum ContactRoleCopy {
    static let characterisationNote = "Overture's words, not the page's"
}
