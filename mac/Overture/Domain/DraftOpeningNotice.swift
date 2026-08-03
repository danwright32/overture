import Foundation

// #2010: the body already opens with its own greeting, and the opening above it carries one too, so the
// email would greet the reader twice.
//
// This NOTICES. It does not rewrite and it does not block, and both halves of that are Dan's rule:
//
//   "I want whatever is in the text box that I see to be what's sent. There should never be any hidden
//    addition that I cannot see in the app"  (2026-08-03)
//
// A launch pass used to rewrite the stored body instead, which is the app editing his words with nothing
// on screen saying so, and it made the result depend on whether he had restarted (L5, L64). Blocking would
// be the same overreach wearing a warning label: now that the opening sits directly above the body, he can
// see both at once and is the right one to judge it.
//
// LIVE-STORE-CLAIM verified=2026-08-03 measure="stored drafts whose body opens with a greeting, and which of them the retired strip pattern matched"
// Measured on the live store: 4 of 9 drafts open with a greeting and the retired pattern matched NONE of
// them, because every one is a bare "Hello," with no name and that pattern required a name after the
// opener. The AI drafter writes these itself, so this is not only about hand-typed text.
enum DraftOpeningNotice {

    // Deliberately WIDER than the strip it replaces, because it only has to be worth reading, never
    // correct enough to act on by itself. It covers the bare "Hello," the old one could not see, and
    // "Dear", which that one did not know about at all.
    //
    // Anchored to the very start and requiring the punctuation, so an ordinary sentence that merely
    // contains a greeting word ("Highlights from the season") cannot trip it: the openers are bounded by
    // a word break, and one of a comma, a bang or a line end has to follow within a short span.
    private static let pattern =
        #"^\s*(hi|hello|hey|dear|good morning|good afternoon|good evening)\b[^,!\n]{0,40}([,!]|\n)"#

    static func bodyRepeatsAGreeting(_ body: String?) -> Bool {
        guard let body, !body.isEmpty else { return false }
        return body.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    // Said once, as a whole sentence, so the inventory carries the words Dan actually reads.
    static let note =
        "This email starts with a greeting and the opening above adds one too, so it will say hello twice."
}
