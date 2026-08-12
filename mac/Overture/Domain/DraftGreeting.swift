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

    // A word that opens a greeting without naming anyone, so "Hi all," is a good way to write to
    // several people rather than a name that reaches the wrong ones.
    private static let fillers: Set<String> = ["there", "all", "everyone", "team", "folks"]

    private static let openers = "hi|hello|hey|dear|good morning|good afternoon|good evening"

    // The `Attn: <name>, <role>` block a shared-inbox pitch opens with (#610), plus the blank line
    // under it. Written by the drafter now rather than composed at send, so it sits INSIDE the body
    // and every question below has to see past it first.
    private static let attnPattern = #"^\s*Attn:[^\n]*\n\s*"#

    private static var greetingPattern: String {
        #"^\s*("# + openers + #")\b[^,!\n]{0,40}([,!]|\n)"#
    }

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
    static func namesSomeone(_ body: String?) -> Bool {
        guard let body, !body.isEmpty else { return false }
        let text = withoutAttnBlock(body)
        guard let range = text.range(of: namedPattern, options: [.regularExpression, .caseInsensitive]),
              range.lowerBound == text.startIndex || text[..<range.lowerBound].allSatisfy(\.isWhitespace)
        else { return false }
        return !isFiller(namedToken(in: String(text[range])))
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

    private static func greetingRange(in body: String) -> Range<String.Index>? {
        body.range(of: greetingPattern, options: [.regularExpression, .caseInsensitive])
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

    private static func isFiller(_ token: String) -> Bool {
        let words = token.split(separator: " ").map(String.init)
        return words.count == 1 && fillers.contains(words[0].lowercased())
    }
}
