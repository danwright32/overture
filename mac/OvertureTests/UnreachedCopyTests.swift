import Foundation
import Testing

// #2707: `docs/copy-inventory.md` could list a sentence no screen in Overture is able to render.
//
// The generator finds copy by scanning for string literals. That question ("does this string exist in
// the source?") is not the question the inventory exists to answer ("can Overture say this to Dan?"). A
// sentence in a declaration nothing calls satisfies the first and fails the second, and the file could
// not tell them apart. Every dead entry is a line somebody reads carefully, holds against its
// neighbours and reasons about, for a surface that cannot appear, and the cold read of that diff is a
// REQUIRED pre-PR step. It also inflates the headline count the file opens with.
//
// The confirmed instance was "Of the N high-fit: N from a prior relationship, N on event merit", which
// nothing had been able to render since #1131 and which sat in the inventory for over a thousand issues.
//
// WHAT THIS ASKS, AND WHY IT IS SOUND FOR COPY SPECIFICALLY. `UnreachedAppCodeTests` (#2811) covers dead
// code and deliberately restricts itself to `private` declarations, because general reachability needs a
// call graph, protocol conformances and SwiftUI's own dynamic dispatch, and a broader sweep would accuse
// correct code (L93). None of that applies to a NAMED COPY CONSTANT: a sentence held in a `static let`
// or returned by a `static func` in a copy enum is reached by writing its name, never by a conformance
// or a selector, so "this name appears nowhere else in the app" really is the question.
//
// The predicate for "is this copy" is `CopyInventory.isCopy`, the inventory's OWN, called directly. A
// second definition of what counts as a sentence would drift from the file this exists to protect, and
// it would drift in the direction that flatters whichever list is shorter (L107, L26).
//
// It reads only `mac/Overture`. A declaration used solely by tests is unreached BY THE APP, which is
// exactly what makes its sentence undisplayable, whatever the suite does with it.
@Suite("Copy nothing can render (#2707)")
struct UnreachedCopyTests {

    // Declarations that hold copy and are UNREFERENCED ON PURPOSE, each with the reason it is not dead.
    //
    // Keyed on file AND name, so allowing one does not quietly allow a same-named declaration elsewhere,
    // and each carries its reason, because an allowlist entry with no reason is indistinguishable from
    // one somebody added to make a failure go away (L65). Empty today: every entry the measurement found
    // was really dead and was deleted rather than allowed.
    //
    // Both of the measurement's findings have now left this list, and by the two different routes that
    // are available. #3068 closed one by WIRING it: `closingNoteOnStoodDownShow` is on the post-event row
    // now, so it is reached rather than allowed. #3069 closed the other by DELETING it: `undoRefusalReason`
    // explained a refusal that no screen could produce, and Dan's call (2026-08-22) was that a recorded
    // form pitch is final, so the sentence and the undo it belonged to went together (L29).
    //
    // Empty is the state to keep it in. An entry here is a declaration holding copy that nothing reaches,
    // kept on purpose, and each one has to name the issue that activates it, which is this repo's rule
    // for a value nothing reads yet.
    private static let unreachedOnPurpose: [String: [String: String]] = [:]

    private struct Finding: Equatable, CustomStringConvertible {
        let file: String
        let name: String
        let sentence: String
        var description: String { "\(file): \(name) -> \"\(sentence)\"" }
    }

