import Testing
import Foundation

// #3829: a cost instrument that enumerates a view's change keys measures only the change keys, and a
// SwiftUI body evaluates every other modifier argument at the call site in exactly the same way.
//
// WHAT IT COST. `SourcesSheetCostTests` (#3656) measured "one body evaluation costs 8.98 ms" and its
// header reasoned from that figure that the Sources sheet's per-redraw derivation could not explain a
// 1.34 s freeze. That conclusion was repeated into #3645's body and stood for days. It was wrong because
// the instrument never timed `roomContext`, which is passed as an argument to a modifier and therefore
// evaluated on every pass just like the keys beside it. Measured 2026-09-12:
//
//   ClientWindow(sources:clients:) , never timed     69.01 ms
//   everything the instrument DID time               7.87 ms
//   the real per body evaluation cost               76.88 ms
//
// So the derivation could account for the freezes after all, and the instrument's own completeness is
// what hid it (L400, L107).
//
// WHY THIS IS A CLASS RATHER THAN ONE FIXED TEST. #3645 fixed the Sources sheet. The instrument SHAPE is
// the thing that generalises: any cost test built by listing the expressions its author remembered
// measures what they remembered. So the subjects are ENUMERATED FROM THE SOURCE, the way
// `EveryRenderPassIsCountedTests` already derives its own, and an expression added to the view next month
// is either timed or reported as untimed (L96, L98).
//
// WHAT THIS CAN AND CANNOT SEE, stated so nobody reads more into a pass than it carries. It enumerates
// the DOMAIN types named in the region a redraw evaluates, which is the body plus every private property
// and function the body reaches. It cannot see a cost inside one of those types, it cannot count HOW MANY
// body evaluations an interaction drives (that is the hosted target's question, #3645), and it does not
// know what anything COSTS. It answers one question: is every derivation this redraw runs named by the
// instrument that claims to price the redraw.
@Suite("A cost instrument enumerates its subjects from the source (#3829)")
struct ACostInstrumentEnumeratesItsSubjectsTests {

    // The instruments that claim to price one redraw of the Sources sheet. BOTH, because the subjects are
    // split between them since #3645 lifted the derivation into a pass, and an expression timed by either
    // is timed (L582).
    private static let sourcesInstruments = ["SourcesSheetCostTests.swift", "SourcesRenderPassCostTests.swift"]

    // Named as UNTIMED, with the reason, rather than left out. An exemption written as a reason keeps
    // covering the next thing that satisfies it; one written as a name stops at the case somebody
    // remembered (L362).
    private static let untimed: [String: String] = [
        // Values, not derivations: constructing one is a struct init over fields already in hand.
        "StageContext": "a struct init over values already derived, with no walk of its own",
        "SourcesRenderPass": "the pass itself, whose cost IS what the instruments measure",
        // TIMED TRANSITIVELY. Both are called per ROW from inside `SourcesRenderPass.make`, which
        // `SourcesRenderPassCostTests` times whole, and each is O(1) over that row's own fields with no
        // walk of the store. Naming them separately would be timing the same work twice under two names.
        "ClientTagCopy": "per row inside the pass, O(1) over that row's fields, timed by the pass",
        "SourceReadState": "per row inside the pass, two field reads, timed by the pass",
        // NOT ON THE REDRAW PATH AT ALL, and this entry is the honest cost of how the region is derived.
        // The walk follows every private declaration the body reaches, which includes the closures a
        // control hands to `Button`, and those run when Dan presses something rather than when the sheet
        // redraws. It cannot tell the two apart, so an action-only type reads as a redraw subject. Left
        // as an exemption with the reason rather than by narrowing the walk, because a walk that tried to
        // exclude closures would also exclude derivations that legitimately live in one (L362).
        "WatchlistEditing": "reached only from a control's action closure, never from a redraw",
    ]

