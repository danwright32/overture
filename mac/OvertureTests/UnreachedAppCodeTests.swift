import Foundation
import Testing

// #2811: app code nothing reaches, found deliberately instead of one instance at a time.
//
// The class is established rather than speculative. Filed individually before this: #2672 (a field
// nothing writes), #2796 (a refusal with no shipping caller), #2490 (a case with no writer), #1640,
// #2419. Every one looked alive to any is-this-used check, because the declaration really does exist
// and the write path really does run. They are not evenly harmless either: one was a safety refusal
// meant to stop Overture adding a message to a conversation it never sent on, which read as being in
// force precisely because it existed and had tests (L3, L46).
//
// WHAT THIS ASKS, AND WHY IT IS THE SOUND SUBSET. Only `private` declarations. A private name can be
// used ONLY in the file that declares it, so "no other line in this file mentions it" is a proof
// rather than a heuristic, and there is no cross-file lookup to get wrong. A sweep over internal or
// public declarations would need real reachability (a call graph, protocol conformances, SwiftUI's own
// dynamic dispatch) and would accuse correct code, which is a guard nobody keeps (L93).
//
// READ THROUGH `SwiftSource`, the repo's own lexer, rather than a fresh regex stripper. That is not a
// preference: three hand-rolled strippers were tried while measuring this and each accused correct
// code. Erasing string literals wholesale accuses every copy helper, because in this codebase they are
// called from inside `\(...)`. Mishandling `"""` flips the parse and erases the rest of the file.
// Worst, stripping `//` comments BEFORE strings eats the closing quote of any literal holding a URL
// (`"http://127.0.0.1:\(port)"`), which erased 200 lines of GmailAuthManager and accused six
// properties that are each used five times. `SwiftSource.tokenize` handles all three, because it walks
// the characters once and its comment branch is reachable only from code.
//
// It reads each line's SOURCE (literals included), which is the safe direction: a declaration whose
// name also appears inside a sentence is not reported. That misses a finding rather than inventing one.
@Suite("App code nothing reaches (#2811)")
struct UnreachedAppCodeTests {

    // The declarations that are UNREFERENCED ON PURPOSE, each with the reason it is not dead.
    //
    // Every entry so far is one kind: a SwiftUI property wrapper whose job is a side effect rather than
    // a value. `@AppStorage` and `@Query` are DynamicProperty, so SwiftUI subscribes to them and
    // redraws the view when the underlying store changes, whether or not the body ever reads the
    // property. Both of the ones here say exactly that in their own comments ("bound, not merely
    // read"), which is what tells this apart from a leftover.
    //
    // Keyed on file AND name, so allowing one does not quietly allow a same-named declaration
    // elsewhere. Each carries its reason, because an allowlist entry with no reason is indistinguishable
    // from one somebody added to make a failure go away (L65).
    private static let unreferencedOnPurpose: [String: [String: String]] = [
        "OvertureApp.swift": [
            "appDelegate": "@NSApplicationDelegateAdaptor installs the delegate; the property is never read by design",
        ],
        "DaysOffView.swift": [
            "snoozedUntil": "@AppStorage bound for invalidation (#925): pressing Hide this for a week redraws the sheet",
        ],
        "ExcludedTownsView.swift": [
            "allowedRows": "@Query bound for invalidation (#1221): an Allow or Skip again redraws the seed sections",
        ],
    ]

    private static let declaration = try! NSRegularExpression(
        pattern: #"^\s*(?:@\w+(?:\([^)]*\))?\s+)*private\s+(?:static\s+)?(?:func|var|let)\s+([A-Za-z_]\w*)"#)

    private struct Finding {
        let file: String
        let line: Int
        let name: String
    }

    private static func findings() -> [Finding] {
        var out: [Finding] = []
        for file in AppSourceWalk.files(under: RepoRoot.mac.appendingPathComponent("Overture"), floor: 200) {
            let lines = SwiftSource.scannableLines(in: file.text, skipping: [])
            for (index, entry) in lines.enumerated() {
                let range = NSRange(entry.code.startIndex..., in: entry.code)
                guard let match = Self.declaration.firstMatch(in: entry.code, range: range),
                      let nameRange = Range(match.range(at: 1), in: entry.code) else { continue }
                let name = String(entry.code[nameRange])
                let used = lines.enumerated().contains { other in
                    other.offset != index && Self.mentions(name, in: other.element.code)
                }
                guard !used else { continue }
                guard Self.unreferencedOnPurpose[file.name]?[name] == nil else { continue }
                out.append(Finding(file: file.name, line: entry.line, name: name))
            }
        }
        return out
    }

    // A whole-word mention. Without the boundaries `list` is found inside `listing` and nothing is ever
    // reported, which is the way this guard would fail silently rather than loudly.
    private static func mentions(_ name: String, in text: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: #"\b"# + NSRegularExpression.escapedPattern(for: name) + #"\b"#)
        else { return true }
        return re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    @Test func noPrivateDeclarationIsUnreachable() {
        let found = Self.findings()
        #expect(found.isEmpty, """
                app code nothing can reach:
                \(found.map { "  \($0.file):\($0.line)  \($0.name)" }.joined(separator: "\n"))

                A private declaration can only be used in the file that declares it, so nothing in this \
                app can reach these. Delete them, or add the name to `unreferencedOnPurpose` WITH the \
                reason it is not dead (#2811, L29, L46).
                """)
    }

    // The scan really is reading the app, rather than passing on an empty walk. `AppSourceWalk` already
    // refuses below its floor; this says so again against the thing that matters here, which is that
    // private declarations were found at all (L98).
    @Test func theScanReallyReadsPrivateDeclarations() {
        var declarations = 0
        for file in AppSourceWalk.files(under: RepoRoot.mac.appendingPathComponent("Overture"), floor: 200) {
            for entry in SwiftSource.scannableLines(in: file.text, skipping: []) {
                let range = NSRange(entry.code.startIndex..., in: entry.code)
                if Self.declaration.firstMatch(in: entry.code, range: range) != nil { declarations += 1 }
            }
        }
        #expect(declarations > 300, "found only \(declarations) private declarations; the scan is broken")
    }

    // Every allowlist entry must still EXIST, or the list grows into a record of things that were
    // deleted years ago and quietly exempts a future declaration that happens to take the same name.
    @Test func everyAllowedNameIsStillDeclared() {
        let files = AppSourceWalk.files(under: RepoRoot.mac.appendingPathComponent("Overture"), floor: 200)
        for (fileName, names) in Self.unreferencedOnPurpose {
            guard let file = files.first(where: { $0.name == fileName }) else {
                Issue.record("\(fileName) is allowlisted for #2811 and no longer exists")
                continue
            }
            for (name, reason) in names {
                #expect(file.text.contains(name),
                        "\(fileName) no longer declares \(name), allowed because: \(reason)")
                #expect(!reason.isEmpty)
            }
        }
    }
}
