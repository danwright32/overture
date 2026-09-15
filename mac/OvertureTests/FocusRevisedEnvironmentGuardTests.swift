import Testing
import Foundation

// #3880: a view may not BOTH read an environment value the window system revises on focus AND reach a
// whole-store derivation from its body.
//
// WHAT IT COST. `ArchiveView` did exactly that: an `@Environment(\.dismiss)` read at view level, and
// `makeScope()` in its body. The window system revises `dismiss` on every key transition, so tabbing to
// another window and back paid TWO whole-store passes, measured at 385.3 ms each over 1,224 live rows
// (#3876, #3878).
//
// WHY A GUARD RATHER THAN THE SWEEP THAT FOUND IT. The sweep for #3878 is bounded and says so: it read
// the 17 views that name `@Environment(\.dismiss)` and matched three spellings of a derivation
// (`QueueModel.scope`, `makeScope()`, `filteredItems(`). A view deriving something expensive by a fourth
// name was never in scope, and a view added tomorrow is in nobody's scope. A hand sweep checks what
// somebody remembered (L96, L30). `becomingKeyCostsNoWholeStorePass` covers the behaviour and covers
// `ArchiveView` alone. The component and its guard ship together (L613); this is the guard half.
//
// HOW THE TWO HALVES ARE NAMED, which is the part worth reading before changing it.
//
// The ENVIRONMENT half is a constant, because it is short, closed, and every member is on it for the
// same stated reason: the window system writes it when focus moves. Written as that reason rather than
// as the one case the incident happened to be about (L362).
//
// The DERIVATION half is the part that would rot as a list, so it is not one. It is enumerated from the
// app's own declarations: every function under `mac/Overture` whose signature takes a `[Prospect]`, as
// `Type.function` pairs. A helper added next month is enumerated by the same code that judges it, and
// the QUALIFIED pair is what makes that usable at all: the bare function names are things like `build`,
// `count`, `from` and `due`, which match SwiftUI's own members everywhere and would bury a finding in
// noise (L412).
//
// WHICH OF THE TWO RULES THIS IS, because #3880 asks that question and #3879 answered it. The issue
// offered "do not read these at view level" or "do not derive the whole store in a body", and noted that
// the second becomes moot if #3879 removes the cost rather than the trigger. #3879 shipped, so the
// second rule as stated would now refuse a MEMOISED derivation, which is the remedy rather than the
// defect. The rule here is therefore the pair MINUS the remedy: a view may read one of these values, and
// it may derive the whole store, and it may not do both with nothing making the derivation conditional.
//
// A view that routes its derivation through `ScopeMemo` is exempt, and the exemption is not a list: it
// is the presence of the mechanism. Whether that memo's KEY is complete is a different question with its
// own guard, `ScopeMemoInputsAreCompleteGuardTests`, which enumerates the view's own model collections
// from the tree. Two guards, one each, rather than one guard asserting something it cannot see (L400).
//
// WHAT IT CANNOT SEE, stated so a pass is not read as more than it is. It is text over the redraw
// region, so it cannot tell a call inside an escaping closure (which runs when Dan presses something)
// from one in the body, it cannot see a derivation reached through a protocol or a stored closure, and
// it does not know what anything costs. It answers one question: does this view read a focus-revised
// environment value while its redraw can reach a declared whole-store derivation that nothing makes
// conditional.
@Suite("No view derives the whole store behind a focus-revised environment value (#3880)")
struct FocusRevisedEnvironmentGuardTests {

    // Written as the REASON, not as the case that bit: an environment value the window system revises
    // when focus moves. All four are documented as changing on activation, presentation or key state.
    static let focusRevised = ["dismiss", "controlActiveState", "isPresented", "scenePhase"]

    private static let appRoot = RepoRoot.mac.appendingPathComponent("Overture")
    // Low enough that an ordinary deletion cannot trip it, high enough that a wrong path does.
    private static let fileFloor = 100

    /// Every `Type.function` under the app whose signature takes a `[Prospect]`, read off the
    /// declarations rather than from a list.
    static func wholeStoreDerivations() -> Set<String> {
        var pairs: Set<String> = []
        for file in AppSourceWalk.files(underAll: [appRoot], floor: fileFloor) {
            let code = SwiftSource.scannableLines(in: file.text).map(\.code).joined(separator: "\n")
            var enclosing: String?
            var index = code.startIndex
            for line in code.components(separatedBy: "\n") {
                defer { index = code.index(index, offsetBy: line.count + 1, limitedBy: code.endIndex) ?? code.endIndex }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                for keyword in ["struct ", "enum ", "final class ", "class ", "actor ", "extension "]
                where line.hasPrefix(keyword) {
                    let name = line.dropFirst(keyword.count).prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                    if let first = name.first, first.isUppercase { enclosing = String(name) }
                }
                guard let type = enclosing, let range = trimmed.range(of: "func ") else { continue }
                let name = String(trimmed[range.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "_" })
                guard !name.isEmpty else { continue }
                // The signature can wrap over many lines, so it is read from the declaration to its
                // balanced closing paren rather than from this line alone. A one line read would miss
                // every helper whose parameters are listed one per line, which is most of them here.
                guard let open = code.range(of: "func \(name)(", range: index..<code.endIndex),
                      let signature = Self.balanced(in: code, from: open.upperBound) else { continue }
                if signature.contains("[Prospect]") { pairs.insert("\(type).\(name)") }
            }
        }
        return pairs
    }

