import Testing
import Foundation

// #3879: every model collection a memoised derivation READS is in the key it decides by.
//
// WHY THIS EXISTS AT ALL. `ScopeMemo` decides whether to rebuild from a fingerprint the CALLER computes,
// and a fingerprint that omits one of the view's inputs is a memo that serves a stale list when that
// input changes: rows on screen that disagree with the store, which is worse than a slow screen (L40).
// Handing the fingerprint in rather than computing it inside the memo is what makes that omission
// possible, and it is deliberate: the memo cannot know what a view's inputs are. So the omission is made
// VISIBLE here instead, by the same rule #3659's 9b states for the render pass's generation: the inputs
// are enumerated from the code, with a test that fails when one is added to the view and not to the key.
//
// DERIVED IN BOTH DIRECTIONS, so neither half is a list somebody maintains. The model types come from
// the `@Model` declarations in the app; the view's inputs come from its own property declarations. A
// seventh `@Query` added to `ArchiveView` next month is enumerated by this code on the run after it is
// written (L96, L41).
@Suite("A memoised derivation keys on every model collection it reads (#3879)")
struct ScopeMemoInputsAreCompleteGuardTests {

    private static let appRoot = RepoRoot.mac.appendingPathComponent("Overture")
    private static let fileFloor = 100

    /// Every `@Model` class the app declares, read off the declarations.
    static func modelTypes() -> Set<String> {
        var names: Set<String> = []
        for file in AppSourceWalk.files(underAll: [appRoot], floor: fileFloor) {
            let lines = SwiftSource.scannableLines(in: file.text).map(\.code)
            for (index, line) in lines.enumerated() where line.trimmingCharacters(in: .whitespaces) == "@Model" {
                guard index + 1 < lines.count else { continue }
                let next = lines[index + 1].trimmingCharacters(in: .whitespaces)
                for keyword in ["final class ", "class "] where next.hasPrefix(keyword) {
                    let name = next.dropFirst(keyword.count).prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                    if name.count > 2 { names.insert(String(name)) }
                    break
                }
            }
        }
        return names
    }

    @Test func everyModelCollectionADerivationReadsIsInTheKeyItsMemoDecidesBy() {
        let models = Self.modelTypes()
        #expect(models.count > 8, Comment(rawValue: """
            only \(models.count) @Model types were enumerated, so the walk did not read the app and \
            nothing below was measured (L98)
            """))

        let files = AppSourceWalk.files(underAll: [Self.appRoot], floor: Self.fileFloor)
        var derivations: [String] = []
        var missing: [String] = []
        for file in files {
            let code = RedrawRegion.code(file.text)
            guard code.contains("ScopeMemo<") else { continue }

            // The names this file declares as a collection of a model type: a `@Query`, or a handed-down
            // `let`. Collected from the whole file because a view's inputs are its properties, and
            // checked PER DERIVATION below, which is the part that matters.
            var collections: [String: String] = [:]
            for line in code.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard let open = trimmed.firstIndex(of: "["), let close = trimmed.firstIndex(of: "]"),
                      open < close else { continue }
                let element = String(trimmed[trimmed.index(after: open)..<close])
                guard models.contains(element) else { continue }
                guard let colon = trimmed.range(of: ":"), colon.lowerBound < open else { continue }
                let head = String(trimmed[trimmed.startIndex..<colon.lowerBound])
                guard let name = head.split(separator: " ").last.map(String.init), !name.isEmpty else { continue }
                collections[name] = element
            }

            // ONE DECLARATION AT A TIME, which is the whole correction. Asking whether every collection
            // in the FILE is in the key is the wrong question: a view may hold several memos over
            // different inputs, and `RootView` does. `followUpsDue` derives from the prospects and a
            // marker and from nothing else, so demanding it key on the watched sources would be
            // demanding a key that is wrong in the other direction (L40 cuts both ways: a key that
            // changes when the content does not is a memo that never hits).
            //
            // So the subject is the DERIVATION: for each declaration whose body runs a memo, every model
            // collection that body READS must be in the key that body builds.
            for (name, declaration) in RedrawRegion.declarations(in: code)
            where declaration.body.contains("Memo.value(") {
                derivations.append("\(file.name).\(name)")
                for (collection, element) in collections
                where declaration.body.contains(collection) && !declaration.body.contains(".add(\(collection))") {
                    missing.append("\(file.name).\(name) reads \(collection): [\(element)] and never adds it to the key")
                }
            }
        }

        // Cannot pass vacuously. With no derivation running a memo this has measured nothing (L98).
        #expect(!derivations.isEmpty, """
            nothing under mac/Overture runs a derivation through ScopeMemo, so this guard checked \
            nothing at all
            """)
        #expect(missing.isEmpty, Comment(rawValue: """
            \(missing.joined(separator: "; ")). A memo keyed on fewer inputs than its derivation reads \
            serves an answer that disagrees with the store the moment the missing one changes, and \
            nothing else here would report it (L40, #3879).
            """))
    }
}
