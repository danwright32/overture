import Testing
import Foundation

// #4330 (A13): the entry point list is DERIVED from the code, never named (L96, L247). Every function that
// calls `ScoutService.apply` or builds a `ScoutLandingStore` is a landing entry point, and it must take its
// turn through `LandingSingleFlight.begin` unless it has the one reason to be exempt.
//
// THE EXEMPTION IS A REASON, CHECKED MECHANICALLY (L362). A caller is exempt only while its own body has no
// suspension point between its first touch of the store and its last write, because such a caller cannot
// interleave with a landing block: on the main actor it runs start to finish in one turn. It is never
// exempt by name. `LeadIntakeModel.importAll` passed while it was synchronous; #4339 (A11) gave the paste its
// awaits and, in the same change, its own turn through `begin` (`LeadPasteLanding.landPastedLead`).
//
// An exempt caller's OWN callers are then entry points in turn (they reach the store through it), followed
// by name wherever the name is declared exactly once in the app, so a new async caller of `applySweep` is
// caught as surely as a new caller of `apply`. A name declared more than once cannot be followed by text,
// and each such name is listed, with its reason, in `unfollowed`, so a new one fails rather than passing.
@Suite("Every scout landing entry point waits its turn for the store (#4330)")
struct EveryScoutLandingGoesThroughTheSingleFlightTests {

    struct Function: Equatable {
        let file: String
        let name: String
        let line: Int
        let lines: [(line: Int, code: String)]

        static func == (a: Function, b: Function) -> Bool { a.file == b.file && a.name == b.name && a.line == b.line }
        var label: String { "\(file):\(line) \(name)" }
    }

    enum Verdict: Equatable {
        case throughTheFlight
        case exempt
        case unguarded(String)
    }

    // What makes a function a landing entry point to begin with.
    static let directCalls = ["ScoutService.apply(", "apply(events:", "ScoutLandingStore("]
    // A read of the store a landing will then write against.
    static let storeTouches = ["context.fetch(", ".fetch(FetchDescriptor", "readProspectTable(", "row(for:",
                               "venueBrandCorpus(", "ScoutLandingStore(",
                               // #4339: the entry flush saves the main context, so a caller that flushes, reads
                               // off the main thread and lands later has touched the store from its first line.
                               "flushBeforeLanding("]
    // A write, or a call that writes.
    static let writes = [".save()", "saveLanding(", "save(context)"]

    // Names declared more than once in the app, so their callers cannot be told apart by text, with why
    // leaving each unfollowed does not open a gap.
    static let unfollowed: [String: String] = [
        "apply": "ScoutService.apply itself, whose default working set is built inside it; every caller of it "
            + "is already found through `ScoutService.apply(` and `apply(events:` above",
    ]

    // Type level functions (four spaces in, which is where a type's own members sit in this codebase), each
    // with its code lines: comments and string contents removed, so neither can be mistaken for a call.
    static func functions(in source: String, file: String) -> [Function] {
        let code = SwiftSource.tokenize(source).codeLines
        let numbers = code.keys.sorted()
        var out: [Function] = []
        var i = 0
        while i < numbers.count {
            let text = code[numbers[i]]!
            guard let name = declaredName(text), text.hasPrefix("    "), !text.hasPrefix("     ") else {
                i += 1
                continue
            }
            // Balance braces from the BODY's opening brace, over the code alone. The body opens at the first
            // brace once the parameter list has closed: a default argument can itself be a closure (`= { _
            // in }`), and counting from the declaration line would end the function inside its signature.
            var parens = 0
            var sawParen = false
            var depth = 0
            var opened = false
            var body: [(Int, String)] = []
            var j = i
            scan: while j < numbers.count {
                let lineText = code[numbers[j]]!
                // A requirement with no body (a protocol's `func`) ends where the next declaration starts.
                if !opened && j > i && declaredName(lineText) != nil {
                    j -= 1
                    break scan
                }
                body.append((numbers[j], lineText))
                for ch in lineText {
                    if !opened {
                        if ch == "(" { parens += 1; sawParen = true }
                        if ch == ")" { parens -= 1 }
                        if ch == "{" && sawParen && parens == 0 { opened = true; depth = 1; continue }
                        continue
                    }
                    if ch == "{" { depth += 1 }
                    if ch == "}" { depth -= 1; if depth == 0 { break scan } }
                }
                j += 1
            }
            out.append(Function(file: file, name: name, line: numbers[i], lines: body))
            i = j + 1
        }
        return out
    }

