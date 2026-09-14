import Testing
import Foundation

// #3493: one evaluation of RootView's search scope walked the whole store twice.
//
// `nonDismissedProspects` is a COMPUTED property, so it is re-run by every reader and memoised between
// none of them, and a call site reads as a free field access with nothing at the point of use saying what
// it costs (L383). `searchableItems` read it directly and then read `reachedOutKeys`, which read it again.
// `routeDeepLink` had the same shape.
//
// The remedy is #3492's and #1774's: bind the walk once and hand it on. `reachedOutKeys` now TAKES the
// rows, so a caller cannot accidentally ask for a second walk by asking a second question.
//
// WHY A SOURCE GUARD RATHER THAN A BEHAVIOURAL ONE. Nothing about the ANSWER changed: both spellings
// return the same scope, so no test over the output can tell them apart, and a counter would have to
// reach inside a private computed property of a SwiftUI view that cannot be evaluated in a unit test at
// all. What is being protected is the SHAPE, so the shape is what is asserted (#1913's own reason for
// existing, one level down).
//
// The offender list is DERIVED: every declaration in the file is read and every one of them checked,
// rather than the two this issue happened to find (L96, L30). A third written next year is covered.
@Suite("RootView walks the store once per question (#3493)")
struct RootViewWalksTheStoreOnceTests {

    private var rootView: String { SourceGuardHelper.source("Overture/App/RootView.swift") }

    // The derivations that cost a walk of the whole store every time they are read. `allProspects` is
    // deliberately NOT here: it is the `@Query`'s own stored array, so reading it twice costs nothing.
    private static let wholeStoreDerivations = ["nonDismissedProspects", "allItems", "searchableItems"]

    // A declaration that legitimately reads one of those more than once, and WHY. The reason is a claim
    // about WHEN those reads happen, never a permission slip, and it is the shape of exemption this repo
    // already uses where a rule is right about the common case and wrong about a named one (L233, L324).
    //
    // There is exactly one, and this guard is what found it: writing the rule for the two sites #3493
    // names turned up a third the issue had already reasoned about correctly in its own text.
    struct Deferred: Equatable, Sendable {
        let declaration: String
        let derivation: String
        let why: String
    }

    static let deferred: [Deferred] = [
        Deferred(declaration: "withSheets", derivation: "allItems",
                 why: "Neither read is on the render path. One is `archiveItems: { allItems }`, an "
                    + "escaping closure Archive runs when it opens; the other is inside a `.sheet` "
                    + "content builder, evaluated on presentation. #3493's own text says so of the "
                    + "second: it is evaluated on presentation rather than per render, which is why "
                    + "that half is a duplicate-definition finding rather than a cost one."),
    ]

    // Every `var` and `func` declared at the type's own indentation, with its balanced-brace body.
    // Parsed rather than listed, so a declaration added later is judged without anybody adding it here.
    private func declarations(in source: String) -> [(name: String, body: String)] {
        var out: [(String, String)] = []
        for line in source.components(separatedBy: "\n") {
            guard line.hasPrefix("    "), !line.hasPrefix("     ") else { continue }
            guard line.hasSuffix("{") else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains("var ") || trimmed.contains("func ") else { continue }
            guard let body = SourceGuardHelper.propertyBody(line, in: source) else { continue }
            let keyword = trimmed.contains("func ") ? "func " : "var "
            guard let after = trimmed.range(of: keyword) else { continue }
            let name = trimmed[after.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            out.append((String(name), body))
        }
        return out
    }

    @Test("no declaration derives the whole store twice for one question")
    func noDeclarationWalksTheStoreTwice() {
        let source = rootView
        let declared = declarations(in: source)
        // A parser that stopped matching would report a clean file, which is the emptiest possible
        // failure reading as the cleanest possible pass (L98).
        #expect(declared.count > 30,
                "read only \(declared.count) declarations out of RootView, so this checked nothing")

        var offences: [String] = []
        for (name, body) in declared {
            // Its OWN definition mentions it once in the header, which `propertyBody` already excludes,
            // so a declaration's body naming itself is a recursive read and counts like any other.
            let code = SourceGuardHelper.normalizedCode(body)
            for derivation in Self.wholeStoreDerivations where name != derivation {
                let reads = code.components(separatedBy: derivation).count - 1
                guard reads > 1 else { continue }
                guard !Self.deferred.contains(where: { $0.declaration == name && $0.derivation == derivation })
                else { continue }
                offences.append("""
                    \(name) reads \(derivation) \(reads) times, so one evaluation of it walks the whole \
                    store \(reads) times over. Bind it to a local once and hand that on, the way \
                    searchableItems does, rather than asking a second question that asks the first one \
                    again (#3493, #3492, L383).
                    """)
            }
        }
        #expect(offences.isEmpty, "\(offences.joined(separator: "\n\n"))")

        // The other direction, so an exemption defending code that is gone does not sit here reading as a
        // considered decision the next person argues with rather than deletes (L346).
        for entry in Self.deferred {
            let body = declared.first(where: { $0.name == entry.declaration })?.body
            let reads = body.map { SourceGuardHelper.normalizedCode($0)
                .components(separatedBy: entry.derivation).count - 1 } ?? 0
            let stale = "\(entry.declaration) is exempted for reading \(entry.derivation) more than "
                + "once, and it reads it \(reads) times now. Delete the entry."
            #expect(reads > 1, "\(stale)")
        }
    }

    @Test("every exemption carries a reason")
    func everyExemptionCarriesAReason() {
        for entry in Self.deferred {
            #expect(entry.why.count > 60,
                    "\(entry.declaration) is exempted for \(entry.derivation) with no real reason written")
        }
    }

    // The second half of #3493, which is a duplicate DEFINITION rather than a duplicate walk: `allItems`
    // was declared once and then written out again inline at the Prep selection sheet. Two definitions of
    // one question can each be changed without the other (L263, L370).
    @Test("every prospect is mapped to a card in exactly one place")
    func oneDefinitionOfEveryShowAsACard() {
        let code = SourceGuardHelper.normalizedCode(rootView)
        let definitions = code.components(separatedBy: "allProspects.map(QueueItem.init)").count - 1
        #expect(definitions == 1,
                """
                RootView writes `allProspects.map(QueueItem.init)` \(definitions) times. One of them is \
                `allItems`; any other is a second definition of the same question, which can be changed \
                without the first (#3493).
                """)
    }

    // And that the shared one is still the one the sheet is handed, since the count above would also be
    // satisfied by deleting `allItems` and keeping the inline copy.
    @Test("the Prep selection sheet is handed the shared definition")
    func thePrepSheetTakesTheSharedDefinition() {
        #expect(SourceGuardHelper.containsCode("allItems: allItems)", in: rootView),
                "the Prep selection sheet no longer takes the shared allItems")
    }

    // #3493's own remedy, asserted so it cannot quietly become a computed property again, which is what
    // made the double walk invisible at the two call sites.
    @Test("the reached-out keys are asked OF a list rather than deriving their own")
    func reachedOutKeysTakesTheRows() {
        #expect(SourceGuardHelper.containsCode("private func reachedOutKeys(in rows: [Prospect]) -> Set<String>",
                                               in: rootView),
                "reachedOutKeys no longer takes the rows, so a caller cannot bind one walk for both")
    }
}
