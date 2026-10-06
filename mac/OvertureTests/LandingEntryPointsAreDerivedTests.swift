import Testing
import Foundation

// #4343 (E0, A13): every way into a scout landing is one the acceptance rig measures, DERIVED from the source.
//
// A landing is a call to `ScoutService.apply` or to `ScoutLandingStore`'s initialiser. The rig judges the
// 100 ms bar on every entry point into one, so its list of entry points (`LandingAcceptanceRig.carried`) has to
// be every entry point there is, and a hand-kept list only checks what somebody remembered (L96, L247). So it
// is derived: every function holding a landing call, then every caller of those, upward through the model
// layers (Integration, Domain, Persistence), until a function is called from the VIEW layer (App, UI). Each
// such function is an entry point, and the view functions calling it are how Dan reaches it. The rig's list
// must equal that derivation both ways: a new caller anywhere on the way up fails here, and so does an entry
// the code no longer has. Nothing is excluded by name.
//
// Calls are matched by name and by the first argument's label, qualified (`Owner.name(`), through `Self.`, or
// bare inside the same type, across files. What it cannot see, stated so its silence is read correctly: a call
// through a value (a closure, an instance stored elsewhere), which the landing path does not use for any of
// these functions today.
@MainActor
@Suite("Every way into a scout landing is one the acceptance rig measures (#4343)")
struct LandingEntryPointsAreDerivedTests {

    struct Entry: Equatable, CustomStringConvertible {
        let top: String
        let viewCallers: Set<String>
        var description: String { "\(top) <- \(viewCallers.sorted().joined(separator: ", "))" }
    }

    static func isViewLayer(_ file: String) -> Bool { file.hasPrefix("App/") || file.hasPrefix("UI/") }

    // The label a call's first argument must carry to be a call of `function`: its first parameter's external
    // name, or "" when that is `_` or there is no parameter.
    static func firstLabel(of function: StoreWriteScan.Function, index: StoreWriteScan.Index) -> String {
        let signature = index.lines(of: function).map(\.code).joined(separator: " ")
        let opener = function.name == "init" ? "init" : "func \(function.name)"
        guard let start = signature.range(of: opener)?.upperBound,
              let paren = signature[start...].firstIndex(of: "(") else { return "" }
        let afterParen = signature[signature.index(after: paren)...].drop { $0.isWhitespace }
        let words = afterParen.prefix { $0 != ":" && $0 != ")" }.split(whereSeparator: \.isWhitespace)
        guard let first = words.first, afterParen.prefix(while: { $0 != ")" }).contains(":") else { return "" }
        return first == "_" ? "" : String(first)
    }

