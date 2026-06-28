import Foundation

// Phase 2.5 (#393): recover a salutation-free body from a legacy draft that embeds the greeting
// inline ("Hi Emma, I photograph..."). The app now owns the greeting at send (one per recipient via
// Salutation.greeting(for:)), so a stored body must start at the first real sentence. This strip is
// deliberately CONSERVATIVE: it removes a leading "Hi/Hello/Hey <name>[,!]" ONLY when the token looks
// like a name; if the grammar matches but the token is not name-like, it leaves the copy untouched
// and flags it for Dan rather than risk corrupting real content. Idempotent, so it is safe to re-run.
enum SalutationStrip {
    struct Result: Equatable {
        var body: String
        var didStrip: Bool
        var needsReview: Bool
    }

    // Generic greetings with no real name; still safe to strip.
    private static let fillers: Set<String> = ["there", "all", "everyone", "team", "folks"]

    // Opener + a 1-to-2 word token + comma or bang + trailing whitespace. The opener needs trailing
    // whitespace, so a word that merely starts with "Hi" ("Highlights") never matches.
    private static let regex = try? NSRegularExpression(pattern: #"^(Hi|Hello|Hey)\s+([^,!\n]{1,40})[,!]\s*"#)

    static func strip(_ body: String) -> Result {
        guard let regex,
              let match = regex.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
              let tokenRange = Range(match.range(at: 2), in: body),
              let fullRange = Range(match.range(at: 0), in: body) else {
            return Result(body: body, didStrip: false, needsReview: false)
        }
        let token = String(body[tokenRange]).trimmingCharacters(in: .whitespaces)
        guard isNameLike(token) else {
            // A greeting-shaped prefix whose token is not a name: don't guess, flag for Dan.
            return Result(body: body, didStrip: false, needsReview: true)
        }
        return Result(body: String(body[fullRange.upperBound...]), didStrip: true, needsReview: false)
    }

    private static func isNameLike(_ token: String) -> Bool {
        let words = token.split(separator: " ").map(String.init)
        guard (1...2).contains(words.count) else { return false }
        if words.count == 1, fillers.contains(words[0].lowercased()) { return true }
        return words.allSatisfy { word in
            guard let first = word.first, first.isUppercase else { return false }
            return word.allSatisfy { $0.isLetter || $0 == "'" || $0 == "-" }
        }
    }
}
