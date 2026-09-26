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
// that name must never have `save` or `transaction` called on it in the same file. It cannot follow a
// context handed to another file and saved there, so a construction whose context is RETURNED or passed
// on is reported too, rather than trusted. And any `@ModelActor`, whose whole purpose is a context of its
// own that writes, is refused outright.
@Suite("Only a store's main context ever saves (#4252)")
struct OnlyTheMainContextWritesGuardTests {

    private static let appRoot = RepoRoot.mac.appendingPathComponent("Overture")

    struct Finding: Equatable {
        let file: String
        let line: Int
        let why: String
    }

    // The rule, over one file's text, so the refusal can be driven directly as well as over the app.
    static func findings(in text: String, file: String) -> (constructions: Int, findings: [Finding]) {
        let lines = SwiftSource.scannableLines(in: text, skipping: [])
        // The rest of the block the construction sits in: from its line until the brace that closes the
        // block it opened in. Scoped this way because the same name is routinely a parameter of another
        // function in the same file, and a whole-file search would read that one's uses as this one's.
        func scope(from index: Int) -> String {
            var depth = 0
            var taken: [String] = []
            for (_, source) in lines[index...] {
                taken.append(source)
                depth += source.filter { $0 == "{" }.count - source.filter { $0 == "}" }.count
                if depth < 0 { break }
            }
            return taken.joined(separator: "\n") + "\n"
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
            for escape in ["return \(name)\n", "(\(name))", "(\(name),", " \(name))", ": \(name),", ": \(name))"]
            where code.contains(escape) {
                found.append(Finding(file: file, line: line,
                                     why: "hands `\(name)` on, where this guard cannot see whether it is saved"))
                break
            }
        }
        return (constructions, found)
    }

    @Test func noAppCodeSavesThroughASecondContext() {
        let files = AppSourceWalk.files(underAll: [Self.appRoot], floor: AppSourceWalk.appFloor)
        var constructions = 0
        var findings: [Finding] = []
        for file in files {
            let result = Self.findings(in: file.text, file: file.name)
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
}