    private static func pattern(_ head: String, label: String) -> NSRegularExpression {
        let argument = label.isEmpty ? #"(?!\s*[A-Za-z_][A-Za-z0-9_]*\s*:)"# : #"\s*"# + label + #"\s*:"#
        return try! NSRegularExpression(pattern: head + #"\s*\("# + argument)
    }

    // Each code line of a file joined, with the offset where each line starts, so a call broken across lines
    // (`ScoutService.apply(` then `events:` below) is matched as the one call it is.
    struct Joined {
        let text: String
        let starts: [(offset: Int, line: Int)]
        func line(at offset: Int) -> Int {
            var low = 0, high = starts.count - 1
            while low < high {
                let mid = (low + high + 1) / 2
                if starts[mid].offset <= offset { low = mid } else { high = mid - 1 }
            }
            return starts[low].line
        }
    }

    static func joined(_ code: [(line: Int, code: String)]) -> Joined {
        var text = ""
        var starts: [(offset: Int, line: Int)] = []
        for (line, code) in code {
            starts.append((text.utf16.count, line))
            text += code + "\n"
        }
        return Joined(text: text, starts: starts)
    }

    // The outermost function or computed property holding a line, which is what a call there belongs to.
    static func holder(of line: Int, in file: String, index: StoreWriteScan.Index) -> StoreWriteScan.Function? {
        (index.functions + index.properties)
            .filter { $0.file == file && $0.firstLine <= line && line <= $0.lastLine }
            .min { $0.firstLine < $1.firstLine }
    }

    // Every function holding a call that matches `head` with `label`, optionally only inside functions owned by
    // `owner` (a bare or `Self.` call reaches only its own type).
    static func holders(calling head: String, label: String, inside owner: String?, index: StoreWriteScan.Index,
                        joined: [String: Joined]) -> [StoreWriteScan.Function] {
        let re = pattern(head, label: label)
        var out: [StoreWriteScan.Function] = []
        for (file, j) in joined {
            for m in re.matches(in: j.text, range: NSRange(location: 0, length: j.text.utf16.count)) {
                let line = j.line(at: m.range.location)
                guard let h = holder(of: line, in: file, index: index) else { continue }
                if let owner {
                    // The innermost function at the line decides whose `Self` and whose bare names these are.
                    let inner = (index.functions + index.properties)
                        .filter { $0.file == file && $0.firstLine <= line && line <= $0.lastLine }
                        .max { $0.firstLine < $1.firstLine }
                    guard inner?.owner == owner else { continue }
                }
                out.append(h)
            }
        }
        return out
    }

    static func callers(of f: StoreWriteScan.Function, index: StoreWriteScan.Index,
                        joined: [String: Joined]) -> [StoreWriteScan.Function] {
        let label = firstLabel(of: f, index: index)
        var out: [StoreWriteScan.Function] = []
        if let owner = f.owner {
            out += holders(calling: #"\b"# + owner + #"\s*\.\s*"# + f.name, label: label, inside: nil,
                           index: index, joined: joined)
            out += holders(calling: #"\bSelf\s*\.\s*"# + f.name, label: label, inside: owner, index: index,
                           joined: joined)
        }
        out += holders(calling: #"(?<![\w.])(?<!func )"# + f.name, label: label, inside: f.owner, index: index,
                       joined: joined)
        return out.filter { $0 != f }
    }

    static func derive(_ files: [(name: String, text: String)]) -> (entries: [Entry], sites: [String]) {
        let index = StoreWriteScan.Index(files: files)
        var joinedByFile: [String: Joined] = [:]
        for (file, lines) in index.code { joinedByFile[file] = joined(lines) }
        // The landing calls themselves.
        var start: [StoreWriteScan.Function] = []
        start += holders(calling: #"\bScoutService\s*\.\s*apply"#, label: "events", inside: nil, index: index,
                         joined: joinedByFile)
        start += holders(calling: #"(?<![\w.])(?<!func )apply"#, label: "events", inside: "ScoutService",
                         index: index, joined: joinedByFile)
        start += holders(calling: #"\bScoutLandingStore(?:\s*\.\s*init)?"#, label: "context", inside: nil,
                         index: index, joined: joinedByFile)
        let sites = Set(start.map(\.qualifiedName)).sorted()
        // Upward, until a function is called from the view layer.
        var seen: Set<StoreWriteScan.Function> = []
        var queue = start.filter { !isViewLayer($0.file) }
        var entries: [String: Set<String>] = [:]
        while let f = queue.popLast() {
            guard seen.insert(f).inserted else { continue }
            let up = callers(of: f, index: index, joined: joinedByFile)
            let view = up.filter { isViewLayer($0.file) }
            if !view.isEmpty || up.isEmpty {
                entries[f.qualifiedName, default: []].formUnion(view.map(\.qualifiedName))
            }
            queue += up.filter { !isViewLayer($0.file) }
        }
        return (entries.map { Entry(top: $0.key, viewCallers: $0.value) }.sorted { $0.top < $1.top }, sites)
    }

    static func appFiles() -> [(name: String, text: String)] {
        let root = RepoRoot.app.standardizedFileURL.path
        return AppSourceWalk.appFiles().map { file in
            (name: String(file.url.standardizedFileURL.path.dropFirst(root.count + 1)), text: file.text)
        }
    }

    @Test func theRigCarriesEveryEntryPointTheSourceHas() {
        let derived = Self.derive(Self.appFiles())
        // POSITIVE CONTROL (L98): the landing calls were found where the code is known to make them, so an empty
        // derivation cannot read as a rig that carries everything.
        for site in ["ScoutService.runScout", "ScoutExtractIngest.ingest", "LeadPasteLanding.landPastedLead"] {
            #expect(derived.sites.contains(site), Comment(rawValue: "no landing call found in \(site): \(derived.sites)"))
        }
        let carried = LandingAcceptanceRig.carried.map { Entry(top: $0.top, viewCallers: $0.viewCallers) }
            .sorted { $0.top < $1.top }
        print("landing entry points, derived: " + derived.entries.map(\.description).joined(separator: "; "))
        #expect(derived.entries == carried, Comment(rawValue: """
            the acceptance rig's entry points are not the ones the source has. Derived: \
            \(derived.entries.map(\.description).joined(separator: "; ")). Carried by the rig: \
            \(carried.map(\.description).joined(separator: "; ")). Give the rig a driver for a new one \
            (LandingAcceptanceRig.Entry) rather than leaving it unmeasured.
            """))
    }

    // MARK: - The rule, on sources written here

    @Test func aNewCallerOnTheWayUpIsAnEntryPointAndAViewCallerNamesIt() {
        let files: [(name: String, text: String)] = [
            (name: "Integration/Store.swift", text: """
                enum ScoutService {
                    static func apply(events: [Int], into c: Int) -> Int { 0 }
                    static func sweep() -> Int {
                        apply(events: [], into: 0)
                    }
                    static func other() -> Int {
                        apply(enriched, to: 1)
                    }
                }
                enum Ingest {
                    static func land() -> Int {
                        ScoutService.apply(
                            events: [], into: 0)
                    }
                    static func offer() -> Int { Self.land() }
                }
                """),
            (name: "UI/Screen.swift", text: """
                struct Screen {
                    func press() { _ = ScoutService.sweep(); _ = Ingest.offer() }
                    func paste() { _ = Ingest.land() }
                }
                """),
        ]
        let derived = Self.derive(files)
        #expect(derived.sites == ["Ingest.land", "ScoutService.sweep"])
        #expect(derived.entries == [
            Entry(top: "Ingest.land", viewCallers: ["Screen.paste"]),
            Entry(top: "Ingest.offer", viewCallers: ["Screen.press"]),
            Entry(top: "ScoutService.sweep", viewCallers: ["Screen.press"]),
        ], Comment(rawValue: derived.entries.map(\.description).joined(separator: "; ")))
    }

    @Test func aFunctionNothingCallsIsAnEntryPointWithNoViewCaller() {
        let files: [(name: String, text: String)] = [
            (name: "Integration/Store.swift", text: """
                enum Orphan {
                    static func land() -> Int { ScoutLandingStore(context: 0).count }
                }
                """),
        ]
        #expect(Self.derive(files).entries == [Entry(top: "Orphan.land", viewCallers: [])])
    }
}
