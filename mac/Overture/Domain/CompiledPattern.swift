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
        // copy-inventory:ignore-start  A developer assertion, never rendered to Dan (#3432)
        //
        // It is marked because the cold read caught it landing in docs/copy-inventory.md as one of the
        // sentences Overture can say to him, which it is not: this is the only preconditionFailure in the
        // whole app, and the inventory is a list of what he READS. AGENTS.md records the same shape
        // happening once before, when a fatalError string added to break the app on purpose was written
        // into that document.
        guard let compiled = try? NSRegularExpression(pattern: pattern, options: options) else {
            preconditionFailure("CompiledPattern could not compile the literal pattern: \(pattern)")
        }
        // copy-inventory:ignore-end
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

    // #3886: one capture group of the first match, or nil.
    //
    // WHY IT LIVES HERE. Without it, a call site that needs a PIECE of a match rather than a yes or no
    // and a replace-all has to build its own `NSRegularExpression`, which is how
    // `GroupNameMatch.stripProgramSubtitle` came to compile a fresh one on every name it normalized, on
    // the scout's per-comparison path, and why `DraftCheck` keeps some of its patterns outside the shared
    // type. Extending the one definition is the alternative to a second hand-rolled copy of the applying
    // code (L370).
    //
    // THREE WAYS THERE IS NO CAPTURE, and all three answer nil rather than "". Nothing matched at all; the
    // index names a group this pattern does not have; or the group is optional and did not participate,
    // which `NSRegularExpression` reports as an NSNotFound range. An empty string would be a real capture
    // to every caller, so a caller substituting one would replace a name with nothing (L215).
    //
    // Index 0 is the whole match, which is what `NSRegularExpression` means by it.
    func firstCaptureGroup(_ index: Int, in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              index < match.numberOfRanges,
              let captured = Range(match.range(at: index), in: text)
        else { return nil }
        return String(text[captured])
    }
}

// #3886: the patterns several files had each spelled out for themselves, and the two readings of them
// that were written over and over.
//
// Sharing the PATTERN alone would not be consolidation: what matters is that the applying code is shared
// too, and it is, because every call here goes through `replacingMatches` above (L370). Written as String
// methods rather than as bare statics because almost every call site is mid-chain
// (`.lowercased().collapsingWhitespaceRuns().trimmingCharacters(...)`), and a form that breaks the chain
// is a form the next person writes `options: .regularExpression` instead of.
extension CompiledPattern {
    static let whitespaceRun = CompiledPattern(#"\s+"#)
    static let htmlTag = CompiledPattern(#"<[^>]+>"#)
    // Only meaningful on already-lowercased text, which is how both call sites use it: a capital letter
    // is outside the class and would be replaced by a space.
    static let nonAlphanumericLowercase = CompiledPattern(#"[^a-z0-9\s]"#)
}

extension String {
    // Every run of whitespace becomes a single space. The caller still does its own trimming, because
    // the two call sites that trim disagree about whether newlines count and that is each one's decision.
    func collapsingWhitespaceRuns() -> String {
        CompiledPattern.whitespaceRun.replacingMatches(in: self, with: " ")
    }

    // Every HTML tag becomes a space, which is what the scrape and email paths mean by stripping markup:
    // a space rather than nothing, so two words either side of a tag do not fuse into one.
    func strippingHTMLTags() -> String {
        CompiledPattern.htmlTag.replacingMatches(in: self, with: " ")
    }
}
