import Testing
import Foundation

// #3647: a whole-store derivation must not sit in an ARGUMENT position on a render path.
//
// An argument evaluates at its CALL SITE, so a derivation written as an argument to a subview runs in the
// enclosing view's body, every time that body runs, while reading as though it belonged to the subview.
// `QueueView.swift:280` records the app falling into this once and `#1916` records it a level down, so this
// is the third time; the position is what hides it rather than anything about the call (L30).
//
// NEITHER INSTRUMENT CAN SEE IT. `QueueRenderPass.Corpus` counts sweeps over rows the pass was HANDED and
// this happens outside the pass; `WorkTally` counts `QueueItem` construction and this builds none. So the
// shape sits in the one position both are structurally blind to, which is why a guard is worth more here
// than the fix: the fix removes one instance and this refuses the next (L613).
//
// MEASURED FIRST, and the number is why this is a SHAPE guard rather than a cost one: the instance found in
// 2026-09 measured 1.9 ms per evaluation warm, not the dominant cost the issue was filed as. A guard that
// refused above a cost would have let this through.
@Suite("No whole-store walk in an argument position (#3647)")
struct NoWholeStoreWalkInAnArgumentTests {

    // The collections this guard follows, DERIVED from the source by the model they hold.
    //
    // TWO WRONG VERSIONS FIRST, and the data is what settled it. A hand-written list of three names I had
    // read off `RootView` exempts any collection added later from the check meant to catch it (L96). Deriving
    // from every `@Query` then over-matched: it flagged `GeoRefusals(userExcludedTowns: Set(excludedTownRows
    // .map(...)))`, which is a legitimate walk of a reference table.
    //
    // The distinction is SIZE, and size is a property of the data rather than of the syntax. Measured on the
    // live store 2026-09-11: Prospect 1,233 rows, WatchedSource 73, ExcludedTown 4, AllowedSeedTown 0. So the
    // subject is the `Prospect` table, which IS derivable: a `@Query` whose element type is `Prospect`, plus
    // the properties derived from one.
    //
    // The derived half reads DECLARATION LINES only, so a computed property that mentions `allProspects` on a
    // later line of its body is not picked up. `nonDismissedProspects` and `allItems` are both one-liners so
    // both are covered today, and this is stated rather than claimed away because an overstated account of a
    // guard's reach is worse than a narrow guard (L400).
    private static func storeWideNames(in code: String) -> [String] {
        let lines = SwiftSource.scannableLines(in: code, skipping: .all).map(\.code)

        func declaredName(_ line: String) -> String? {
            guard let varRange = line.range(of: "var "),
                  let colon = line.range(of: ":", range: varRange.upperBound..<line.endIndex) else { return nil }
            let name = line[varRange.upperBound..<colon.lowerBound].trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : name
        }

        var names: [String] = []
        for line in lines where line.contains("@Query") && line.contains("[Prospect]") {
            if let name = declaredName(line) { names.append(name) }
        }
        for line in lines where line.contains("private var ") && line.contains("{") {
            guard names.contains(where: { line.contains($0) }), let name = declaredName(line) else { continue }
            if !names.contains(name) { names.append(name) }
        }
        return names
    }

    @Test("no argument in RootView's body passes a call over the whole store")
    func rootViewPassesNoWholeStoreCall() throws {
        let source = try String(contentsOf: RepoRoot.mac
            .appendingPathComponent("Overture/App/RootView.swift"), encoding: .utf8)

        let storeWide = Self.storeWideNames(in: source)
        // The derivation has to find something, or this guard silently checks nothing at all: a run over an
        // empty name list would report no offenders and read exactly like a clean file (L98).
        #expect(storeWide.contains("allProspects"),
                Comment(rawValue: "the derivation found \(storeWide), which does not include the @Query this "
                + "guard exists to follow, so it is checking nothing"))

        var offenders: [String] = []
        for (line, code) in SwiftSource.scannableLines(in: source, skipping: .all) {
            // An argument is `label: value`; the shape being refused is a value that CALLS something with a
            // store-wide collection in it. A bare `label: allProspects` is not this: passing the collection
            // itself costs nothing at the call site, and the subview is then where the cost is attributed.
            guard let colon = code.firstIndex(of: ":") else { continue }
            let value = String(code[code.index(after: colon)...])
            // The collection must be INSIDE a call, which means an opening parenthesis BEFORE it. Written
            // first as "the value contains a paren and contains the collection", which refused
            // `allItems: allItems) { ... startPrep(...) }`: that passes the collection itself, which this
            // guard deliberately permits, and the paren belonged to a trailing closure further along the
            // line. An over-matching filter reads as working while refusing correct code, so it is tested
            // against what it must PRESERVE and not only against what it must catch (L104).
            guard let collection = storeWide.compactMap({ value.range(of: $0) }).min(by: {
                $0.lowerBound < $1.lowerBound
            }) else { continue }
            guard let paren = value.firstIndex(of: "("), paren < collection.lowerBound else { continue }
            // The label has to look like an argument rather than a type annotation or a dictionary key.
            let label = code[..<colon].trimmingCharacters(in: .whitespaces)
            guard !label.hasPrefix("\""), !label.contains(" ") else { continue }
            offenders.append("  RootView.swift:\(line)  \(code.trimmingCharacters(in: .whitespaces))")
        }

        let why = """
        A whole-store derivation is passed as an ARGUMENT, so it runs in RootView's body on every evaluation \
        rather than in the view it reads as belonging to, and neither cost instrument can see it (#3647):
        \(offenders.joined(separator: "\n"))
        Hold the value in @State and refresh it where `unreadableFiles` and `failingResponses` are refreshed.
        """
        #expect(offenders.isEmpty, Comment(rawValue: why))
    }
}
