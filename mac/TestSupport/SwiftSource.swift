import Foundation

// A small Swift lexer, shared by the copy guards (#885's "no copy computed in a view", #915's inventory
// of every sentence the app can say).
//
// Both need the same thing: to know, at every character, whether it is looking at code, a comment or a
// string, and never to confuse the three. Getting that wrong is not a cosmetic failure. A scanner that
// ends a literal at the quote inside `\(venue ?? "Venue TBD")` reads the code after it as prose, and
// yields two mangled half-sentences in place of one real one, in precisely the files that hold the most
// copy. It looks like it worked.
//
// So it lives in one place rather than two, and both callers get every fix.
enum SwiftSource {

    struct Literal: Equatable {
        var text: String        // the literal's contents, interpolations left intact
        var isRaw: Bool         // #"..."#, which in this codebase is always a regex, never a sentence
        var line: Int = 0
        // #3155: the only thing between this literal and the one before it was `+` and whitespace, so
        // the two are one sentence in the running app. A reader of the literals alone cannot tell that,
        // and the copy inventory recorded the halves separately, which put a fragment in front of the
        // cold read and left the sentence Dan actually sees written nowhere.
        //
        // Decided HERE rather than by a caller re-reading the source, because the character positions
        // that make it decidable exist only during the scan: `codeLines` has the literals removed with
        // nothing marking where they were, so a caller holding two literals on one line cannot tell
        // which side of the `+` each sat on.
        var joinedToPrevious: Bool = false
    }

    // Copy that isn't a sentence Overture says to Dan is marked where it lives, not allowlisted in a
    // test file: the outbound email a recipient reads, the RFC822 headers Gmail reads, the AppleScript
    // OmniFocus reads. Marking it at the source keeps the reason next to the words, and lets the
    // inventory PRINT its own exclusions instead of hiding them.
    static let ignoreStart = "copy-inventory:ignore-start"
    static let ignoreEnd = "copy-inventory:ignore-end"

    // MARK: - Public reads

    // What to leave out. The two callers want different sets, and the difference is load-bearing: the
    // #885 guard must NOT honour a marked region, or a `copy-inventory:ignore` comment dropped into a
    // view would quietly buy an exemption from the guard as well as from the list. A marking says "this
    // is not Dan's copy", never "this may be computed wherever you like".
    struct Skips: OptionSet {
        let rawValue: Int
        static let debug = Skips(rawValue: 1 << 0)
        static let previews = Skips(rawValue: 1 << 1)
        static let markedRegions = Skips(rawValue: 1 << 2)
        static let scaffolding: Skips = [.debug, .previews]
        static let all: Skips = [.debug, .previews, .markedRegions]
    }

    static func literals(in source: String, skipping: Skips = .all) -> [Literal] {
        let scan = tokenize(source)
        let skipped = skippedLines(scan, skipping: skipping)
        return scan.literals.filter { !skipped.contains($0.line) }
    }

    // The source as a guard reads it: comments gone, skipped regions blanked, string literals left
    // intact, one entry per line so a caller can still report where it found something.
    static func scannableLines(in source: String, skipping: Skips = .all) -> [(line: Int, code: String)] {
        let scan = tokenize(source)
        let skipped = skippedLines(scan, skipping: skipping)
        return scan.sourceLines.keys.sorted()
            .filter { !skipped.contains($0) }
            .map { (line: $0, code: scan.sourceLines[$0]!) }
    }

    static func ignoredReasons(in source: String) -> [String] {
        tokenize(source).comments.compactMap { comment in
            guard let range = comment.text.range(of: ignoreStart) else { return nil }
            let reason = comment.text[range.upperBound...].trimmingCharacters(in: .whitespaces)
            return reason.isEmpty ? nil : reason
        }
    }

