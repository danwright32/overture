import Testing
import Foundation

// #2451: every stored fold key in this app is derived FROM THE SOURCE and checked against the passes
// that realign it, rather than enumerated by hand beside them.
//
// An earlier draft of the plan listed the key-bearing columns by hand. That is a registry standing in
// for a set the code already knows, and a guard built on it checks only what the list remembers, while
// this milestone is actively minting new key-bearing models. The entries that go missing from such a
// list are exactly the ones the realignment was written to protect (L96, L41): a column nobody re-keys
// does not fail, its rows simply stop being found, which is #1784's whole finding.
//
// So this walks the app, finds every `@Model` stored property that a key function's output is written
// into, and fails when one is not covered by a realignment pass. A new key column then fails the suite
// the day it is added rather than being exempted by omission.
//
// SEEN RED FIRST, twice, by adding to `PromotedProducer` a second stored key column
// (`var secondaryKey: String`) filled from `ProducerGate.key` at the insert site: the derivation found
// `PromotedProducer.secondaryKey`, nothing covered it, and `everyKeyBearingFieldIsRealigned` failed
// naming it. Removing the field restored green. `theCoverageListNamesOnlyRealFields` was seen red the
// other way, by renaming a declared property in its `KeyRealignment.Field`.
//
// WHAT THE DERIVATION CAN SEE, stated rather than implied, because a scan's blind spot is where the
// next defect lives. It traces a key from the function that computes it to the model that stores it
// WITHIN ONE FILE, through local bindings and same-file helper functions. A key that reaches a model
// carried inside a VALUE (`ContactRefusal.Scope`, which is how a refusal's `scopeId` is filled) crosses
// a file boundary inside that value and is invisible to it. That one indirection is not left as a hole:
// `aKeyCarriedIntoAModelInsideAValueIsStillCovered` asserts it directly, from the source, and fails if
// a scope is ever constructed from something that is not an organisation key.
@Suite("Every stored fold key has a realignment pass (#2451)")
struct KeyBearingFieldCoverageTests {

    // The three folds whose output is written down. `OrgKey.stored` is `OrgKey.of` plus the namespace,
    // and it is named separately because it is what call sites actually use.
    static let keyFunctions = ["OrgKey.of", "OrgKey.stored", "ProducerGate.key",
                              "VenuePlaces.canonicalKey"]

    struct Field: Hashable, CustomStringConvertible {
        let model: String
        let property: String
        var description: String { "\(model).\(property)" }
    }

    // MARK: - Reading the app

    private struct ModelType: Sendable {
        let name: String
        let properties: [String]
    }

    private struct AppFile: Sendable {
        let name: String
        let code: String
    }

    // The walk is a few seconds over 300-odd files, and four tests ask the same question of it. Held as
    // a `static let` so the app is read ONCE for the whole suite rather than once per test: Swift Testing
    // builds a fresh instance for each test, so an instance-level cache would buy nothing.
    private struct Scan: Sendable {
        let files: [AppFile]
        let models: [ModelType]
        let derived: Set<Field>
    }

    private static let scan: Scan = {
        let suite = KeyBearingFieldCoverageTests()
        let files = suite.appFiles()
        let models = suite.appModels(files)
        return Scan(files: files, models: models,
                    derived: suite.derivedFields(in: files, models: models))
    }()

    private func appFiles() -> [AppFile] {
        AppSourceWalk.appFiles().map {
            AppFile(name: $0.name,
                    code: SwiftSource.scannableLines(in: $0.text, skipping: .scaffolding)
                        .map(\.code).joined(separator: "\n"))
        }
    }

    // Every `@Model final class` in the app, with the stored properties it declares. Read through the
    // shared `SourceGuardHelper.storedPropertyNames`, so this and the two other guards that ask "is
    // every field accounted for" cannot disagree about what counts as storage.
    private func appModels(_ files: [AppFile]) -> [ModelType] {
        var out: [ModelType] = []
        for file in files {
            let code = file.code
            var search = code.startIndex
            while let marker = code.range(of: "@Model", range: search..<code.endIndex) {
                search = marker.upperBound
                guard let declaration = code.range(of: "final class ",
                                                   range: marker.upperBound..<code.endIndex),
                      code[marker.upperBound..<declaration.lowerBound]
                        .allSatisfy({ $0.isWhitespace })
                else { continue }
                let name = String(code[declaration.upperBound...]
                    .prefix { $0.isLetter || $0.isNumber || $0 == "_" })
                guard !name.isEmpty,
                      let brace = code.range(of: "{", range: declaration.upperBound..<code.endIndex),
                      let body = Self.balancedBody(in: code, from: brace.upperBound)
                else { continue }
                out.append(ModelType(name: name,
                                     properties: SourceGuardHelper.storedPropertyNames(inClassBody: body)))
            }
        }
        return out
    }

