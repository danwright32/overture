import Testing
import Foundation

// #4252: no production code saves through a `ModelContext` other than the store's main one.
//
// WHY. Measured by #4102's agent on 2026-09-25 (a swiftc probe, SwiftData on macOS 26): a second context
// that fetched a row, then saved an edit to one field after the main context had saved a different field
// on the same row, wrote the WHOLE object back, reverting the main context's field to its old value. So a
// write through a second context silently undoes whatever Dan changed on that row in the meantime. A
// second context may READ (`StoreRows.readInBackground` does, off the main actor) and must never save.
//
// It is also the premise `ScopeMemo` serves a refetch on: that every save the app makes comes through the
// main context, so a change behind an observed notification either moved the save count or is still
// unsaved there. A store that ever takes a save through another context stops serving refetches
// (`StoreSaveCount.hasForeignSaves`), as a net, but this is what keeps the app from making one.
//
// WHAT IT CAN SEE. Every `ModelContext(...)` constructed in app code, which must be bound to a name, and
// that name must never have `save` or `transaction` called on it in the same file. A construction whose
// context is RETURNED is reported rather than trusted. And any `@ModelActor`, whose whole purpose is a
// context of its own that writes, is refused outright.
//
// #4332 (A3): a context PASSED ON is followed rather than refused, because the brand corpus read off the main
// actor has to hand its context to the shared corpus builder and its two fetches. It is accepted only when
// every call on the handing line resolves to app functions (`StoreWriteScan.callees`) and nothing reachable
// from them, transitively, inserts, deletes, saves or opens a transaction; or when the callee is a closure
// parameter of the enclosing function declared as one of the two injected reads (`acceptedClosureTypes`): the
// whole table read, whose only production value is `ScoutService.readProspectTable`, a single fetch, and the
// producer corrections read, whose only production value calls `ProducerOverrideEditing.readOverrides`
// (`theInjectedReadsOnlyFetch` asserts both). WHAT THAT CANNOT SEE: a call through any other value (a
// protocol witness, a stored closure) is not followed, so such a hand-on is still reported.
@Suite("Only a store's main context ever saves (#4252)")
struct OnlyTheMainContextWritesGuardTests {

    private static let appRoot = RepoRoot.mac.appendingPathComponent("Overture")

    struct Finding: Equatable {
        let file: String
        let line: Int
        let why: String
    }