    // #2650: the INVERSE of the skip. The literals inside marked regions whose reason carries a given
    // tag, which is how outbound email (deliberately kept out of the inventory, because the inventory is
    // the app's own voice to Dan) gets a reader of its own.
    //
    // Matched on a leading TAG rather than on the prose after it. The prose is there for a person and is
    // reworded freely; a match on it would quietly stop finding a region the day somebody improved the
    // sentence (L103).
    static func literalsInTaggedRegions(in source: String, tag: String) -> [Literal] {
        let scan = tokenize(source)
        var wanted: Set<Int> = []
        var openedAt: Int?
        var openedTagged = false
        for comment in scan.comments {
            if let range = comment.text.range(of: ignoreStart), openedAt == nil {
                openedAt = comment.line
                let reason = comment.text[range.upperBound...].trimmingCharacters(in: .whitespaces)
                openedTagged = reason.hasPrefix(tag)
            }
            if comment.text.contains(ignoreEnd), let start = openedAt {
                if openedTagged { for line in start...comment.line { wanted.insert(line) } }
                openedAt = nil
                openedTagged = false
            }
        }
        // An unclosed region is NOT collected. `unclosedIgnoreRegion` already makes that state loud, and
        // guessing at where it ends would put the rest of the file into a document about outbound email.
        return scan.literals.filter { wanted.contains($0.line) }
    }

    // Every marked region's reason, with the line it opened on, so a guard can ask whether a region that
    // reads like outbound email actually carries the tag that gives it a reader.
    static func ignoredReasonsWithLines(in source: String) -> [(line: Int, reason: String)] {
        tokenize(source).comments.compactMap { comment in
            guard let range = comment.text.range(of: ignoreStart) else { return nil }
            let reason = comment.text[range.upperBound...].trimmingCharacters(in: .whitespaces)
            return reason.isEmpty ? nil : (line: comment.line, reason: reason)
        }
    }

    // An ignore region opened and never closed silently swallows the rest of a file's copy. That is the
    // exact failure the inventory exists to prevent, so callers can make it loud.
    static func unclosedIgnoreRegion(in source: String) -> Bool {
        let comments = tokenize(source).comments
        let starts = comments.filter { $0.text.contains(ignoreStart) }.count
        let ends = comments.filter { $0.text.contains(ignoreEnd) }.count
        return starts != ends
    }

    // #2671: an ignore region opened while one is ALREADY open, reported by the line it opened on.
    //
    // Nested markers cancel each other. `skippedLines` opens on the first start and closes on the first
    // end it meets, so the inner region's `ignore-end` closes the OUTER region too, and every literal
    // between there and the outer end leaks into a list meant to hold only sentences Overture says to
    // Dan. `unclosedIgnoreRegion` cannot see it: nesting leaves the starts and the ends balanced, which
    // is exactly why this is a separate question rather than a widening of that one.
    //
    // Reported as the LINE rather than as a bare Bool, because the two markers involved are routinely
    // hundreds of lines apart and "this file nests a region somewhere" is not something anybody can act
    // on. Returns the first offending start only: the fix for one is usually the fix for the rest.
    static func nestedIgnoreRegion(in source: String) -> Int? {
        var openedAt: Int?
        for comment in tokenize(source).comments {
            if comment.text.contains(ignoreStart) {
                if openedAt != nil { return comment.line }
                openedAt = comment.line
            }
            if comment.text.contains(ignoreEnd) { openedAt = nil }
        }
        return nil
    }

    // MARK: - Line skipping (DEBUG branches, marked regions)