    // MARK: - What counts as a key expression, per file

    // Names that carry a fold key in this file: the fold functions themselves, anything bound to one,
    // and any same-file function that returns one. Computed to a fixed point, because a call site is
    // routinely two hops from the fold (`let key = normalize(raw)`, where `normalize` is one line
    // returning `ProducerGate.key(raw)`).
    private func keyProducers(in code: String) -> Set<String> {
        var producers = Set(Self.keyFunctions)
        let lines = code.components(separatedBy: "\n")
        var declarations: [(name: String, value: String)] = []

        for (index, line) in lines.enumerated() {
            declarations.append(contentsOf: Self.bindings(in: line))
            guard let function = line.range(of: "func ") else { continue }
            let name = String(line[function.upperBound...]
                .prefix { $0.isLetter || $0.isNumber || $0 == "_" })
            guard !name.isEmpty else { continue }
            declarations.append((name, Self.bodyFollowing(line: index, in: lines)))
        }

        // Bounded rather than `while changed`, so a pathological file cannot spin. Four hops is far more
        // than anything in this app needs, and a fifth would be a call chain nobody should be writing.
        // A binding inherits keyness only by CALLING a key producer, never by merely mentioning one, and
        // the difference is not pedantry: `let existing = byKey[key]` mentions a key and holds a room's
        // display NAME, so treating a mention as inheritance made `VenuePlaceAnswer.venueName` look like
        // a key column and demanded a realignment pass for the words Dan reads on a card.
        //
        // A SINK is the other way round and is deliberately looser: `VenuePlaceAnswer(venueKey: key,
        // ...)` hands a key over by name with no call in sight, and that is the shape being looked for.
        for _ in 0..<4 {
            var grew = false
            for declaration in declarations where !producers.contains(declaration.name) {
                guard producers.contains(where: {
                    Self.calls($0, in: declaration.value)
                }) else { continue }
                producers.insert(declaration.name)
                grew = true
            }
            if !grew { break }
        }
        return producers
    }

    // Every `let`/`var` binding on one line, each with ONLY its own right-hand side.
    //
    // The region matters more than it looks. A guard routinely binds twice on one line
    // (`guard let presenter = p.presenter, let orgKey = OrgKey.stored(for: presenter) else ...`), and
    // taking the first binding's value as "everything after the first equals" swallows the second one's,
    // which makes `presenter` look like a fold key. That is not a harmless over-report: it spreads,
    // because a producer is anything built from a producer, so one wrong binding turns a display name
    // into a key column and the guard starts demanding a realignment pass for a person's name.
    static func bindings(in line: String) -> [(name: String, value: String)] {
        var starts: [(name: String, valueStart: String.Index)] = []
        for keyword in ["let ", "var "] {
            var search = line.startIndex
            while let hit = line.range(of: keyword, range: search..<line.endIndex) {
                search = hit.upperBound
                let name = String(line[hit.upperBound...]
                    .prefix { $0.isLetter || $0.isNumber || $0 == "_" })
                guard !name.isEmpty,
                      let equals = line.range(of: "=", range: hit.upperBound..<line.endIndex),
                      // `==` is a comparison, never a binding's assignment.
                      equals.upperBound == line.endIndex || line[equals.upperBound] != "="
                else { continue }
                starts.append((name, equals.upperBound))
            }
        }
        starts.sort { $0.valueStart < $1.valueStart }

        return starts.enumerated().map { position, binding in
            let end = position + 1 < starts.count ? starts[position + 1].valueStart : line.endIndex
            guard binding.valueStart <= end else { return (binding.name, "") }
            var value = String(line[binding.valueStart..<end])
            // A second binding on the line is preceded by ", let x" or ", var x", and the " else {" of a
            // guard belongs to neither. Cutting both keeps a value to exactly what was assigned.
            for terminator in [", let ", ", var ", " else "] {
                if let cut = value.range(of: terminator) { value = String(value[..<cut.lowerBound]) }
            }
            return (binding.name, value)
        }
    }

    // MARK: - The derivation

    private func derivedFields(in files: [AppFile], models: [ModelType]) -> Set<Field> {
        var found = Set<Field>()

        for file in files {
            let producers = keyProducers(in: file.code)
            for model in models {
                // A construction of the model, with a key expression handed to one of its stored
                // properties by name.
                for arguments in Self.argumentLists(callingInto: model.name, in: file.code) {
                    for (label, value) in Self.labelledArguments(arguments)
                    where model.properties.contains(label) {
                        guard producers.contains(where: { Self.mentionsIdentifier($0, in: value) })
                        else { continue }
                        found.insert(Field(model: model.name, property: label))
                    }
                }
                // An assignment onto the property afterwards. Deliberately not narrowed to a receiver of
                // the right type, which text cannot know: it over-reports across models sharing a
                // property name, and over-reporting here can only demand MORE coverage.
                for property in model.properties {
                    for value in Self.assignedValues(to: property, in: file.code)
                    where producers.contains(where: { Self.mentionsIdentifier($0, in: value) }) {
                        found.insert(Field(model: model.name, property: property))
                    }
                }
            }
        }
        return found
    }

