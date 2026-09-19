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
        // #3852: THE FIVE THIS GUARD COULD NOT SEE UNTIL THE WALK WAS FIXED.
        //
        // The walk appended " {" to a declaration line to build the marker for a property body, so a line
        // already ending in an open brace produced a marker ending "{ {" and matched nothing. Not one
        // `var` in this view ever resolved, which means this guard has been reading FUNCTIONS ONLY since
        // #3829 shipped, while its header claimed "every private property and function the body reaches"
        // (L400). These five became visible the moment that was fixed, and each is judged here rather
        // than left to make the list look clean.
        "SourceSearch": "its derivation half (isSearching, filter) runs inside the pass, timed by the pass; the rest is copy",
        "GeoRefusals": "a struct init over two small tables the view already holds, walking no prospect",
        "SourcesSheetClose": "a struct init over four booleans of this view's own editing state, plus copy",
        "CoverageCopy": "copy, not a derivation",
        "CoverageDismissEditing": "reached only from a control's action closure, never from a redraw",
        // #1424: the calendar clients box. Neither runs on a plain redraw: the body reads the CACHED
        // `calendarResult`, exactly as it reads `coverageResult`.
        "ShootHistory": "read once in the sheet's .task when it opens, a file read, never on a redraw",
        "CalendarClientCoverage": "recomputed only in the .task and on the ClientCoverage.signature change gate, the body reads its cached result; the row closures call setAsideKey, a string join",
    ]

    // WHY THE LIST STOPS AT TWO SURFACES, which is #3849's own fourth question. `RootView` and
    // `ArchiveView` both build `QueueItem`s and neither has a cost instrument of its own. This guard
    // checks a redraw's subjects AGAINST the instrument that claims to price that redraw, so pointing it
    // at a surface with no instrument names every Domain type in the region and every one of them lands
    // in an untimed list as a guess, which is worse than no list at all (L233). They join when they have
    // something to be checked against: `ArchiveView` gets one in #3879, which is measuring that surface's
    // pass; `RootView` needs one filed. Stated here rather than left unanswered, because an absent answer
    // and a considered no read identically.
    //
    // #3849: the second call site, and the whole reason #3829 exists. An instrument built from what
    // somebody remembered measures what they remembered, and the Sources sheet is the one that happened
    // to be looked at. The queue is the surface this milestone is actually about.
    //
    // THREE instruments, because the queue's subjects are split between them and a subject timed by any
    // of them is timed (L582). `QueueRenderPassCostTests` counts the whole-store sweeps a pass makes,
    // `QueueRenderPassLiveStoreCostTests` times the same pass against a clone of the real store, and
    // `QueueRebuildCostTests` prices the rebuild a mutation provokes.
    private static let queueInstruments = [
        "QueueRenderPassCostTests.swift",
        "QueueRenderPassLiveStoreCostTests.swift",
        "QueueRebuildCostTests.swift",
    ]

    // Every name the guard reported against `QueueView`, judged one at a time rather than listed. The
    // three it found that were REAL, `ContactRefusal`, `ProducerOverrides` and the tables behind them,
    // are not here: they were arguments the app built at the call site of every pass while this
    // instrument left them at their empty defaults, and #3849 wired them into
    // `QueueRenderPassLiveStoreCostTests` so they are measured rather than excused. That is the whole
    // point of enumerating from the source: an entry here asserting a cost is small is a judgement, and
    // a judgement that can be replaced by a measurement should be (L233, #3829).
    private static let queueUntimed: [String: String] = [
        // TIMED TRANSITIVELY by the pass, whose cost IS what the three instruments measure.
        "LiveRunHoldings": "a read of one cached Set (`current`), whose disk read happens at run start and run end, never in a body",
        // ON THE REDRAW PATH and O(1) or O(a small table beside the store). Each was read rather than
        // assumed: the function is named so the next reader can check the claim instead of trusting it.
        "AgentRoster": "statuses(_:) builds six chips from one AgentInputs value, walking nothing",
        "AppNotices": "servable(_:canFinishMissedShows:) maps the notice list, which is the handful on screen",
        "GeoRefusals": "a struct init capturing two town lists, walking no prospect",
        "ScoutStatus": "a struct init over one Date plus a summary string, per masthead",
        "SendDelightTiming": "plan(reduceMotion:) reads one flag and returns four durations",
        // THE IN-APP CARD CHECK's write side, reached from `body` through `recordCardCheck`. It is on the
        // redraw path and it is deliberately not part of the pass: the pass is a pure derivation and this
        // is the side effect on the app's own instrument. What it costs per redraw is one UserDefaults
        // read, which is served from memory, and the append happens only when the pass reports a real
        // divergence, which is the rare case rather than the redraw case.
        "CardDivergenceReport": "shouldStamp(last:now:) compares two dates, per redraw",
        "CardDivergenceLog": "one in-memory UserDefaults read per redraw; the file append needs a divergence",
        "CardDivergenceRecord": "constructed only when the pass reports a divergence, which is not the redraw case",
        // NOT ON THE REDRAW PATH AT ALL, and this is the same honest cost `WatchlistEditing` above
        // records: the walk follows every declaration the body reaches, which includes the closures a
        // control hands to a button, and those run when Dan presses something. It cannot tell the two
        // apart, so an action-only type reads as a redraw subject (L362).
        "DueBadge": "published from a .task keyed on the number, so it runs when that number changes",
        "FollowUp": "reached from performRowNudge, a control's action, never from a redraw",
        "ProbeSelection": "reached from finishShowsACheckMissed and the one-show recheck, both actions",
        "ProbeSelectionCopy": "the copy for those same two actions, never from a redraw",
    ]

    // #3852 lifted this and the walk below into `RedrawRegion`, so the two guards that ask questions of
    // a redraw's region share one implementation rather than each holding a copy that can learn a new
    // declaration shape without the other (L41, L370). Behaviour here is unchanged.
    private static func code(_ source: String) -> String { RedrawRegion.code(source) }

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
    static func redrawRegion(of view: String) -> String { RedrawRegion.of(view) }

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

    // #3849: the same question asked of the queue.
    @Test func thequeueInstrumentNamesEveryDerivationARedrawRuns() {
        let view = SourceGuardHelper.source("Overture/UI/QueueView.swift")
        let region = Self.redrawRegion(of: view)
        #expect(!region.isEmpty,
                "QueueView's redraw region could not be extracted, so nothing below was measured")

        let domain = Self.domainTypes()
        #expect(domain.count > 100,
                Comment(rawValue: "only \(domain.count) Domain types were enumerated, so the walk did "
                        + "not read the app and nothing below was measured (L98)"))

        let used = domain.filter { region.contains("\($0)(") || region.contains("\($0).") }.sorted()
        #expect(!used.isEmpty, "no Domain type is named in the queue's redraw region, which cannot be right")

        let files = Self.queueInstruments.map { (name: $0, text: SourceGuardHelper.source("OvertureTests/\($0)")) }
        let unreadable = files.filter { $0.text.isEmpty }.map(\.name)
        #expect(unreadable.isEmpty,
                Comment(rawValue: "\(unreadable.joined(separator: ", ")) could not be read, so the "
                        + "finding below would be a list of everything rather than a measurement (L98)"))
        let instruments = files.map(\.text).joined(separator: "\n")

        let missing = used.filter { !instruments.contains($0) && Self.queueUntimed[$0] == nil }
        #expect(missing.isEmpty, """
            \(missing.joined(separator: ", ")) is evaluated on every redraw of the queue and is named by \
            none of its three cost instruments, nor by this suite's untimed list for the queue (#3849).
            """)
    }
}
