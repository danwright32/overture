import Foundation

// Shared by view-only guard-test suites (MastheadGuardTests, ProspectRowGuardTests, …) that
// assert on the raw source text of a SwiftUI view rather than runtime behavior, for changes
// with no behavioral surface to exercise.
enum SourceGuardHelper {
    // #1993: `mac/` is SEARCHED for, not counted to. This used to climb two levels from the CALLER's
    // own path, which quietly required every caller to sit exactly at `mac/<Target>/File.swift`. The
    // first caller in a subdirectory would have got a wrong path, and a wrong path here does not
    // fail: it returns "" and every `!source.contains(...)` guard standing on it passes, which is
    // dozens of guards silently protecting nothing.
    //
    // `file` is kept because callers pass it through and it is the right thing to name in a failure,
    // but it no longer decides WHERE the source is read from.
    static func source(_ relativeFromMac: String, file: StaticString = #filePath) -> String {
        let url = RepoRoot.mac.appendingPathComponent(relativeFromMac)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    // #2009: the STORED properties declared in a class body, for the guards that ask "is every field
    // accounted for by this rule?". Shared rather than copied: two readings of Swift source would
    // eventually disagree about what counts as stored, and the guard that disagreed quietly would be the
    // one holding a delete path open (L26).
    //
    // A line carrying a brace is a computed property or an accessor, never storage. `@Attribute`-prefixed
    // declarations count, since the macro decorates a stored property.
    static func storedPropertyNames(inClassBody body: String) -> [String] {
        body.components(separatedBy: "\n").compactMap { line in
            let code = line.trimmingCharacters(in: .whitespaces)
            guard !code.contains("{") else { return nil }
            guard let varRange = code.range(of: "var ") else { return nil }
            guard code.hasPrefix("var ") || code.hasPrefix("@Attribute") else { return nil }
            let name = code[varRange.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            return name.isEmpty ? nil : String(name)
        }
    }

    // #2106: the text between two markers, for scoping a guard to a region that is not brace-delimited.
    // The runners' heartbeat is `( while :; do … done ) &`, so its body runs from the loop header to the
    // loop's own terminator, and that is the region a guard about "what the heartbeat does each tick"
    // actually means. The alternative in use was a fixed character count after the header, which is a
    // proxy for the region rather than the region: it left 34 characters of headroom in prep-run.sh, so
    // the next edit inside the loop failed the guard while the wiring it protects was untouched (L63).
    // Returns nil if either marker is missing or they appear in the wrong order.
    static func between(_ start: String, and end: String, in source: String) -> String? {
        guard let startRange = source.range(of: start),
              let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex)
        else { return nil }
        return String(source[startRange.upperBound..<endRange.lowerBound])
    }

    // #2417: the balanced-brace body of a FUNCTION found by name, for a guard whose claim is about what
    // that function does rather than about the parameters it happens to take today.
    //
    // `propertyBody` needs its marker to run all the way to the opening brace, so a guard using it on a
    // function is pinned to that function's whole signature AS WRITTEN. Adding a parameter, renaming one,
    // or merely re-wrapping the signature across two lines then turns the guard red for formatting while
    // the rule it exists for is untouched, and a guard that goes red for the wrong reason teaches the
    // next person to edit it until it is quiet (L103, #2543). Five guards over two functions did exactly
    // that when #2417 widened `prospectRow` and `dateSection`.
    //
    // Finds the DECLARATION (`func <name>(`, which no call site can look like), walks the parameter list
    // by paren depth so a brace inside it cannot be mistaken for the body's, then balances from the
    // opening brace. Returns nil if the function is absent or its body never balances, so a name that
    // has gone stale reads as missing rather than as an empty body every `contains` is false against.
    static func bodyOfFunction(named name: String, in source: String) -> String? {
        guard let declaration = source.range(of: "func \(name)(") else { return nil }
        var index = source.index(before: declaration.upperBound)   // the "(" itself
        var parens = 0
        while index < source.endIndex {
            let char = source[index]
            if char == "(" { parens += 1 }
            if char == ")" {
                parens -= 1
                if parens == 0 { break }
            }
            index = source.index(after: index)
        }
        guard parens == 0, index < source.endIndex else { return nil }
        guard let brace = source.range(of: "{", range: index..<source.endIndex) else { return nil }
        return propertyBody(String(source[declaration.lowerBound..<brace.upperBound]), in: source)
    }

    // Returns the balanced-brace body of the property/computed-var declaration whose header line
    // ends in the given open-brace marker (e.g. "private var masthead: some View {"), scanning
    // character-by-character from the marker's own opening brace until depth returns to zero
    // (#569). Lets a guard scope its check to ONE view's own body instead of the whole file, so a
    // coincidental match elsewhere in a large file (QueueView.swift is 700+ lines) can't produce a
    // false positive, and a change hidden inside that one property can't slip past undetected.
    // Returns nil if the marker isn't found or its close brace is unbalanced.
    static func propertyBody(_ marker: String, in source: String) -> String? {
        guard let markerRange = source.range(of: marker) else { return nil }
        var depth = 1
        let bodyStart = markerRange.upperBound
        var index = bodyStart
        while index < source.endIndex {
            let char = source[index]
            if char == "{" { depth += 1 }
            if char == "}" {
                depth -= 1
                if depth == 0 { return String(source[bodyStart..<index]) }
            }
            index = source.index(after: index)
        }
        return nil
    }

    // #2543: does this source contain that CODE, whatever layout it happens to be written in?
    //
    // A guard that pins the exact rendering of the code it watches fails the first time that code is
    // legitimately reformatted, and says nothing about whether the rule it exists for still holds (L103).
    // #1900 hit it for real: the masthead guard pinned a call as one exact two-line rendering, so adding
    // a third argument re-wrapped it and turned the guard red for formatting.
    //
    // The corrosive half is not the red one. A guard that goes red for the wrong reason teaches the next
    // person to edit it until it is quiet, which is how a guard becomes decoration. And a NEGATIVE
    // assertion pinned to a rendering ("this swallowing catch must not come back") fails the other way:
    // reformat the offending code and the guard passes with the defect present.
    //
    // Collapses every run of whitespace, in both the source and the needle, so what is compared is the
    // sequence of tokens. It cannot see indentation, line breaks, or how a call is wrapped, which is the
    // point: none of those is ever the rule.
    //
    // COMMENTS ARE STRIPPED FIRST, and that is not a nicety. The first conversion of a pinned guard to
    // this helper immediately tripped on `// #1601: this used to be an inline `catch { return false }``,
    // a comment recording the very code the guard forbids. Prose about a rule is where a rule is most
    // often written down, so a code matcher that reads comments is a code matcher that fires on its own
    // documentation (L103).
    static func normalizedCode(_ source: String) -> String {
        SwiftSource.scannableLines(in: source, skipping: [])
            .map(\.code)
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    // The needle is normalised as WRITTEN, never through the comment stripper: a needle is a fragment,
    // not a file, and running it through a line-based scanner would drop a fragment that happens to open
    // with a slash.
    static func containsCode(_ needle: String, in source: String) -> Bool {
        normalizedCode(source).contains(needle.split(whereSeparator: \.isWhitespace).joined(separator: " "))
    }
}