    // MARK: - The assertions

    // The floor, before anything else. A scan that finds nothing reports a clean app, and "I checked
    // everything and found no problem" is the most different thing there is from "I checked nothing"
    // (#2311). Four is what the app holds today and the number is a this-still-resolves assertion, not
    // a pin on how many key columns exist.
    @Test func theDerivationStillFindsTheKeyColumnsTheAppIsKnownToHold() {
        let derived = Self.scan.derived
        #expect(derived.count >= 4, Comment(rawValue:
                "the derivation found \(derived.count) key-bearing fields, which is fewer than this app "
                + "is known to hold. That is a broken scan, not a clean app: with nothing found, the "
                + "coverage check below passes over every field it exists to check."))
        for known in [Field(model: "OrgReachabilityAnswer", property: "orgKey"),
                      Field(model: "VenuePlaceAnswer", property: "venueKey"),
                      Field(model: "PromotedProducer", property: "orgKey"),
                      Field(model: "DemotedHouse", property: "orgKey")] {
            #expect(derived.contains(known), "the derivation stopped finding \(known)")
        }
    }

    // The check itself.
    @Test func everyKeyBearingFieldIsRealigned() {
        let uncovered = Self.scan.derived
            .filter { !KeyRealignment.covers(model: $0.model, property: $0.property) }
            .sorted { $0.description < $1.description }
        #expect(uncovered.isEmpty, Comment(rawValue:
                "stored fold keys with no realignment pass: \(uncovered.map(\.description)). A column "
                + "nobody re-keys does not fail when its fold changes: its rows simply stop being found."))
    }

    // The other direction, which is what stops the coverage list drifting into fiction: every field it
    // declares must be a stored property that really exists on a real `@Model`.
    @Test func theCoverageListNamesOnlyRealFields() {
        let models = Self.scan.models
        #expect(!models.isEmpty, "no models were read, so this guard checked nothing")
        for field in KeyRealignment.coverage {
            let model = models.first { $0.name == field.model }
            #expect(model != nil, "\(field.model) is realigned but is not a @Model in this app")
            #expect(model?.properties.contains(field.property) == true,
                    "\(field.model).\(field.property) is realigned but is not a stored property of it")
        }
    }

    // Built is not wired (L3). A declared pass that nothing calls is indistinguishable from no pass at
    // all, and it would read as covered here.
    @Test func everyDeclaredPassRunsAtLaunch() {
        let launch = SourceGuardHelper.source("Overture/Domain/LaunchMigrations.swift")
        #expect(!launch.isEmpty, "LaunchMigrations was not read, so this guard checked nothing")
        for pass in Set(KeyRealignment.coverage.map(\.pass)).sorted() {
            #expect(launch.contains("\(pass).run(in: context)"),
                    "\(pass) realigns a stored key and is never called at launch")
        }
    }

    // The one indirection the derivation cannot see, asserted directly rather than left as a hole.
    //
    // `RefusedContactAddress.scopeId` holds an `OrgKey.stored` key on an organisation-scoped row, but it
    // is filled from `scope.id`, so no line in `ContactRefusal.swift` mentions a fold at all. What makes
    // it key-bearing lives at the CONSTRUCTION of the scope, in another file: so that is what this
    // checks, and it fails if an organisation scope is ever built from something that is not a key.
    @Test func aKeyCarriedIntoAModelInsideAValueIsStillCovered() {
        var constructions = 0
        for file in Self.scan.files where file.name != "ContactRefusal.swift" {
            let producers = keyProducers(in: file.code)
            for value in Self.argumentLists(callingInto: ".organisation", in: file.code) {
                constructions += 1
                #expect(producers.contains(where: { Self.mentionsIdentifier($0, in: value) }),
                        Comment(rawValue:
                        "\(file.name) builds an organisation-scoped refusal from \"\(value)\", which is "
                        + "not an organisation key. A refusal written against the wrong key silently "
                        + "spares the address it names and strikes somebody else's (L75)."))
            }
        }
        #expect(constructions > 0,
                "no organisation-scoped refusal is written anywhere, so this guard checked nothing")
        #expect(KeyRealignment.covers(model: "RefusedContactAddress", property: "scopeId"),
                "the refusal ledger's organisation key has no realignment pass")
    }

    // MARK: - Small source readers

    // The body between a `{` at `start` and its matching `}`.
    private static func balancedBody(in text: String, from start: String.Index) -> String? {
        var depth = 1
        var index = start
        while index < text.endIndex {
            if text[index] == "{" { depth += 1 }
            if text[index] == "}" {
                depth -= 1
                if depth == 0 { return String(text[start..<index]) }
            }
            index = text.index(after: index)
        }
        return nil
    }

    // The lines from a `func` header to its matching close brace, joined. Used to ask whether a helper
    // returns a fold key.
    private static func bodyFollowing(line: Int, in lines: [String]) -> String {
        var depth = 0
        var opened = false
        var body: [String] = []
        for index in line..<lines.count {
            let text = lines[index]
            body.append(text)
            depth += text.filter { $0 == "{" }.count
            if depth > 0 { opened = true }
            depth -= text.filter { $0 == "}" }.count
            if opened, depth <= 0 { break }
        }
        return body.joined(separator: "\n")
    }

    // The argument text of every call spelled `<callee>(`, balanced, so a nested call's own parentheses
    // do not end it early.
    static func argumentLists(callingInto callee: String, in text: String) -> [String] {
        var out: [String] = []
        var search = text.startIndex
        while let hit = text.range(of: callee + "(", range: search..<text.endIndex) {
            search = hit.upperBound
            // Not a call into this callee at all if the name runs on from something else
            // (`FooRefusedContactAddress(`), which text alone would otherwise read as a match.
            if hit.lowerBound > text.startIndex, !callee.hasPrefix(".") {
                let previous = text[text.index(before: hit.lowerBound)]
                if previous.isLetter || previous.isNumber || previous == "_" || previous == "." {
                    continue
                }
            }
            var depth = 1
            var index = hit.upperBound
            var argument = ""
            while index < text.endIndex, depth > 0 {
                let character = text[index]
                if character == "(" { depth += 1 }
                if character == ")" {
                    depth -= 1
                    if depth == 0 { break }
                }
                argument.append(character)
                index = text.index(after: index)
            }
            out.append(argument)
        }
        return out
    }

    // `label: value` pairs, split at TOP-LEVEL commas only, so a nested call's own arguments stay with
    // the argument they belong to.
    static func labelledArguments(_ arguments: String) -> [(String, String)] {
        var pieces: [String] = []
        var current = ""
        var depth = 0
        for character in arguments {
            if character == "(" || character == "[" { depth += 1 }
            if character == ")" || character == "]" { depth -= 1 }
            if character == ",", depth == 0 {
                pieces.append(current)
                current = ""
                continue
            }
            current.append(character)
        }
        pieces.append(current)

        return pieces.compactMap { piece in
            let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let colon = trimmed.firstIndex(of: ":") else { return nil }
            let label = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty, label.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" })
            else { return nil }
            return (label, String(trimmed[trimmed.index(after: colon)...]))
        }
    }

    // The right-hand side of every `.<property> =` in the text, to the end of its line.
    static func assignedValues(to property: String, in text: String) -> [String] {
        var out: [String] = []
        for line in text.components(separatedBy: "\n") {
            guard let hit = line.range(of: ".\(property)") else { continue }
            let rest = line[hit.upperBound...]
            guard let equals = rest.firstIndex(of: "=") else { continue }
            let between = rest[..<equals]
            guard between.allSatisfy({ $0.isWhitespace }) else { continue }
            // `==` is a comparison, and reading one as an assignment is how `row.orgKey == key` came to
            // report that a key had been WRITTEN into three unrelated models.
            let after = rest.index(after: equals)
            guard after == rest.endIndex || rest[after] != "=" else { continue }
            out.append(String(rest[after...]))
        }
        return out
    }

    // A whole-identifier match that is immediately CALLED. See the fixed point above for why calling and
    // mentioning are treated differently.
    static func calls(_ identifier: String, in text: String) -> Bool {
        var search = text.startIndex
        while let hit = text.range(of: identifier + "(", range: search..<text.endIndex) {
            search = hit.upperBound
            let beforeIsIdentifier = hit.lowerBound > text.startIndex
                && Self.isIdentifierCharacter(text[text.index(before: hit.lowerBound)])
            if !beforeIsIdentifier { return true }
        }
        return false
    }

    // A whole-identifier match, so a producer named `key` is not found inside `venueKey` or `monkey`.
    static func mentionsIdentifier(_ identifier: String, in text: String) -> Bool {
        var search = text.startIndex
        while let hit = text.range(of: identifier, range: search..<text.endIndex) {
            search = hit.upperBound
            let beforeIsIdentifier = hit.lowerBound > text.startIndex
                && Self.isIdentifierCharacter(text[text.index(before: hit.lowerBound)])
            let afterIsIdentifier = hit.upperBound < text.endIndex
                && Self.isIdentifierCharacter(text[hit.upperBound])
            if !beforeIsIdentifier && !afterIsIdentifier { return true }
        }
        return false
    }

    private static func isIdentifierCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }
}
