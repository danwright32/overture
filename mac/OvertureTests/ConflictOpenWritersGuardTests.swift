import Testing
import Foundation

// #3968: the comment above `Prospect.conflictOpen` is the list a reader enumerates from when changing what
// "blocked" means, since the flag also backs a SwiftData #Predicate. It named `restoreConflict`, which
// assigns nothing, and did not name `restoreConflictClearance`, which is the real writer and which
// QueueUndoStack calls directly. The count was right by accident and the names were not (L96).
//
// So the list is DERIVED here from the app's own code and compared both ways against what the comment
// says: every function that assigns the flag must be named, and every name must assign it. The same for
// the files outside the model that call those writers, so the comment cannot lose a call site again.
@Suite("The conflictOpen writer comment matches the code (#3968)")
struct ConflictOpenWritersGuardTests {

    private static let model = "Prospect.swift"

    // The comment block directly above the stored property, with the `//` markers removed and the lines
    // joined, so a sentence wrapped across two lines still reads as one.
    private static func documentation() -> String? {
        let lines = SourceGuardHelper.source("Overture/Domain/Prospect.swift").components(separatedBy: "\n")
        guard let declaration = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("var conflictOpen:")
        }) else { return nil }
        var block: [String] = []
        var index = declaration - 1
        while index >= 0 {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("//") else { break }
            block.insert(String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces), at: 0)
            index -= 1
        }
        return block.joined(separator: " ")
    }

    // The names a labelled sentence of the comment lists, read up to the sentence's full stop.
    private static func listed(after label: String, in doc: String) -> Set<String>? {
        guard let start = doc.range(of: label),
              let stop = doc.range(of: ".", range: start.upperBound..<doc.endIndex) else { return nil }
        let sentence = doc[start.upperBound..<stop.lowerBound]
        let names = sentence
            .components(separatedBy: CharacterSet(charactersIn: ",` ").union(.whitespaces))
            .filter { !$0.isEmpty && $0 != "and" }
        return Set(names)
    }

    // Every (file, enclosing function) that assigns the flag, read from code with comments stripped.
    private static func derivedWriters() -> [(file: String, function: String)] {
        // No `\b`: Swift's default word boundary is Unicode's, under which `p.conflictOpen` is ONE word, so
        // `\bconflictOpen` never matched an assignment through a receiver. Seen: a `p.conflictOpen = true`
        // planted in DayOff passed this guard until the boundary was spelled out (#3968).
        let assignment = try! Regex(#"(?:^|[^A-Za-z0-9_])conflictOpen\s*=(?!=)"#)
        let function = try! Regex(#"(?:^|[^A-Za-z0-9_])func\s+(\w+)"#)
        var found: [(file: String, function: String)] = []
        for file in AppSourceWalk.appFiles() {
            let lines = SwiftSource.scannableLines(in: file.text, skipping: [])
            for (position, entry) in lines.enumerated() where entry.code.contains(assignment) {
                if entry.code.trimmingCharacters(in: .whitespaces).hasPrefix("var conflictOpen") { continue }
                let enclosing = lines[..<position].reversed().lazy
                    .compactMap { $0.code.firstMatch(of: function) }
                    .first.map { String($0.output[1].substring ?? "") } ?? "<top level>"
                found.append((file: file.name, function: enclosing))
            }
        }
        return found
    }

    // Files other than the model that call a writer, or call a model function that calls one (one hop,
    // which is how `restoreConflict` reaches the flag).
    private static func derivedCallerFiles(writers: Set<String>) -> Set<String> {
        let modelSource = SourceGuardHelper.source("Overture/Domain/Prospect.swift")
        let declared = modelSource.matches(of: try! Regex(#"(?:^|[^A-Za-z0-9_])func\s+(\w+)\("#))
            .compactMap { $0.output[1].substring.map(String.init) }
        let relays = declared.filter { name in
            guard !writers.contains(name),
                  let body = SourceGuardHelper.bodyOfFunction(named: name, in: modelSource) else { return false }
            return writers.contains { body.contains("\($0)(") }
        }
        // An INSTANCE call, on a receiver spelled in lower case (`prospect.`, `model.`, `p?.`). A static of
        // the same name on another type (`ProspectMutations.clearConflict(`) is not a call on the model.
        let names = writers.union(relays).sorted().joined(separator: "|")
        let instanceCall = try! Regex(#"(?:^|[^A-Za-z0-9_])[a-z_][A-Za-z0-9_]*[?!]?\.(?:"# + names + #")\("#)
        var files: Set<String> = []
        for file in AppSourceWalk.appFiles() where file.name != model {
            if SourceGuardHelper.normalizedCode(file.text).contains(instanceCall) {
                files.insert((file.name as NSString).deletingPathExtension)
            }
        }
        return files
    }

    @Test func theCommentNamesExactlyTheFunctionsThatAssignTheFlag() throws {
        let doc = try #require(Self.documentation(), "no comment block found above `var conflictOpen`")
        let documented = try #require(Self.listed(after: "assigned only inside", in: doc),
                                      "the conflictOpen comment no longer carries its `assigned only inside` sentence")
        let found = Self.derivedWriters()
        #expect(!found.isEmpty, "found no assignment to conflictOpen at all, so this guard is reading the wrong tree")

        let outsideModel = found.filter { $0.file != Self.model }
        #expect(outsideModel.isEmpty, """
            conflictOpen is assigned outside \(Self.model): \(outsideModel.map { "\($0.file) in \($0.function)" }). \
            It is derived from conflictKey and conflictClearedKey and must have one definition; call one of \
            the model's writers instead.
            """)

        let derived = Set(found.map(\.function))
        #expect(documented == derived, """
            The comment above Prospect.conflictOpen lists its writers as \(documented.sorted()), but the code \
            assigns it inside \(derived.sorted()). Correct the `assigned only inside` sentence (#3968).
            """)
    }

    @Test func theCommentNamesEveryFileThatCallsAWriter() throws {
        let doc = try #require(Self.documentation(), "no comment block found above `var conflictOpen`")
        let documented = try #require(Self.listed(after: "callers outside the model are", in: doc),
                                      "the conflictOpen comment no longer carries its `callers outside the model are` sentence")
        let writers = Set(Self.derivedWriters().map(\.function))
        let derived = Self.derivedCallerFiles(writers: writers)
        #expect(!derived.isEmpty, "found no caller of a conflictOpen writer, so this guard is reading the wrong tree")
        #expect(documented == derived, """
            The comment above Prospect.conflictOpen lists the callers as \(documented.sorted()), but the code \
            calls a writer from \(derived.sorted()). Correct the `callers outside the model are` sentence (#3968).
            """)
    }
}
