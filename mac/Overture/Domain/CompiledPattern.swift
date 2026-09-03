import Foundation

// #3432: a regular expression compiled ONCE, held as a static, and reused.
//
// `String.range(of:options:.regularExpression)` and `replacingOccurrences(of:options:.regularExpression)`
// take the pattern as a STRING, so the expression is parsed and compiled on every single invocation.
// That is invisible at the call site and it reads exactly like a constant.
//
// Measured 2026-09-02 with a standalone harness over twelve realistic venue strings, 20,000 calls each
// way through VenueNormalization's four patterns: 9.7us per call the string way against 6.3us through
// compiled statics, a 1.53x difference, with both forms producing identical output on every input.
//
// WHY A SHARED TYPE RATHER THAN A COMPILED STATIC IN EACH FILE. Two files needed this at once, and
// giving each its own `NSRegularExpression` plus its own "does it match" and "replace the matches"
// helpers is two copies of the applying code sharing nothing but the idea (L370). One definition here
// means a call site cannot quietly differ about what a match or a replacement means.
//
// `@unchecked Sendable` is deliberate and narrow. `NSRegularExpression` is documented as immutable once
// created and safe to use from multiple threads, which is the whole reason it can be a shared static;
// the compiler cannot see that, so the conformance is asserted here in one place rather than at every
// declaration.
final class CompiledPattern: @unchecked Sendable {
    private let regex: NSRegularExpression

    // A pattern that fails to compile is a programming error in a literal, not a runtime condition, and
    // it would otherwise turn into "this rule silently never matches" (L536). It is caught here, at
    // first use, rather than being reported as an absence of findings.
    init(_ pattern: String, options: NSRegularExpression.Options = []) {
        guard let compiled = try? NSRegularExpression(pattern: pattern, options: options) else {
            preconditionFailure("CompiledPattern could not compile the literal pattern: \(pattern)")
        }
        regex = compiled
    }

    func matches(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }

    func replacingMatches(in text: String, with template: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}
