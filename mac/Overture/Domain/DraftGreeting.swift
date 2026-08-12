import Foundation

// #2545: the ONE judgment about how an outgoing body opens, in one place because three different
// questions turn on it and they must never disagree:
//
//   - does the body greet at all (if not, the send is held, since nothing composes a greeting on top
//     of it any more and it would go out headless)
//   - does the greeting name a particular person (if so, it may only reach one)
//   - where does the real writing start (RecentOpeners compares openers, so it has to look past both
//     the greeting and the `Attn:` block above it)
//
// The greeting pattern is carried over unchanged from `DraftOpeningNotice`, which asked the same
// question for the opposite reason: it warned that the body greeted as WELL as the appended opening.
// Same judgment, inverted consequence, so keeping the pattern keeps every draft classified as it was.
enum DraftGreeting {

    // copy-inventory:ignore-start  Search terms and regex fragments, not anything Overture says to Dan.
    // Without this the opener alternation is listed in docs/copy-inventory.md as a sentence the app can
    // say, which is exactly the noise that inventory exists to keep out (it is the same reason the draft
    // lint's own search terms are marked).

    // Words that appear in a greeting WITHOUT being somebody's name. They are capitalised at the start
    // of a line by convention, not because they identify a person, so a capitalised word outside this set
    // is what marks a greeting as addressed to someone in particular.
    //
    // Deliberately covers the openings Dan writes as well as the drafter's ("Thanks for the quick reply,",
    // "Many thanks for the note,"), because reading one of those as a NAME would hold a send that is
    // perfectly fine, and a hold he has to override on ordinary wording is how the override stops meaning
    // anything.
    private static let notNames: Set<String> = [
        "hi", "hello", "hey", "dear", "good", "morning", "afternoon", "evening", "greetings",
        "there", "all", "everyone", "team", "folks", "again", "thanks", "thank", "many", "happy", "welcome",
    ]

    private static let openers = "hi|hello|hey|dear|good morning|good afternoon|good evening"

    // The `Attn: <name>, <role>` block a shared-inbox pitch opens with (#610), plus the blank line
    // under it. Written by the drafter now rather than composed at send, so it sits INSIDE the body
    // and every question below has to see past it first.
    private static let attnPattern = #"^\s*Attn:[^\n]*\n\s*"#

    private static var greetingPattern: String {
        #"^\s*("# + openers + #")\b[^,!\n]{0,40}([,!]|\n)"#
    }

    // A greeting that does NOT begin with an opener word, which is the shape Dan writes himself:
    // "Marcus, hello again," or "Morning Emma," or just "Sarah and Tom,". Recognised by SHAPE rather
    // than by vocabulary, because a closed list only ever covers the phrasings somebody thought of, and
    // the first version of this rule refused every one of the above (#2545, Dan's call 2026-08-12).
    //
    // A short FIRST LINE ending in a comma or bang, carrying no sentence-ending punctuation, and followed
    // by a line break. The three constraints together are what stop a real opening sentence matching:
    // "I photograph performing arts in New York, and I saw..." runs on past 40 characters and does not end
    // its line at the comma. Erring toward accepting is deliberate here, since this gate REFUSES a send.
    private static let greetingShapePattern = #"^[^\n.?!]{1,40}[,!]\s*(\n|$)"#

    // An opener followed by at least one word before the punctuation. "Hello," has nothing between
    // the opener and the comma, so it never matches; "Hi Emma," does.
    private static var namedPattern: String {
        #"^\s*("# + openers + #")\s+([^,!\n]{1,40})[,!]"#
    }
    // copy-inventory:ignore-end

    static func opensWithAGreeting(_ body: String?) -> Bool {
        guard let body, !body.isEmpty else { return false }
        return greetingRange(in: withoutAttnBlock(body)) != nil
    }

    // Whether the greeting addresses somebody by name. Nil-safe because both callers hold an optional
    // body, and a body that is absent greets nobody.
    // #2545: judged over BOTH greeting shapes, because the two halves of the rule disagreeing about what
    // a greeting is leaves the hole exactly where Dan's own writing is: "Marcus, hello again," counted as
    // a greeting but not as a NAMED one, so a two-contact show would have sent it to both of them.
    static func namesSomeone(_ body: String?) -> Bool {
        guard let body, !body.isEmpty else { return false }
        let text = withoutAttnBlock(body)
        guard let range = greetingRange(in: text) else { return false }
        let line = String(text[range]).split(separator: "\n").first.map(String.init) ?? ""
        // The opener-word form has its own token rule, which knows "Hi all," is a filler rather than a name.
        if text.range(of: namedPattern, options: [.regularExpression, .caseInsensitive]) != nil {
            return !isFiller(namedToken(in: line))
        }
        return line.split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "-" })
            .contains { word in
                guard let first = word.first, first.isUppercase else { return false }
                return !notNames.contains(word.lowercased())
            }
    }

    // Everything before the first real sentence: the `Attn:` block if there is one, then the greeting.
    // Leaves a body alone when it opens with neither, so it is safe to run over any text.
    static func withoutLeadingOpening(_ body: String) -> String {
        let afterAttn = withoutAttnBlock(body)
        guard let range = greetingRange(in: afterAttn) else { return afterAttn }
        return String(afterAttn[range.upperBound...])
    }

    private static func withoutAttnBlock(_ body: String) -> String {
        guard let range = body.range(of: attnPattern, options: [.regularExpression, .caseInsensitive])
        else { return body }
        return String(body[range.upperBound...])
    }

    // Either shape counts. The opener-word form is tried first because it is the one the drafter is told
    // to write and the one whose extent the strip below needs to know.
    private static func greetingRange(in body: String) -> Range<String.Index>? {
        body.range(of: greetingPattern, options: [.regularExpression, .caseInsensitive])
            ?? body.range(of: greetingShapePattern, options: [.regularExpression, .caseInsensitive])
    }

    // The words between the opener and the punctuation, e.g. "Emma" from "Hi Emma,".
    private static func namedToken(in match: String) -> String {
        let trimmed = match.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let openerRange = trimmed.range(of: #"^("# + openers + #")\s+"#,
                                              options: [.regularExpression, .caseInsensitive])
        else { return "" }
        return String(trimmed[openerRange.upperBound...])
            .trimmingCharacters(in: CharacterSet(charactersIn: ",! "))
    }

    // Judged against `notNames`, the one list of words that appear in a greeting without being a name, so
    // the two branches of `namesSomeone` cannot disagree: "Hello again," reads as naming nobody whichever
    // pattern matched it first. There was briefly a second, smaller list here and that was the bug.
    private static func isFiller(_ token: String) -> Bool {
        let words = token.split(separator: " ").map(String.init)
        return words.count == 1 && notNames.contains(words[0].lowercased())
    }
}