    private static func code(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
            guard let range = line.range(of: "//") else { return line }
            return line[line.startIndex..<range.lowerBound]
        }.joined(separator: "\n")
    }

    // Every type the app declares under Domain, read off the declarations rather than from a list, so a
    // type added next month is enumerated by the same code that judges it.
    static func domainTypes() -> Set<String> {
        var names: Set<String> = []
        for url in AppSourceWalk.urls(under: RepoRoot.mac.appendingPathComponent("Overture/Domain")) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            // TOP LEVEL ONLY, judged by the line starting at column zero. A NESTED declaration is a
            // different thing: `Corpus`, `Inputs`, `Row`, `Section` and `State` are all nested types in
            // this app, and matching them against a view's source matches SwiftUI's own `Section(` and
            // `State(` instead. The first run of this guard reported nine such names out of nineteen,
            // which is the noise that makes a finding unreadable (L412).
            for line in code(text).components(separatedBy: "\n") {
                for keyword in ["struct ", "enum ", "final class ", "actor "] where line.hasPrefix(keyword) {
                    let rest = line.dropFirst(keyword.count)
                    let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                    if name.count > 2 { names.insert(String(name)) }
                }
            }
        }
        return names
    }

    // The region ONE REDRAW evaluates: the view's `body`, plus every private property and function the
    // body reaches, transitively. That transitive step is the whole point: `roomContext` is not named in
    // `body` at all, it is reached through `makeRenderData()`, which is exactly how it stayed invisible.
    static func redrawRegion(of view: String) -> String {
        let source = code(view)
        var region = SourceGuardHelper.propertyBody("var body: some View {", in: source) ?? ""
        guard !region.isEmpty else { return "" }

        // Declarations this file holds, by name, so a reference in the region can be followed.
        var declarations: [String: String] = [:]
        for line in source.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            for prefix in ["private var ", "private func ", "var ", "func "] where trimmed.hasPrefix(prefix) {
                let rest = trimmed.dropFirst(prefix.count)
                let name = String(rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
                guard !name.isEmpty, declarations[name] == nil else { continue }
                if trimmed.hasPrefix("private func ") || trimmed.hasPrefix("func ") {
                    declarations[name] = SourceGuardHelper.bodyOfFunction(named: name, in: source) ?? ""
                } else {
                    declarations[name] = SourceGuardHelper.propertyBody(trimmed + " {", in: source) ?? ""
                }
                break
            }
        }

        // Followed to a FIXED POINT rather than one level deep. One level would have found
        // `makeRenderData()` and stopped above `roomContext`, which is the defect this exists to catch.
        var seen: Set<String> = []
        var changed = true
        while changed {
            changed = false
            for (name, body) in declarations
            where !seen.contains(name) && !body.isEmpty && region.contains(name) {
                seen.insert(name)
                region += "\n" + body
                changed = true
            }
        }
        return region
    }

    @Test func thesourcesSheetInstrumentNamesEveryDerivationARedrawRuns() {
        let view = SourceGuardHelper.source("Overture/UI/SourcesView.swift")
        let region = Self.redrawRegion(of: view)
        // UNMEASURED is its own outcome. A region that came back empty, because the body's marker moved,
        // leaves nothing to enumerate and reads exactly like a view with no derivations in it (L98).
        #expect(!region.isEmpty,
                "SourcesView's redraw region could not be extracted, so nothing below was measured")

        let domain = Self.domainTypes()
        #expect(domain.count > 100,
                Comment(rawValue: "only \\(domain.count) Domain types were enumerated, so the walk did "
                        + "not read the app and nothing below was measured (L98)"))

        let used = domain.filter { region.contains("\($0)(") || region.contains("\($0).") }.sorted()
        #expect(!used.isEmpty, "no Domain type is named in the redraw region, which cannot be right")

        // Read INDIVIDUALLY and each checked, never joined and checked once. Two unreadable files joined
        // by a newline produce a non-empty string, so the obvious check passes over nothing at all, which
        // is the emptiest possible failure reading as the cleanest possible pass (L98). Seen: the first
        // run of this guard reported eleven missing subjects, three of which the instruments plainly name,
        // because the path was wrong and both files came back empty.
        let files = Self.sourcesInstruments.map { (name: $0, text: SourceGuardHelper.source("OvertureTests/\($0)")) }
        let unreadable = files.filter { $0.text.isEmpty }.map(\.name)
        #expect(unreadable.isEmpty,
                Comment(rawValue: "\(unreadable.joined(separator: ", ")) could not be read, so the "
                        + "finding below would be a list of everything rather than a measurement (L98)"))
        let instruments = files.map(\.text).joined(separator: "\n")

        let missing = used.filter { !instruments.contains($0) && Self.untimed[$0] == nil }
        #expect(missing.isEmpty, """
            \(missing.joined(separator: ", ")) is evaluated on every redraw of the Sources sheet and is \
            named by neither cost instrument nor by this suite's untimed list. An instrument built from \
            the expressions somebody remembered measures what they remembered, which is how a 69 ms call \
            read as 8.98 ms for days (#3829, #3645, L400).
            """)
    }
}