    private static func skippedLines(_ scan: Scan, skipping: Skips) -> Set<Int> {
        var skipped: Set<Int> = []

        // A marked region, from its opening comment to its closing one.
        if skipping.contains(.markedRegions) {
            var openedAt: Int?
            for comment in scan.comments {
                if comment.text.contains(ignoreStart), openedAt == nil { openedAt = comment.line }
                if comment.text.contains(ignoreEnd), let start = openedAt {
                    for line in start...comment.line { skipped.insert(line) }
                    openedAt = nil
                }
            }
            if let start = openedAt, let last = scan.sourceLines.keys.max() {
                for line in start...max(start, last) { skipped.insert(line) }
            }
        }

        // A #Preview is scaffolding for Xcode's canvas, and its fixtures are invented ("Aurora Strings").
        // Left in, a preview's fake org name collides with the real one elsewhere and reports a
        // duplicate that isn't one, which spoils the one section of the inventory that must stay worth
        // reading.
        if skipping.contains(.previews) {
            var previewDepth = 0
            var inPreview = false
            for line in scan.codeLines.keys.sorted() {
                let text = scan.codeLines[line]!
                if !inPreview, text.trimmingCharacters(in: .whitespaces).hasPrefix("#Preview") {
                    inPreview = true
                    previewDepth = 0
                }
                guard inPreview else { continue }
                skipped.insert(line)
                previewDepth += text.filter { $0 == "{" }.count - text.filter { $0 == "}" }.count
                if previewDepth <= 0, text.contains("}") { inPreview = false }
            }
        }
        guard skipping.contains(.debug) else { return skipped }

        // DEBUG-only copy is compiled out of the app Dan runs, so it can never mislead him: DebugSeed and
        // DebugStaging are nothing but fake prospect names. But only the DEBUG BRANCH is skipped. Several
        // of these blocks have an #else holding the release behaviour (StoreLocation, OvertureDeepLink),
        // and dropping that half would quietly hide real copy, which is the one thing this must not do.
        var depth = 0                 // how many #if blocks deep we are, DEBUG or otherwise
        var debugDepth: Int?          // the depth at which the DEBUG branch began, once we're in one
        for line in scan.codeLines.keys.sorted() {
            let text = scan.codeLines[line]!.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("#if") {
                depth += 1
                if text.hasPrefix("#if DEBUG"), debugDepth == nil { debugDepth = depth }
            }
            if let start = debugDepth {
                if depth == start, text.hasPrefix("#else") { debugDepth = nil }   // release half: keep it
                else { skipped.insert(line) }
            }
            if text.hasPrefix("#endif") {
                if debugDepth == depth { debugDepth = nil }
                depth -= 1
            }
        }
        return skipped
    }

    // MARK: - The scanner

    struct Comment: Equatable { var text: String; var line: Int }

    struct Scan {
        var literals: [Literal] = []
        var comments: [Comment] = []
        var codeLines: [Int: String] = [:]     // line -> its code, minus comments AND string contents:
                                               // what you want when counting braces or reading a #if
        var sourceLines: [Int: String] = [:]   // line -> its code, minus comments, strings intact:
                                               // what you want when matching a Text( and reading its words
    }

    static func tokenize(_ source: String) -> Scan {
        var scan = Scan()
        let chars = Array(source)
        var i = 0
        var line = 1

        func peek(_ offset: Int) -> Character? {
            let index = i + offset
            return index < chars.count ? chars[index] : nil
        }
        // #3155: whether the last thing emitted was a literal, and whether a `+` has been seen since.
        // Both are needed together: `+` alone is arithmetic, and a literal alone is the ordinary case.
        // Whitespace is transparent, so a concatenation broken across lines reads the same as one on a
        // single line (a newline never reaches here, and a comment never does either, so both are
        // transparent for free).
        var lastEmissionWasLiteral = false
        var plusSinceThatLiteral = false

        func code(_ character: Character) {
            scan.codeLines[line, default: ""].append(character)
            scan.sourceLines[line, default: ""].append(character)
            if character.isWhitespace { return }
            if character == "+", lastEmissionWasLiteral {
                plusSinceThatLiteral = true
                return
            }
            lastEmissionWasLiteral = false
            plusSinceThatLiteral = false
        }
        // A literal is put back into its line's source, quotes and all, so a caller matching on `Text(`
        // sees the sentence sitting inside it. A `"""` block collapses onto its opening line, which is
        // what a statement-shaped reader wants anyway.
        func literal(_ text: String, raw: Bool, at start: Int) {
            let quoted = raw ? "#\"\(text)\"#" : "\"\(text)\""
            scan.sourceLines[start, default: ""].append(quoted)
            scan.literals.append(Literal(text: text, isRaw: raw, line: start,
                                         joinedToPrevious: lastEmissionWasLiteral && plusSinceThatLiteral))
            lastEmissionWasLiteral = true
            plusSinceThatLiteral = false
        }

        while i < chars.count {
            let character = chars[i]

            if character == "\n" { line += 1; i += 1; continue }

            // A comment. Never one that lives inside a string: this branch is only reachable from code.
            if character == "/", peek(1) == "/" {
                var text = ""
                i += 2
                while i < chars.count, chars[i] != "\n" { text.append(chars[i]); i += 1 }
                scan.comments.append(Comment(text: text.trimmingCharacters(in: .whitespaces), line: line))
                continue
            }
            if character == "/", peek(1) == "*" {
                var depth = 1
                i += 2
                while i < chars.count, depth > 0 {
                    if chars[i] == "\n" { line += 1 }
                    if chars[i] == "/", i + 1 < chars.count, chars[i + 1] == "*" { depth += 1; i += 2; continue }
                    if chars[i] == "*", i + 1 < chars.count, chars[i + 1] == "/" { depth -= 1; i += 2; continue }
                    i += 1
                }
                continue
            }

            // A raw string, #"..."# or ##"..."##. Escapes don't apply; only a quote followed by the same
            // number of hashes closes it. That is what makes a regex's own quotes and backslashes safe.
            if character == "#" {
                var hashes = 0
                var j = i
                while j < chars.count, chars[j] == "#" { hashes += 1; j += 1 }
                if j < chars.count, chars[j] == "\"" {
                    let start = line
                    var text = ""
                    i = j + 1
                    while i < chars.count {
                        if chars[i] == "\n" { line += 1 }
                        if chars[i] == "\"" {
                            var closing = 0
                            var k = i + 1
                            while k < chars.count, chars[k] == "#" { closing += 1; k += 1 }
                            if closing >= hashes { i = k; break }
                        }
                        text.append(chars[i])
                        i += 1
                    }
                    literal(text, raw: true, at: start)
                    continue
                }
            }

            if character == "\"" {
                let isMulti = peek(1) == "\"" && peek(2) == "\""
                let start = line
                i += isMulti ? 3 : 1
                let text = readString(chars, &i, &line, isMulti: isMulti)
                literal(text, raw: false, at: start)
                continue
            }

            code(character)
            i += 1
        }
        return scan
    }