    /// The text from `start` to the paren that closes the one just before it.
    private static func balanced(in text: String, from start: String.Index) -> String? {
        var depth = 1
        var i = start
        while i < text.endIndex {
            if text[i] == "(" { depth += 1 }
            if text[i] == ")" { depth -= 1; if depth == 0 { return String(text[start..<i]) } }
            i = text.index(after: i)
        }
        return nil
    }

    /// The rule itself, as a function of two texts, so it can be driven with source that is known to
    /// violate it. A guard whose predicate can only be exercised by the tree it judges cannot be shown
    /// to fire at all once that tree is clean (L98, L159).
    static func violates(view: String, derivations: Set<String>) -> (environment: String, derivation: String)? {
        let code = SwiftSource.scannableLines(in: view).map(\.code).joined(separator: "\n")
        // The remedy, not a list of names: a view whose derivation runs through a memo has made the pass
        // conditional, which is the thing the pair costs.
        guard !code.contains("ScopeMemo<") else { return nil }
        guard let environment = focusRevised.first(where: { code.contains("@Environment(\\.\($0))") })
        else { return nil }
        let region = RedrawRegion.of(view)
        guard let derivation = derivations.sorted().first(where: { region.contains("\($0)(") })
        else { return nil }
        return (environment, derivation)
    }

    @Test func thePredicateFiresOnTheShapeThisExistsToRefuse() {
        // The positive control, and it is asserted rather than assumed. Without it a clean tree and a
        // predicate that can never fire report identically, and the clean tree is what this guard will
        // see on every run after the day it ships (L159, L1).
        let offender = """
            struct SomeSheet: View {
                @Environment(\\.dismiss) private var dismiss
                var body: some View {
                    let rows = DueWork.counts(prospects: allProspects, now: Date())
                    Text("\\(rows)")
                }
            }
            """
        let found = Self.violates(view: offender, derivations: ["DueWork.counts"])
        #expect(found?.environment == "dismiss")
        #expect(found?.derivation == "DueWork.counts")

        // And it does NOT fire once the derivation is made conditional, which is the remedy #3879
        // shipped. Asserted, because an exemption nothing exercises is an exemption nobody can tell from
        // a rule that never fires (L159).
        let memoised = offender.replacingOccurrences(
            of: "var body: some View {",
            with: "@State private var memo = ScopeMemo<Int>()\n    var body: some View {")
        #expect(Self.violates(view: memoised, derivations: ["DueWork.counts"]) == nil)

        // And it does NOT fire on either half alone, which is what makes it a rule about the pair.
        let derivationOnly = offender.replacingOccurrences(of: "@Environment(\\.dismiss) private var dismiss",
                                                          with: "")
        #expect(Self.violates(view: derivationOnly, derivations: ["DueWork.counts"]) == nil)
        let environmentOnly = offender.replacingOccurrences(of: "DueWork.counts(prospects: allProspects, now: Date())",
                                                           with: "42")
        #expect(Self.violates(view: environmentOnly, derivations: ["DueWork.counts"]) == nil)
    }

    @Test func noViewReadsAFocusRevisedValueWhileDerivingTheWholeStore() {
        let derivations = Self.wholeStoreDerivations()
        #expect(derivations.count > 40, Comment(rawValue: """
            only \(derivations.count) whole-store derivations were enumerated from the app's own \
            declarations, so the walk did not read the app and nothing below was measured (L98)
            """))

        let files = AppSourceWalk.files(underAll: [Self.appRoot], floor: Self.fileFloor)
        var readers: [String] = []
        var offenders: [String] = []
        for file in files {
            let code = SwiftSource.scannableLines(in: file.text).map(\.code).joined(separator: "\n")
            guard Self.focusRevised.contains(where: { code.contains("@Environment(\\.\($0))") }) else { continue }
            readers.append(file.name)
            if let found = Self.violates(view: file.text, derivations: derivations) {
                offenders.append("\(file.name) reads \\.\(found.environment) and reaches \(found.derivation)")
            }
        }

        // Cannot pass vacuously. With no view reading one of these values this has measured nothing,
        // and nothing measured must not read as everything being fine (L98).
        #expect(!readers.isEmpty, """
            no view under mac/Overture reads a focus-revised environment value, so this guard checked \
            nothing at all
            """)
        #expect(offenders.isEmpty, Comment(rawValue: """
            \(offenders.joined(separator: "; ")). The window system revises these values when focus \
            moves, so every key transition evaluates that body and runs that derivation: measured at \
            385.3 ms a pass over 1,224 rows on ArchiveView, in both directions, which is what #3876 and \
            #3878 removed for one screen (L613, L96).
            """))
    }
}