    static func declaredName(_ text: String) -> String? {
        guard let range = text.range(of: #"\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)\s*[(<]"#, options: .regularExpression)
        else { return nil }
        let decl = text[range]
        return String(decl.dropFirst(4).trimmingCharacters(in: .whitespaces).prefix { $0.isLetter || $0.isNumber || $0 == "_" })
    }

    // A call of `name(` that is not its own declaration and not a longer identifier ending in it.
    static func calls(_ needle: String, in text: String) -> Bool {
        var search = text.startIndex..<text.endIndex
        while let r = text.range(of: needle, range: search) {
            let before = r.lowerBound == text.startIndex ? " " : text[text.index(before: r.lowerBound)]
            // A needle that starts with a dot (`.save()`) is a member call and follows its receiver's name.
            let isIdentifierTail = needle.first != "." && (before.isLetter || before.isNumber || before == "_")
            let prefix = text[text.startIndex..<r.lowerBound]
            let isDeclaration = prefix.hasSuffix("func ")
            if !isIdentifierTail && !isDeclaration { return true }
            search = r.upperBound..<text.endIndex
        }
        return false
    }

    static func verdict(_ f: Function, targets: [String]) -> Verdict {
        let body = f.lines.dropFirst()   // the declaration line itself touches nothing
        let touchLines = body.filter { l in (storeTouches + targets).contains { calls($0, in: l.code) } }.map(\.line)
        let writeLines = body.filter { l in (writes + targets).contains { calls($0, in: l.code) } }.map(\.line)
        guard let first = touchLines.min(), let last = writeLines.max() ?? touchLines.max() else { return .exempt }
        let awaits = body.filter { $0.line >= first && $0.line <= last && $0.code.range(of: #"\bawait\b"#, options: .regularExpression) != nil }
        if awaits.isEmpty { return .exempt }
        let firstTarget = body.first { l in targets.contains { calls($0, in: l.code) } }?.line ?? first
        // `.begin(` with its `entryPoint:` label on the same line or the next, so re-wrapping the call does
        // not turn this red for formatting (L103).
        let bodyLines = Array(body)
        let begins = bodyLines.indices.filter { k in
            guard bodyLines[k].code.contains(".begin(") else { return false }
            let next = k + 1 < bodyLines.count ? bodyLines[k + 1].code : ""
            return (bodyLines[k].code + " " + next).range(of: #"\.begin\(\s*entryPoint:"#, options: .regularExpression) != nil
        }.map { bodyLines[$0].line }
        guard let begin = begins.min() else {
            return .unguarded("it can suspend (line \(awaits[0].line)) between its first touch of the store "
                              + "(line \(first)) and its last write (line \(last)), and never calls "
                              + "LandingSingleFlight.begin")
        }
        guard begin < firstTarget else {
            return .unguarded("it calls LandingSingleFlight.begin at line \(begin), after it has already "
                              + "started landing at line \(firstTarget)")
        }
        return .throughTheFlight
    }

    struct Derivation {
        var verdicts: [(Function, Verdict)] = []
        var notFollowed: Set<String> = []
    }

    static func derive(_ files: [(name: String, text: String)]) -> Derivation {
        let all = files.flatMap { functions(in: $0.text, file: $0.name) }
        let declaredCount = Dictionary(grouping: all, by: \.name).mapValues(\.count)
        var targets = directCalls
        var judged: [Function] = []
        var out = Derivation()
        var frontier = directCalls
        while !frontier.isEmpty {
            let needles = frontier
            frontier = []
            for f in all where !judged.contains(f) {
                guard f.lines.dropFirst().contains(where: { l in needles.contains { calls($0, in: l.code) } }) else { continue }
                judged.append(f)
                let v = verdict(f, targets: targets)
                out.verdicts.append((f, v))
                if v == .exempt {
                    if declaredCount[f.name] == 1 {
                        let needle = f.name + "("
                        if !targets.contains(needle) { targets.append(needle); frontier.append(needle) }
                    } else {
                        out.notFollowed.insert(f.name)
                    }
                }
            }
        }
        return out
    }

    // MARK: - The app

    private func derivedFromTheApp() -> Derivation {
        let files = AppSourceWalk.appFiles().map { (name: $0.name, text: $0.text) }
        return Self.derive(files)
    }

    @Test func everyDerivedEntryPointWaitsItsTurnOrCannotInterleave() {
        let derived = derivedFromTheApp()
        let unguarded = derived.verdicts.compactMap { f, v -> String? in
            if case .unguarded(let why) = v { return "\(f.label): \(why)" }
            return nil
        }
        #expect(unguarded.isEmpty, Comment(rawValue:
            "a landing entry point can interleave with another landing without waiting its turn: "
            + unguarded.joined(separator: "; ")))
    }

    // The derivation found the entry points that exist today, so an empty or broken walk cannot pass the
    // test above by finding nothing (L98). Asserted by what each IS, not as a closed list: a new entry
    // point is judged above rather than breaking this.
    @Test func theDerivationFindsTodaysEntryPoints() {
        let derived = derivedFromTheApp()
        func verdict(_ name: String) -> Verdict? { derived.verdicts.first { $0.0.name == name }?.1 }
        #expect(verdict("runScout") == .throughTheFlight)
        #expect(verdict("ingest") == .throughTheFlight)
        // #4339 (A11): the lead paste awaits now, so it takes its own turn, at Dan's priority.
        #expect(verdict("landPastedLead") == .throughTheFlight, "the lead paste lands without waiting its turn")
        #expect(verdict("importAll") == nil,
                Comment(rawValue: "importAll should not be a derived entry point: it calls only landPastedLead and "
                    + "touches the store nowhere itself, so being derived means it has started touching the store directly"))
        #expect(verdict("applySweep") == .exempt)
        #expect(verdict("landNative") == .exempt)
        #expect(derived.verdicts.count >= 6, Comment(rawValue:
            "only \(derived.verdicts.count) entry points were derived: \(derived.verdicts.map(\.0.label))"))
        #expect(derived.notFollowed == Set(Self.unfollowed.keys), Comment(rawValue:
            "names that could not be followed by text: \(derived.notFollowed.sorted()); each needs a reason in "
            + "`unfollowed`, or the callers behind it are unchecked"))
    }

    // MARK: - The rule, on sources written for it (seen to fail in each direction)

    private func verdictOf(_ body: String, named name: String = "enter") -> Verdict? {
        let source = "enum Probe {\n\(body)\n}\n"
        return Self.derive([(name: "Probe.swift", text: source)]).verdicts.first { $0.0.name == name }?.1
    }

    @Test func anAsyncCallerThatAwaitsBeforeItLandsAndNeverWaitsItsTurnIsUnguarded() {
        let v = verdictOf("""
                static func enter(context: ModelContext) async {
                    let rows = try? context.fetch(FetchDescriptor<Prospect>())
                    await somethingElse()
                    _ = ScoutService.apply(events: [], into: context)
                }
            """)
        guard case .unguarded = v else { Issue.record("judged \(String(describing: v))"); return }
    }

    @Test func theSameCallerWaitingItsTurnFirstGoesThroughTheFlight() {
        let v = verdictOf("""
                static func enter(context: ModelContext) async throws {
                    let rows = try? context.fetch(FetchDescriptor<Prospect>())
                    await somethingElse()
                    let token = try await landings.begin(entryPoint: .scoutExtractIngest, priority: .scout, deadline: .seconds(1))
                    _ = ScoutService.apply(events: [], into: context)
                    token.end()
                }
            """)
        #expect(v == .throughTheFlight)
    }

    @Test func aCallerThatWaitsOnlyAfterItHasStartedLandingIsUnguarded() {
        let v = verdictOf("""
                static func enter(context: ModelContext) async throws {
                    let landing = ScoutLandingStore(context: context)
                    await somethingElse()
                    let token = try await landings.begin(entryPoint: .scoutExtractIngest, priority: .scout, deadline: .seconds(1))
                    try context.save()
                }
            """)
        guard case .unguarded = v else { Issue.record("judged \(String(describing: v))"); return }
    }

    @Test func aSynchronousCallerIsExemptByItsReasonAndItsCallersAreJudgedInTurn() {
        let source = """
            enum Probe {
                static func paste(context: ModelContext) {
                    let rows = try? context.fetch(FetchDescriptor<Prospect>())
                    _ = ScoutService.apply(events: [], into: context)
                }
                static func caller(context: ModelContext) async {
                    let rows = try? context.fetch(FetchDescriptor<Prospect>())
                    await somethingElse()
                    paste(context: context)
                }
            }
            """
        let derived = Self.derive([(name: "Probe.swift", text: source)])
        #expect(derived.verdicts.first { $0.0.name == "paste" }?.1 == .exempt)
        guard case .unguarded = derived.verdicts.first(where: { $0.0.name == "caller" })?.1 else {
            Issue.record("an async caller of an exempt function was not judged: \(derived.verdicts.map(\.0.label))")
            return
        }
    }

    // A comment or a string naming the call is never a call (the scan reads code alone).
    @Test func aCommentOrAStringNamingTheCallIsNotACall() {
        let v = verdictOf("""
                static func enter(context: ModelContext) async {
                    // ScoutService.apply(events: [], into: context)
                    let s = "ScoutLandingStore(context: context)"
                    await somethingElse()
                }
            """)
        #expect(v == nil)
    }
}
