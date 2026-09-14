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


    // Does this line hand a store-wide collection to something as part of a CALL over it?
    //
    // An argument is `label: value`; the shape being refused is a value that CALLS something with a
    // store-wide collection in it. A bare `label: allProspects` is not this: passing the collection itself
    // costs nothing at the call site, and the subview is then where the cost is attributed.
    //
    // THREE WRONG VERSIONS, and each one is here because it refused correct code, which is the direction
    // that matters: a guard that goes red for the wrong reason teaches the next person to edit it until it
    // is quiet (L103). The first asked whether the value held a paren at all, and refused
    // `allItems: allItems) { ... startPrep(...) }`, where the paren belonged to a trailing closure. The
    // second asked whether a paren came BEFORE the collection, which reads the LINE'S LAYOUT rather than
    // the code: `ArchiveView(prospects: allProspects,` on its own line passed, and the identical
    // `.sheet(isPresented: $showPatterns) { OutcomePatternsView(prospects: allProspects) }` was refused
    // for having its opening paren on the same line (measured on #3871, which is the change that makes
    // handing rows to a sheet the RULE rather than the exception).
    //
    // What it asks now is the question the rule is actually about: is the collection the WHOLE value of
    // its own argument? `prospects: allProspects` is, whatever else is on the line. `corpus:
    // allProspects.filter { ... }` is not, and neither is `rows: expensive(allProspects)`.
    static func passesAWholeStoreCall(_ code: String, storeWide: [String]) -> Bool {
        for name in storeWide {
            var searchFrom = code.startIndex
            while let found = code.range(of: name, range: searchFrom..<code.endIndex) {
                searchFrom = found.upperBound
                // A longer identifier that merely CONTAINS the name is a different value.
                let beforeChar = found.lowerBound == code.startIndex
                    ? Character(" ") : code[code.index(before: found.lowerBound)]
                let endsTheLine = found.upperBound == code.endIndex
                let afterChar = endsTheLine ? Character(" ") : code[found.upperBound]
                if beforeChar.isLetter || beforeChar.isNumber || beforeChar == "_" { continue }
                if afterChar.isLetter || afterChar.isNumber || afterChar == "_" { continue }

                // It has to sit in an argument at all: something labelled, before it, on this line.
                let before = code[..<found.lowerBound]
                guard let colon = before.lastIndex(of: ":") else { continue }
                // Between the label's colon and the collection there may be nothing but space, or the
                // collection is part of a larger expression and this is the shape being refused.
                let between = before[before.index(after: colon)...]
                // The value ENDS there: the argument list continues, the call closes, or the line does.
                // A trailing space is deliberately NOT enough, or `foo: allProspects ?? []` would read as
                // a bare pass while the expression beside it is exactly what this refuses.
                let isTheWholeValue = between.allSatisfy(\.isWhitespace)
                    && (endsTheLine || afterChar == "," || afterChar == ")")
                if isTheWholeValue { continue }

                // The label has to look like an argument rather than a type annotation or a dictionary key.
                let labelStart = before[..<colon].lastIndex(where: { $0 == "(" || $0 == "," })
                    .map { before.index(after: $0) } ?? before.startIndex
                let label = before[labelStart..<colon].trimmingCharacters(in: .whitespaces)
                if label.hasPrefix("\"") || label.contains(" ") || label.isEmpty { continue }
                return true
            }
        }
        return false
    }


    // The predicate itself, against source this test writes. A guard's matcher is the half that can be
    // wrong in the silent direction, and this one has now been wrong in the LOUD direction twice, which
    // is what these preserve cases are for (L104).
    @Test("the matcher catches a call over the store in an argument")
    func catchesTheShapeItExistsFor() {
        let names = ["allProspects"]
        #expect(Self.passesAWholeStoreCall("QueueView(items: buildItems(allProspects))", storeWide: names))
        #expect(Self.passesAWholeStoreCall("Foo(rows: allProspects.filter { $0.isKept })", storeWide: names))
        #expect(Self.passesAWholeStoreCall("Foo(count: allProspects.count)", storeWide: names))
        #expect(Self.passesAWholeStoreCall("Foo(rows: allProspects ?? [])", storeWide: names))
    }

    @Test("the matcher permits handing the collection itself to a subview")
    func preservesWhatItMustNotRefuse() {
        let names = ["allProspects"]
        // The shape #3846 and #3871 make the rule: RootView holds the one query and hands the rows down.
        #expect(!Self.passesAWholeStoreCall("ArchiveView(prospects: allProspects,", storeWide: names))
        // The SAME code with the sheet modifier on the same line, which the previous rule refused purely
        // for its layout.
        #expect(!Self.passesAWholeStoreCall(
            ".sheet(isPresented: $showPatterns) { OutcomePatternsView(prospects: allProspects) }",
            storeWide: names))
        #expect(!Self.passesAWholeStoreCall("FollowUpsView(prospects: allProspects, onOpenInArchive: {", storeWide: names))
        // The trailing-closure case that the FIRST version of this guard refused.
        #expect(!Self.passesAWholeStoreCall("PrepSelectionSheet(prospects: toPrep, allItems: allItems) { keys in", storeWide: names))
        // A declaration, not an argument.
        #expect(!Self.passesAWholeStoreCall("let allProspects: [Prospect]", storeWide: names))
        // A longer identifier that merely contains the name.
        #expect(!Self.passesAWholeStoreCall("Foo(rows: allProspectsCached.count)", storeWide: ["allProspects"]))
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
            if Self.passesAWholeStoreCall(code, storeWide: storeWide) {
                offenders.append("  RootView.swift:\(line)  \(code.trimmingCharacters(in: .whitespaces))")
            }
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