    // Reads a string's contents, leaving `i` just past the closing quote.
    //
    // The whole difficulty is the interpolation: `\(...)` is CODE, and code can contain a string, and
    // that string's quotes must not end the one we're in. So inside an interpolation we count parens and
    // step over any nested literal wholesale, appending everything verbatim, because what the caller
    // wants back is the sentence's TEMPLATE ("Playing \(venue ?? "Venue TBD") tonight"), not its parts.
    private static func readString(_ chars: [Character], _ i: inout Int, _ line: inout Int,
                                   isMulti: Bool) -> String {
        var text = ""
        while i < chars.count {
            let character = chars[i]

            if character == "\n" {
                line += 1
                if !isMulti { break }            // an unterminated single-line literal: don't run away
                text.append(character)
                i += 1
                continue
            }

            if character == "\\", i + 1 < chars.count {
                if chars[i + 1] == "(" {
                    text.append("\\(")
                    i += 2
                    var depth = 1
                    while i < chars.count, depth > 0 {
                        let inner = chars[i]
                        if inner == "\n" { line += 1 }
                        if inner == "\"" {                      // a literal inside the interpolation
                            text.append(inner)
                            i += 1
                            while i < chars.count, chars[i] != "\"" {
                                if chars[i] == "\\", i + 1 < chars.count {
                                    text.append(chars[i]); text.append(chars[i + 1]); i += 2; continue
                                }
                                if chars[i] == "\n" { line += 1 }
                                text.append(chars[i])
                                i += 1
                            }
                            if i < chars.count { text.append(chars[i]); i += 1 }
                            continue
                        }
                        if inner == "(" { depth += 1 }
                        if inner == ")" { depth -= 1; if depth == 0 { text.append(inner); i += 1; break } }
                        text.append(inner)
                        i += 1
                    }
                    continue
                }
                text.append(chars[i]); text.append(chars[i + 1])   // an escape: \" \\ \n, kept verbatim
                i += 2
                continue
            }

            if character == "\"" {
                if isMulti {
                    if i + 2 < chars.count, chars[i + 1] == "\"", chars[i + 2] == "\"" { i += 3; break }
                } else {
                    i += 1
                    break
                }
            }

            text.append(character)
            i += 1
        }
        if isMulti { return trimMultiLine(text) }
        return text
    }

    // A `"""` literal's contents start on the line after the opening quotes, and Swift strips the
    // indentation of the closing ones.
    private static func trimMultiLine(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        guard let last = lines.last else { return text }
        let indent = last.prefix { $0 == " " }.count
        if last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return lines.map { String($0.dropFirst(min(indent, $0.prefix { $0 == " " }.count))) }
            .joined(separator: "\n")
    }
}
