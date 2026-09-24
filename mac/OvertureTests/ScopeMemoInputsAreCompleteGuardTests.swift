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

    /// Declarations whose memo keys through a named function rather than through `ScopeFingerprint`,
    /// with the test that asserts THAT key is complete. Written as the reason plus its evidence, never
    /// as a bare name: an exemption with nothing behind it is worse than no list (L233, L362).
    static let keyedElsewhere: [String: String] = [
        "QueueView.swift.makeRenderData":
            "keys through QueueModel.ProducerTables.key, which hashes the presenter and venue CONTENT "
            + "rather than identity because a name edited in place changes the answer; its completeness "
            + "is driven in all three directions by ProducerTablesReuseTests (#3742)",
    ]

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

    // WHAT THIS GUARD CANNOT SEE, stated because a green run here is not a statement that a key is
    // complete (L400).
    //
    // It asks whether a derivation's BODY MENTIONS a collection by name. A derivation that reaches one
    // through a computed property mentions the property, not the collection, and this rule is blind to
    // it. Measured 2026-09-24: `SourcesView.makeRenderData` builds `roomContext`, which builds `geo`,
    // which reads `excludedTownRows` and `allowedSeedTownRows`. Neither was in the key and this guard
    // was green. The key was fixed; the blind spot is not fixable by a text rule, because following it
    // means resolving a property chain.
    //
    // So: when keying a memo, trace every computed property the derivation touches BY HAND, and treat a
    // pass here as covering only what the body names directly.
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
                // #4112: the LAST colon before the `[`, not the first.
                //
                // The first colon is the type annotation's ONLY when no attribute on the line carries
                // one. `@Query(sort: \WatchedSource.orgName) private var sources: [WatchedSource]` has
                // one inside the attribute, so taking the first gave the name `@Query(sort`, which no
                // derivation body ever contains, and that collection was then skipped entirely. Measured
                // 2026-09-24: removing `key.add(sources)` from `SourcesView.makeRenderData` left this
                // guard GREEN, which is the whole class of defect it exists to catch, in the guard
                // itself (L400).
                //
                // Exactly one declaration in the app is affected today, and it is the one that exposed
                // it. That is the reason to fix the rule rather than the instance: the next `@Query`
                // written with a sort descriptor would have been invisible the same way, silently.
                let colons = trimmed.indices.filter { trimmed[$0] == ":" && $0 < open }
                guard let colon = colons.last else { continue }
                let head = String(trimmed[trimmed.startIndex..<colon])
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
                for (collection, element) in collections where declaration.body.contains(collection) {
                    // TWO ways a collection can be in the key, and both are real. `.add(name)` is the
                    // `ScopeFingerprint` builder, which hashes IDENTITY. The other is a named key
                    // function over a value DERIVED from the collection, which is what #3742's producer
                    // tables need: their key has to hash the presenter and venue CONTENT, because a
                    // presenter edited in place changes the answer and leaves every pointer where it
                    // was, and an identity hash cannot see that.
                    //
                    // So a declaration that passes a `fingerprint:` built by something other than
                    // `ScopeFingerprint` is accepted here, and its completeness is asserted by the tests
                    // named in `keyedElsewhere` instead. That is not a hole: those tests drive the
                    // invalidation in every direction, which is strictly more than this text rule can
                    // see. An entry with no such test would be an exemption with no reason behind it,
                    // which is worse than no list (L233).
                    let addsIt = declaration.body.contains(".add(\(collection))")
                    let derivesTheKey = Self.keyedElsewhere["\(file.name).\(name)"] != nil
                        && declaration.body.contains("fingerprint:")
                    if !addsIt && !derivesTheKey {
                        missing.append("\(file.name).\(name) reads \(collection): [\(element)] and never adds it to the key")
                    }
                }
            }
        }

        // Cannot pass vacuously. With no derivation running a memo this has measured nothing (L98).
        #expect(!derivations.isEmpty, """
            nothing under mac/Overture runs a derivation through ScopeMemo, so this guard checked \
            nothing at all
            """)
        // An exemption whose evidence has gone is an exemption with no reason behind it, so the named
        // test file has to still be there (L233).
        for (declaration, reason) in Self.keyedElsewhere {
            #expect(!SourceGuardHelper.source("OvertureTests/ProducerTablesReuseTests.swift").isEmpty,
                    Comment(rawValue: "\(declaration) is exempted because \(reason), and that test is "
                            + "gone, so the exemption now covers nothing"))
        }

        #expect(missing.isEmpty, Comment(rawValue: """
            \(missing.joined(separator: "; ")). A memo keyed on fewer inputs than its derivation reads \
            serves an answer that disagrees with the store the moment the missing one changes, and \
            nothing else here would report it (L40, #3879).
            """))
    }
}