    // A `static let`, `static var` or `static func` declaration. Copy in this app lives in one of these,
    // inside a `...Copy` enum or a model extension, and is reached by name.
    private static let declaration = try! NSRegularExpression(
        pattern: #"^[ \t]*(?:public |internal |private |fileprivate )?static (?:let|var|func) (\w+)\b"#)

    private static func findings() -> [Finding] {
        let root = CopyInventory.appRoot
        var sources: [String: String] = [:]
        let files = (try? FileManager.default.subpathsOfDirectory(atPath: root.path)) ?? []
        for sub in files where sub.hasSuffix(".swift") {
            let url = root.appendingPathComponent(sub)
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                sources[CopyInventory.relativePath(of: url, under: root)] = text
            }
        }
        // Counted ONCE, over every identifier in the app, rather than a fresh regex per declaration.
        // There are about 1,800 copy-carrying declarations here and the naive form spent 14 seconds
        // scanning the whole tree for each of them, which is a guard nobody would want inside every run.
        //
        // Over CODE, with comments removed, which is not a detail. Counting raw text made a declaration
        // named only in somebody's PROSE read as reachable: `pendingBookingsHelp` was mentioned exactly
        // once outside its own declaration, in the comment above `tooFarHelp` saying the two mirror each
        // other, and it stayed hidden until that comment was deleted with the code it described. A
        // mention is not a use (L103).
        var mentions: [String: Int] = [:]
        for text in sources.values {
            for (_, code) in SwiftSource.scannableLines(in: text, skipping: []) {
                for word in Self.identifiers(in: code) { mentions[word, default: 0] += 1 }
            }
        }

        var found: [Finding] = []
        for (path, text) in sources.sorted(by: { $0.key < $1.key }) {
            let lines = text.components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let range = NSRange(line.startIndex..., in: line)
                guard let match = Self.declaration.firstMatch(in: line, range: range),
                      let nameRange = Range(match.range(at: 1), in: line) else { continue }
                let name = String(line[nameRange])
                if Self.unreachedOnPurpose[path]?[name] != nil { continue }

                // Mentioned anywhere but its own declaration? Then something can reach it. Asked FIRST,
                // because it settles all but a handful of declarations without reading any literals.
                guard mentions[name, default: 0] <= 1 else { continue }

                // The declaration's own body, stopping at the NEXT declaration. A fixed window of lines
                // reaches into the following constant and reports ITS sentence against this name, which
                // the first version did: `confirmGuess` ("Confirm") was reported as holding "Draft with
                // AI", the line below it. The finding was right and its evidence was somebody else's.
                var end = index + 1
                while end < lines.count, end - index < 12,
                      Self.declaration.firstMatch(
                        in: lines[end], range: NSRange(lines[end].startIndex..., in: lines[end])) == nil {
                    end += 1
                }
                let body = lines[index..<end].joined(separator: "\n")
                // Read through `SwiftSource`, never a fresh regex stripper: #2811 measured three
                // hand-rolled ones and every one accused correct code.
                let sentences = SwiftSource.literals(in: body).filter(CopyInventory.isCopy)
                guard let sentence = sentences.first else { continue }
                found.append(Finding(file: path, name: name,
                                     sentence: CopyInventory.withoutInterpolations(sentence.text)))
            }
        }
        return found
    }

    // Every identifier-shaped run of characters, which is what a name being MENTIONED looks like. Split
    // on anything that cannot be part of a Swift identifier, so `QueueModel.tooFarLabel(count:)` yields
    // `tooFarLabel` and a name inside a longer word does not count as a mention of it.
    static func identifiers(in text: String) -> [String] {
        text.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") }).map(String.init)
    }

    private static func mentions(of name: String, in text: String) -> Int {
        identifiers(in: text).filter { $0 == name }.count
    }

    // THE guard. A sentence in a declaration nothing in the app names cannot reach a screen.
    @Test func noSentenceBelongsToAdeclarationNothingReaches() {
        let dead = Self.findings()
        #expect(dead.isEmpty, """
            \(dead.count) sentence(s) belong to a declaration nothing in mac/Overture names, so no screen \
            can render them and the copy inventory is presenting them for a cold read anyway (#2707).
            Delete the declaration with the code that stopped calling it, or add it to \
            `unreachedOnPurpose` with the reason it is reachable after all:
            \(dead.map(\.description).joined(separator: "\n"))
            """)
    }

    // The instrument itself. A guard that silently found NOTHING to examine reports exactly the same
    // green as one that examined everything and approved it (L98, L100), and this one walks a directory
    // and matches a regex, both of which can come back empty for reasons unrelated to the code.
    @Test func theguardReallyExaminesTheApp() {
        let root = CopyInventory.appRoot
        let files = ((try? FileManager.default.subpathsOfDirectory(atPath: root.path)) ?? [])
            .filter { $0.hasSuffix(".swift") }
        #expect(files.count > 100, "it read \(files.count) Swift files, which is not this app")

        // And it can still SEE a dead sentence: the rule is exercised on a declaration built here rather
        // than trusted from a green run over a tree that happens to hold none (L159, L140).
        let name = "aSentenceNothingNames2707"
        let line = "    static let \(name) = \"Nothing in the app names this sentence\""
        let literals = SwiftSource.literals(in: line).filter(CopyInventory.isCopy)
        #expect(literals.isEmpty == false, "the copy predicate must recognise this as a sentence")
        #expect(Self.mentions(of: name, in: line) == 1, "one mention is what a dead declaration looks like")
    }
}
