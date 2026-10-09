import Testing
import Foundation
import SwiftData

// #4625: every function that writes a small table SAVES, or is only ever reached through functions that do, because
// the queue engine only sees a small table once it is saved.
//
// WHY. Since the switch (#4358 E4d) the queue draws the engine's pass, and the engine takes a small table in by the
// saves it hears (`AppSchemaInputClass.smallTableInput`): a struck address, a skipped town or a producer correction
// left unsaved in the main context reaches the queue at the NEXT save, whenever that is, where the old `@Query` path
// saw it at once. Every control saved at once when the switch landed, and nothing said they had to, so a control
// written later that deferred its save would leave the queue drawing the old value with no error anywhere.
//
// WHAT IS DERIVED, never listed by hand (L96, L41):
//   - the small tables, from `AppSchemaInputClass.byModel`;
//   - their stored fields, from each model's `scopeKeyPaths` (held to the schema by `ScopeFieldsMatchTheSchemaTests`);
//   - every function in the app that writes one: constructs a row, assigns one of those fields, or deletes inside a
//     file declaring a small table or a function naming one;
//   - who calls each, by `Type.function(` anywhere or by the bare name inside the writer's own file.
// A writer must save a CONTEXT (`context.save(`, `context.saveOrWarn(`, or `context.save` handed on; another store's
// `save` is not one) AFTER its first write, or every function calling it must save after the call, up to three calls
// up (a launch migration's helper is saved by `LaunchMigrations.run`, two calls up), or it is named in `exempt` with
// the reason the engine still sees its writes. An initializer is never a writer: it fills a row nothing has inserted.
//
// WHAT IT CANNOT SEE, stated so nobody reads more into a pass than it measures: a field shared with a model that is
// not a small table (`id`, `isActive`, `notes`, `venueName` on 2026-10-09) counts only in a function that names a
// small table; a write reached through a variable whose type the source never spells is invisible; a caller that is
// a computed property rather than a function (a view's `body`) is not counted as one that saves; and "after" is the
// order of the text, so a save on a branch the write's path never takes, or in a closure that never runs, still
// counts.
@Suite("Every function that writes a small table saves at once (#4625)")
struct SmallTableWritesSaveAtOnceTests {

    /// Writers whose change reaches the engine without a save of their own or of a caller, by file, type and function.
    /// Each key must name exactly ONE writer, so a second overload of an exempt function is judged, not excused.
    static let exempt: [String: String] = [
        "ScoutExtractIngest.swift ScoutExtractIngest.land": "A scout landing: the engine holds its landing "
            + "generation around it and the landing's closing save carries every source write (#4358 E4d).",
        "ScoutExtractIngest.swift ScoutExtractIngest.landCaptured": "A scout landing, saved at its close (#4358 E4d).",
        "ScoutExtractIngest.swift ScoutExtractIngest.recordSuccess": "A scout landing, saved at its close (#4358 E4d).",
        "ScoutExtractIngest.swift ScoutExtractIngest.recordPartialCheck": "A scout landing, saved at its close "
            + "(#4358 E4d).",
        "ScoutService.swift ScoutService.landCaptured": "A scout landing, saved at its close (#4358 E4d).",
        "ScoutService.swift ScoutService.landNative": "A scout landing, saved at its close (#4358 E4d).",
        "DebugStaging.swift DebugStaging.stageReachabilityCompetition": "Debug staging, which seeds a debug store "
            + "before the queue engine starts and saves once at the end of staging.",
        "DebugStaging.swift DebugStaging.clearDebugLeads": "Debug staging, which clears a debug store and saves once "
            + "at the end.",
    ]

    struct Function: Hashable {
        let file: String
        let name: String
        let line: Int
        let owner: String?
        // A model class declared in this file: its instance methods are called on a row, `row.name(`, so a member call
        // in the same file is one of theirs.
        let ownerIsAClassHere: Bool
        let body: String
        var key: String { "\(file) \(owner ?? "<top level>").\(name)" }
    }