    // The rule, over one file's text, so the refusal can be driven directly as well as over the app.
    // `sources` is the app source a hand-on is followed through; nil refuses every hand-on, as before #4332.
    static func findings(in text: String, file: String,
                         following sources: StoreWriteScan.Index? = nil) -> (constructions: Int, findings: [Finding]) {
        let lines = SwiftSource.scannableLines(in: text, skipping: [])
        // The rest of the block the construction sits in: from its line until the brace that closes the
        // block it opened in. Scoped this way because the same name is routinely a parameter of another
        // function in the same file, and a whole-file search would read that one's uses as this one's.
        func scopeLines(from index: Int) -> [(line: Int, code: String)] {
            var depth = 0
            var taken: [(line: Int, code: String)] = []
            for (line, source) in lines[index...] {
                taken.append((line, source))
                depth += source.filter { $0 == "{" }.count - source.filter { $0 == "}" }.count
                if depth < 0 { break }
            }
            return taken
        }
        func scope(from index: Int) -> String {
            scopeLines(from: index).map(\.code).joined(separator: "\n") + "\n"
        }
        var constructions = 0
        var found: [Finding] = []
        let binding = try! NSRegularExpression(pattern: #"\b(let|var)\s+(\w+)\s*=\s*ModelContext\("#)
        for (index, (line, source)) in lines.enumerated() {
            if source.contains("@ModelActor") {
                found.append(Finding(file: file, line: line, why: "declares a @ModelActor, a context of its own that writes"))
            }
            guard source.contains("ModelContext(") else { continue }
            constructions += 1
            let range = NSRange(source.startIndex..., in: source)
            guard let match = binding.firstMatch(in: source, range: range),
                  let nameRange = Range(match.range(at: 2), in: source) else {
                found.append(Finding(file: file, line: line,
                                     why: "constructs a ModelContext without binding it to a name this guard can follow"))
                continue
            }
            let name = String(source[nameRange])
            let code = scope(from: index)
            for verb in ["save(", "transaction("] where code.contains("\(name).\(verb)") {
                found.append(Finding(file: file, line: line,
                                     why: "constructs `\(name)` and calls \(name).\(verb)"))
            }
            if code.contains("return \(name)\n") {
                found.append(Finding(file: file, line: line,
                                     why: "hands `\(name)` on, where this guard cannot see whether it is saved"))
                continue
            }
            let handOns = ["(\(name))", "(\(name),", " \(name))", ": \(name),", ": \(name))"]
            let handing = scopeLines(from: index).filter { l in handOns.contains { (l.code + "\n").contains($0) } }
            guard !handing.isEmpty else { continue }
            guard let sources else {
                found.append(Finding(file: file, line: line,
                                     why: "hands `\(name)` on, where this guard cannot see whether it is saved"))
                continue
            }
            if let why = unverifiedHandOn(handing, file: file, index: sources) {
                found.append(Finding(file: file, line: line, why: "hands `\(name)` on, and \(why)"))
            }
        }
        return (constructions, found)
    }

    // The types a closure parameter must be declared as for a call through it to be accepted: the injected
    // whole table read and the injected producer corrections read, each of whose production values only
    // fetches (`theInjectedReadsOnlyFetch`).
    static let acceptedClosureTypes = ["ScoutLandingStore.SendableRead", "ScoutService.OverrideRead"]
    private static let callName = try! NSRegularExpression(pattern: #"(?<![\w.])([a-z_][A-Za-z0-9_]*)\s*\("#)
    private static let notCalls: Set<String> = ["if", "guard", "switch", "for", "while", "return", "try",
                                                "await", "let", "var", "catch", "in", "where"]

    // nil when every hand-on line is followed and nothing it reaches can write the store; otherwise why not.
    static func unverifiedHandOn(_ handing: [(line: Int, code: String)], file: String,
                                 index: StoreWriteScan.Index) -> String? {
        let empty = StoreWriteScan.vocabulary(stored: [:], index: index)
        for line in handing {
            // The innermost app function this line sits in, for its owner and its declared parameters.
            let enclosing = index.functions
                .filter { $0.file == file && $0.firstLine <= line.line && line.line <= $0.lastLine }
                .min { ($0.lastLine - $0.firstLine) < ($1.lastLine - $1.firstLine) }
            let signature = enclosing.map { f in
                index.lines(in: file, from: f.firstLine, through: f.bodyLine).map(\.code).joined(separator: " ")
            } ?? ""
            // The enclosing function itself is never a callee here: a bare `read(` inside `read(...)` resolves
            // to it by name, which would wave through a call that is really through a closure parameter.
            let callees = StoreWriteScan.callees(of: [line], file: file, owner: enclosing?.owner, index: index)
                .filter { $0 != enclosing }
            let range = NSRange(line.code.startIndex..., in: line.code)
            let named = callName.matches(in: line.code, range: range).compactMap { m in
                Range(m.range(at: 1), in: line.code).map { String(line.code[$0]) }
            }.filter { !notCalls.contains($0) }
            for call in named where !callees.contains(where: { $0.name == call }) {
                // A call through a closure parameter, accepted only when declared as the injected table read.
                let declared = acceptedClosureTypes.contains { type in
                    signature.range(of: #"\b\#(call)\s*:\s*(@escaping\s+)?\#(NSRegularExpression.escapedPattern(for: type))\b"#,
                                    options: .regularExpression) != nil
                }
                if !declared { return "`\(call)(` is a call this guard cannot follow" }
            }
            let reached = StoreWriteScan.reachable(from: [line], file: file, owner: enclosing?.owner, index: index)
                .filter { $0 != enclosing }
            for function in reached.sorted(by: { ($0.file, $0.firstLine) < ($1.file, $1.firstLine) }) {
                let lines = index.lines(of: function)
                if let write = StoreWriteScan.writes(in: lines, file: function.file,
                                                     function: function.qualifiedName, vocabulary: empty).first {
                    return "\(write.function) reaches a write (\(write.kind)) at \(write.file):\(write.line)"
                }
                if let open = lines.first(where: { $0.code.contains("transaction(") }) {
                    return "\(function.qualifiedName) opens a transaction at \(function.file):\(open.line)"
                }
            }
        }
        return nil
    }

    @Test func noAppCodeSavesThroughASecondContext() {
        let files = AppSourceWalk.files(underAll: [Self.appRoot], floor: AppSourceWalk.appFloor)
        let index = StoreWriteScan.Index(files: files.map { ($0.name, $0.text) })
        var constructions = 0
        var findings: [Finding] = []
        for file in files {
            let result = Self.findings(in: file.text, file: file.name, following: index)
            constructions += result.constructions
            findings += result.findings
        }
        // THE POSITIVE CONTROL: `StoreRows.readInBackground` constructs one, so a walk that found none
        // read nothing, and the empty finding list below would be about nothing (L98).
        #expect(constructions >= 1, Comment(rawValue:
            "no ModelContext construction was found in \(files.count) app files, so this guard read nothing"))
        #expect(findings.isEmpty, Comment(rawValue:
            findings.map { "\($0.file):\($0.line) \($0.why)" }.joined(separator: "; ")
            + ". A second context that saves writes the whole row back and reverts the main context's "
            + "concurrent edits (measured 2026-09-25); read through it, write through the main one."))
    }

    // The refusal, driven: each shape the rule names is caught, and the read-only shape is not.
    @Test func theRuleCatchesEachShapeItNames() {
        let reads = """
            static func read(container: ModelContainer) {
                let context = ModelContext(container)
                _ = try? context.fetch(FetchDescriptor<Prospect>())
            }
            """
        #expect(Self.findings(in: reads, file: "reads").findings.isEmpty)

        let saves = """
            static func write(container: ModelContainer) {
                let context = ModelContext(container)
                try? context.save()
            }
            """
        #expect(Self.findings(in: saves, file: "saves").findings.count == 1)

        let handsOn = """
            static func make(container: ModelContainer) -> ModelContext {
                let context = ModelContext(container)
                return context
            }
            """
        #expect(Self.findings(in: handsOn, file: "handsOn").findings.count == 1)

        let unnamed = """
            static func use(container: ModelContainer) { run(ModelContext(container)) }
            """
        #expect(Self.findings(in: unnamed, file: "unnamed").findings.count == 1)

        let actor = """
            @ModelActor
            actor Writer {}
            """
        #expect(Self.findings(in: actor, file: "actor").findings.count == 1)
    }

    // #4332: a context handed on is FOLLOWED, and accepted only where nothing it reaches can write the store.
    @Test func aHandedOnContextIsFollowedThroughTheAppSource() {
        let reader = """
            enum Reader {
                static func shows(in context: ModelContext) throws -> [Prospect] {
                    try context.fetch(FetchDescriptor<Prospect>())
                }
                static func stamp(in context: ModelContext) throws {
                    try context.save()
                }
                static func deeper(in context: ModelContext) throws { try stamp(in: context) }
            }
            """
        func verdict(_ body: String, signature: String = "container: ModelContainer") -> [Finding] {
            let text = """
                enum Corpus {
                    static func read(\(signature)) throws {
                        let context = ModelContext(container)
                        \(body)
                    }
                }
                """
            let index = StoreWriteScan.Index(files: [("Reader.swift", reader), ("Corpus.swift", text)])
            return Self.findings(in: text, file: "Corpus.swift", following: index).findings
        }
        // Handed to a function that only fetches: accepted.
        #expect(verdict("_ = try Reader.shows(in: context)").isEmpty)
        // Handed to one that saves, directly or two calls down: refused, naming where.
        let saves = verdict("try Reader.stamp(in: context)")
        #expect(saves.count == 1 && saves[0].why.contains("Reader.stamp"), Comment(rawValue: "\(saves)"))
        #expect(verdict("try Reader.deeper(in: context)").count == 1)
        // Handed to a closure nobody declared as the table read: refused.
        #expect(verdict("_ = try read(context)",
                        signature: "container: ModelContainer, read: (ModelContext) throws -> [Prospect]").count == 1)
        // Handed to a closure declared as the injected table read: accepted.
        #expect(verdict("_ = try read(context)",
                        signature: "container: ModelContainer, read: @escaping ScoutLandingStore.SendableRead").isEmpty)
        // Without the app source to follow it through, every hand-on is refused, as before #4332.
        let text = """
            static func read(container: ModelContainer) {
                let context = ModelContext(container)
                _ = try? Reader.shows(in: context)
            }
            """
        #expect(Self.findings(in: text, file: "alone").findings.count == 1)
    }

    // What the closure exemption above stands on: the one production value of each injected read only
    // fetches. The table read is a single fetch; the corrections read calls one function, whose own reach
    // inserts, deletes and saves nothing.
    @Test func theInjectedReadsOnlyFetch() {
        let source = SourceGuardHelper.source("Overture/Integration/ScoutService.swift")
        let lines = source.split(separator: "\n")
        let table = lines.filter { $0.contains("static let readProspectTable") }
        #expect(table.count == 1, Comment(rawValue: "found \(table.count) declarations of the table read"))
        #expect(table.first?.contains("{ try $0.fetch(FetchDescriptor<Prospect>()) }") == true,
                Comment(rawValue: "the table read is no longer a single fetch: \(table)"))
        let overrides = lines.filter { $0.contains("static let readProducerOverrides") }
        #expect(overrides.count == 1, Comment(rawValue: "found \(overrides.count) declarations of the corrections read"))
        #expect(overrides.first?.contains("{ try ProducerOverrideEditing.readOverrides(in: $0) }") == true,
                Comment(rawValue: "the corrections read is no longer the one reader: \(overrides)"))
        let files = AppSourceWalk.files(underAll: [Self.appRoot], floor: AppSourceWalk.appFloor)
        let index = StoreWriteScan.Index(files: files.map { ($0.name, $0.text) })
        let reader = index.functions(named: "readOverrides", owner: "ProducerOverrideEditing")
        #expect(reader.count == 1, Comment(rawValue: "found \(reader.count) corrections readers"))
        let empty = StoreWriteScan.vocabulary(stored: [:], index: index)
        for function in reader + StoreWriteScan.reachable(from: reader.flatMap { index.lines(of: $0) },
                                                          file: reader.first?.file ?? "",
                                                          owner: "ProducerOverrideEditing", index: index) {
            let writes = StoreWriteScan.writes(in: index.lines(of: function), file: function.file,
                                               function: function.qualifiedName, vocabulary: empty)
            #expect(writes.isEmpty, Comment(rawValue: "the corrections read reaches a write: \(writes)"))
        }
    }
}