    struct Writer: Hashable, CustomStringConvertible {
        let function: Function
        let saves: Bool
        var key: String { function.key }
        var description: String { "\(function.file):\(function.line) \(function.name)" }
    }

    static var smallTables: [String] {
        AppSchemaInputClass.byModel.compactMap { name, kind in
            if case .smallTableInput = kind { return name }
            return nil
        }.sorted()
    }

    /// Stored field names by model name, from the scope lists every model keeps against its schema.
    static var fields: [String: Set<String>] {
        var out: [String: Set<String>] = [:]
        for model in AppSchema.models {
            guard let observed = model as? any ScopeObserved.Type else { continue }
            out[String(describing: model)] = Set(observed.scopeKeyPaths.compactMap {
                String(describing: $0).split(separator: ".").last.map(String.init)
            })
        }
        return out
    }

    // A save of a model CONTEXT, called or handed on, and never another store's (`VoiceGuidanceStore.save`) or a copy
    // constant (`VenueNameCopy.save`). Built where it is used rather than held as a static, so the suite holds no
    // process wide state (`SharedStateWiringTests`).
    static func contextSave() -> Regex<AnyRegexOutput> {
        try! Regex(#"[A-Za-z]*[cC]ontext\??\.save(?:OrWarn(?:SendNotConfirmed)?)?(?=[(,)\s])"#)
    }

    /// Whether `body` saves a context after `position`, in the order the text runs.
    static func saves(_ body: String, after position: String.Index, using save: Regex<AnyRegexOutput>) -> Bool {
        body[position...].contains(save)
    }

    /// One file read once: every function and initializer in it, with its body found by balancing braces from the
    /// first one opened outside the parameter list (a default closure in a signature is not the body) and the type it
    /// sits in, and the names of the types the file declares.
    ///
    /// Each regex runs only on a line a plain substring check has already shown could match, and the enclosing type is
    /// found from a list taken in the same pass: the first version ran the type regex backwards over every earlier
    /// line for every function, and took 37 seconds over the app.
    static func read(_ file: AppSourceWalk.File) -> (functions: [Function], declaredClasses: [String]) {
        // A literal's contents blanked, so a brace or paren inside a string cannot move a body's edges.
        let literal = try! Regex(#""(?:[^"\\]|\\.)*""#)
        let declaration = try! Regex(#"(?:^|[^A-Za-z0-9_])(?:func\s+([A-Za-z_][A-Za-z0-9_]*)|(init)\s*[(<?])"#)
        let typeDeclaration = try! Regex(
            #"^( *)(?:[A-Za-z@()]+\s+)*(?:enum|struct|class|extension|actor)\s+([A-Za-z_][A-Za-z0-9_]*)"#)
        let lines = SwiftSource.scannableLines(in: file.text, skipping: []).map { entry in
            (line: entry.line, code: entry.code.contains("\"") ? entry.code.replacing(literal, with: "\"\"") : entry.code)
        }
        func declared(_ code: String) -> Regex<AnyRegexOutput>.Match? {
            guard code.contains("func ") || code.contains("init") else { return nil }
            return code.firstMatch(of: declaration)
        }
        // Each type with the lines its body spans, so a function's owner is the innermost type that CONTAINS it, never
        // merely the last one declared above it (a local function after a nested type is not in that type).
        var types: [(start: Int, end: Int, name: String)] = []
        var classes: [String] = []
        for (index, entry) in lines.enumerated() {
            let code = entry.code
            guard code.contains("enum ") || code.contains("struct ") || code.contains("class ")
                    || code.contains("extension ") || code.contains("actor "),
                  let type = code.firstMatch(of: typeDeclaration),
                  let name = type.output[2].substring.map(String.init) else { continue }
            var depth = 0, started = false, end = index
            spans: for (offset, later) in lines[index...].enumerated() {
                for ch in later.code {
                    if ch == "{" { depth += 1; started = true }
                    if ch == "}" { depth -= 1 }
                }
                end = index + offset
                if started && depth <= 0 { break spans }
                if !started && offset > 40 { break spans }
            }
            guard started else { continue }
            types.append((index, end, name))
            if code.contains("class \(name)") { classes.append(name) }
        }
        var found: [Function] = []
        for (index, entry) in lines.enumerated() {
            guard let match = declared(entry.code) else { continue }
            let name = (match.output[1].substring ?? match.output[2].substring).map(String.init) ?? "?"
            var depth = 0, parens = 0
            var started = false, sawParen = false
            var body: [String] = []
            scan: for later in lines[index...] {
                if !started, later.line != entry.line, parens == 0,
                   declared(later.code) != nil || later.code.trimmingCharacters(in: .whitespaces).hasPrefix("}") {
                    body = []
                    break
                }
                body.append(later.code)
                for ch in later.code {
                    if !started {
                        if ch == "(" { parens += 1; sawParen = true }
                        if ch == ")" { parens -= 1 }
                        if ch == "{", parens == 0, sawParen { depth = 1; started = true }
                        continue
                    }
                    if ch == "{" { depth += 1 }
                    if ch == "}" { depth -= 1 }
                }
                if started && depth <= 0 { break scan }
                if !started && body.count > 40 { body = []; break scan }
            }
            guard started else { continue }
            let owner = types.last { $0.start < index && index <= $0.end }?.name
            found.append(Function(file: file.name, name: name, line: entry.line, owner: owner,
                                  ownerIsAClassHere: owner.map(classes.contains) ?? false,
                                  body: body.joined(separator: "\n")))
        }
        return (found, classes)
    }

    static func writers(in read: [(functions: [Function], declaredClasses: [String])]) -> [Writer] {
        let tables = smallTables
        let fields = Self.fields
        let tableFields = Set(tables.flatMap { fields[$0] ?? [] })
        let otherFields = Set(fields.filter { !tables.contains($0.key) }.values.flatMap { $0 })
        let alternation = tables.joined(separator: "|")
        let construct = try! Regex("(?:^|[^<A-Za-z0-9_.])(?:\(alternation))\\(")
        let names = try! Regex("(?:^|[^A-Za-z0-9_])(?:\(alternation))(?:[^A-Za-z0-9_]|$)")
        let assignment = try! Regex(#"\.([A-Za-z_][A-Za-z0-9_]*)\s*(?:=(?!=)|\+=|-=)"#)
        let save = contextSave()
        var found: [Writer] = []
        for file in read {
            let declaresATable = file.declaredClasses.contains { tables.contains($0) }
            for function in file.functions where function.name != "init" {
                let body = function.body
                let namesATable = tables.contains { body.contains($0) } && body.contains(names)
                // Where each kind of write first happens, so the save can be asked for AFTER it.
                var writes: [String.Index] = []
                if body.contains("=") {
                    writes += body.matches(of: assignment).filter { match in
                        let field = String(match.output[1].substring ?? "")
                        guard tableFields.contains(field) else { return false }
                        return !otherFields.contains(field) || namesATable
                    }.map(\.range.lowerBound)
                }
                if declaresATable || namesATable, let delete = body.range(of: ".delete(") {
                    writes.append(delete.lowerBound)
                }
                if namesATable, let made = body.firstMatch(of: construct) { writes.append(made.range.lowerBound) }
                guard let first = writes.min() else { continue }
                found.append(Writer(function: function, saves: saves(body, after: first, using: save)))
            }
        }
        return found.sorted { ($0.function.file, $0.function.line) < ($1.function.file, $1.function.line) }
    }

    static func writers(in files: [AppSourceWalk.File]) -> [Writer] { writers(in: files.map(read)) }

    /// The functions that call `target`, each with where its first call is: `Type.name(` (or `Self.name(`) anywhere,
    /// or the bare name in its own file. Where a call sits in a function nested in another, only the innermost is the
    /// caller.
    static func callers(of target: Function, among everything: [Function]) -> [(function: Function, call: String.Index)] {
        let qualified = try! Regex("(?:\(target.owner ?? "NoOwner")|Self)\\.\(target.name)\\(")
        // In the target's own file: the bare name, or `self.name(`. A member call on some other object
        // (`list.add(`) is not a call of it, unless the target is an instance method of a model class declared here,
        // which is called on a row.
        let bare = try! Regex(target.ownerIsAClassHere
            ? "(?:^|[^A-Za-z0-9_])\(target.name)\\("
            : "(?:^|[^A-Za-z0-9_.]|self\\.)\(target.name)\\(")
        let calling: [(function: Function, call: String.Index)] = everything.compactMap { function in
            guard !(function.file == target.file && function.line == target.line) else { return nil }
            let call = function.body.firstMatch(of: qualified)
                ?? (function.file == target.file ? function.body.firstMatch(of: bare) : nil)
            return call.map { (function, $0.range.lowerBound) }
        }
        return calling.filter { outer in
            !calling.contains { inner in
                inner.function != outer.function && inner.function.file == outer.function.file
                    && inner.function.line > outer.function.line && outer.function.body.contains(inner.function.body)
            }
        }
    }

    /// Why `target`'s write may sit unsaved, or nothing when every way to reach it saves after the call, within three
    /// calls.
    static func unsavedPaths(from writer: Function, to target: Function, among everything: [Function],
                             using save: Regex<AnyRegexOutput>, depth: Int = 1, visited: Set<String> = []) -> [String] {
        let origin = "\(writer.file):\(writer.line) \(writer.name)"
        let calling = callers(of: target, among: everything)
        if calling.isEmpty {
            return [depth == 1
                ? "\(origin) writes a small table, does not save after it, and no function calls it that could"
                : "\(origin) writes a small table without saving, and is reached through \(target.file):"
                    + "\(target.line) \(target.name), which does not save after the call and which nothing that "
                    + "saves calls"]
        }
        var problems: [String] = []
        for caller in calling where !saves(caller.function.body, after: caller.call, using: save) {
            let function = caller.function
            let mark = "\(function.file):\(function.line)"
            if depth >= 3 || visited.contains(mark) {
                problems.append("\(origin) writes a small table without saving, and is reached from \(function.file):"
                    + "\(function.line) \(function.name), and nothing on that path saves after the call")
                continue
            }
            problems += unsavedPaths(from: writer, to: function, among: everything, using: save, depth: depth + 1,
                                     visited: visited.union([mark]))
        }
        return problems
    }


    static func unsaved(in read: [(functions: [Function], declaredClasses: [String])]) -> [String] {
        let everything = read.flatMap(\.functions)
        let save = contextSave()
        return writers(in: read).filter { !$0.saves && exempt[$0.key] == nil }
            .flatMap { unsavedPaths(from: $0.function, to: $0.function, among: everything, using: save) }
    }

    static func unsaved(in files: [AppSourceWalk.File]) -> [String] { unsaved(in: files.map(read)) }

    @Test func everyWriterOfASmallTableSavesAtOnce() {
        let files = AppSourceWalk.appFiles().map(Self.read)
        let writers = Self.writers(in: files)
        // A scan that found no writer would pass the assertion below on nothing (L98). These are the tables Dan
        // edits most, so each must be found.
        for (file, name) in [("ExcludedTown.swift", "exclude"), ("ProducerOverride.swift", "promote"),
                             ("ContactRefusal.swift", "refuse"), ("WatchlistEditing.swift", "add"),
                             ("SourcesView.swift", "setClientTag")] {
            #expect(writers.contains { $0.function.file == file && $0.function.name == name }, Comment(rawValue:
                "the scan did not find \(file) \(name), so it cannot be trusted to find a writer that does not save"))
        }
        let problems = Self.unsaved(in: files)
        #expect(problems.isEmpty, Comment(rawValue:
            "the queue engine sees a small table only once it is saved, so a write left unsaved shows the old value "
            + "until some later save (#4625):\n" + problems.joined(separator: "\n")))
    }

    @Test func everyExemptionStillNamesAWriter() {
        let writers = Self.writers(in: AppSourceWalk.appFiles())
        for key in Self.exempt.keys.sorted() {
            let named = writers.filter { $0.key == key }
            let sameFile = writers.filter { key.hasPrefix($0.function.file + " ") }.map(\.key)
            #expect(named.count == 1, Comment(rawValue:
                "\(key) is exempt and names \(named.count) writers: none means the exemption excuses nothing and "
                + "should go, more than one means an overload is being excused unread. Writers in that file: "
                + "\(sameFile)"))
        }
    }

    // THE POSITIVE CONTROL on a planted file: a writer that saves, one that does not, a helper whose caller saves, a
    // helper whose caller does not, and a signature whose default closure must not end the body. Without it, an
    // empty problem list could be a scan that matches nothing (L159).
    @Test func thePlantedWritersAreJudgedAsWritten() {
        let planted = AppSourceWalk.File(url: URL(fileURLWithPath: "/planted/Planted.swift"), name: "Planted.swift",
                                         text: """
            enum Planted {
                static func savesAtOnce(_ name: String, in context: ModelContext) {
                    context.insert(ExcludedTown(town: name))
                    try? context.save()
                }
                static func leavesItUnsaved(_ key: String, in context: ModelContext) {
                    context.insert(PromotedProducer(orgKey: key))
                }
                private static func helper(_ source: WatchedSource) {
                    source.hasUnreadChanges = true
                }
                static func savingCaller(_ source: WatchedSource, in context: ModelContext) {
                    helper(source)
                    context.saveOrWarn(org: "", feedback: feedback)
                }
                private static func unsavedHelper(_ source: WatchedSource) {
                    source.lastContentHash = nil
                }
                static func forgetfulCaller(_ source: WatchedSource) {
                    unsavedHelper(source)
                }
                static func defaulted(_ key: String, make: () -> Int = {
                    0
                }, in context: ModelContext) {
                    context.insert(DemotedHouse(orgKey: key))
                }
                static func savesFirst(_ name: String, in context: ModelContext) {
                    try? context.save()
                    context.insert(AllowedSeedTown(town: name))
                }
                static func savesAnotherStore(_ name: String, in context: ModelContext, url: URL) {
                    context.insert(ExcludedTown(town: name))
                    _ = VoiceGuidanceStore.save(name, to: url)
                }
                private static func lonelyHelper(_ source: WatchedSource) {
                    source.lastContentHash = nil
                }
                static func impostor(_ list: Lister, in context: ModelContext) {
                    list.lonelyHelper()
                    try? context.save()
                }
            }
            """)
        let writers = Set(Self.writers(in: [planted]).map(\.function.name))
        #expect(writers == ["savesAtOnce", "leavesItUnsaved", "helper", "unsavedHelper", "defaulted", "savesFirst",
                            "savesAnotherStore", "lonelyHelper"], Comment(rawValue: "\(writers.sorted())"))
        let problems = Self.unsaved(in: [planted])
        // A member call on some other object of the same name is not a call of the helper, so it cannot save for it.
        #expect(problems.contains { $0.contains("lonelyHelper") }, Comment(rawValue: "\(problems)"))
        // The review of #4625: a save BEFORE the write, and another store's save, are not the write being saved.
        #expect(problems.contains { $0.contains("savesFirst") }, Comment(rawValue: "\(problems)"))
        #expect(problems.contains { $0.contains("savesAnotherStore") }, Comment(rawValue: "\(problems)"))
        #expect(problems.contains { $0.contains("leavesItUnsaved") }, Comment(rawValue: "\(problems)"))
        #expect(problems.contains { $0.contains("defaulted") }, Comment(rawValue: "\(problems)"))
        #expect(problems.contains { $0.contains("unsavedHelper") && $0.contains("forgetfulCaller") },
                Comment(rawValue: "\(problems)"))
        #expect(!problems.contains { $0.contains("savesAtOnce") || $0.contains(" helper ") },
                Comment(rawValue: "\(problems)"))
    }
}
