import Testing
import Foundation
import SwiftData

// #1575: a standing guard that every surface answering "will the Queue show this lead" asks the one
// shared predicate, rather than deriving the judgment again with a filter of its own.
//
// #1567 is what this exists to prevent happening a fourth time. Two places answered one question and
// drifted: the stage lists went through StageNavigation, while the masthead total and the deep-link
// routing went through QueueModel.queueOrder and its own date window. Measured on the live store on
// 2026-07-26, they disagreed about 137 of 589 untriaged shows, and searching for a November show
// sitting in the Scout list opened ARCHIVE, which reads as "this show is gone" about a visible row.
// #792 and #861 each began the same way.
//
// QueueShowableIsOneFilterTests pins the two surfaces that drifted against each other. What nothing
// stopped was a THIRD surface (a new stage, a new panel, a new export) starting its own copy of the
// rule, because the defect is not in any one answer: it is in there being two. So this suite asserts
// the SHAPE rather than the values, in the spirit of StagePillCountMatchesNavigationTests, which does
// the same job for pill counts versus navigation targets.
//
// Two independent routes meet here, deliberately (L70). Which functions count as the shared predicate
// is PARSED from StageNavigation.swift; which surfaces answer the question is a written inventory of
// what the product does, read from the surface files themselves. A check whose two sides come from one
// lookup can only ever prove that lookup self-consistent, so renaming the predicate fails the guard
// instead of quietly redefining what it is asserting.
//
// Out of the guard's reach today, and named rather than left implied: UnplacedRooms.isWaiting in
// mac/Overture/Domain/VenuePlaceAnswer.swift decides whether a show is still ahead with a date
// comparison of its own, for the Sources sheet's room list. It is a genuine second answer, it is
// #2288, and it is not fixed here. The sweep below finds a surface by the question its NAME asks, and
// that one names a narrower question, so it does not trip it.

// The audit itself, as pure functions over source text handed IN, so its own failure paths can be
// exercised with fixtures instead of only ever being watched to pass over the real repo. A guard that
// finds nothing to inspect must fail rather than report a clean sweep (L1, L63): a renamed file, a
// moved declaration or a changed marker is exactly the moment this stops protecting anything, and it
// is invisible from a green run.
enum QueueShowableSurfaceAudit {

    // One surface: where it lives, the declaration that answers the question, what it answers in the
    // words a failure should use, and the shared entry points it must resolve through.
    struct Surface: Equatable, Sendable {
        let path: String        // relative to mac/
        let marker: String      // the declaration's header, ending in its opening brace
        let answers: String     // what this surface decides, for Dan
        let mustCall: [String]  // StageNavigation functions it has to go through
    }

    enum Finding: Equatable, CustomStringConvertible {
        case nothingToInspect(what: String)
        case fileUnreadable(path: String)
        case declarationMissing(path: String, marker: String)
        case declarationAmbiguous(path: String, marker: String, count: Int)
        case entryPointMissing(name: String)
        case doesNotAskTheSharedPredicate(answers: String, expected: String)
        case reDerivesTheRule(answers: String, tell: String)
        case unknownSurface(path: String, name: String)

        var description: String {
            switch self {
            case let .nothingToInspect(what):
                return "the guard found no \(what) at all, so it was protecting nothing (#1575)"
            case let .fileUnreadable(path):
                return "\(path) could not be read: a queue surface moved and this guard went blind"
            case let .declarationMissing(path, marker):
                return "\(path) no longer declares \(marker), so its surface is no longer being checked"
            case let .declarationAmbiguous(path, marker, count):
                return "\(path) matches \(marker) \(count) times, so the guard cannot say which body it read"
            case let .entryPointMissing(name):
                return "StageNavigation no longer declares \(name), which surfaces are required to call"
            case let .doesNotAskTheSharedPredicate(answers, expected):
                return "\(answers) no longer calls StageNavigation.\(expected), so it is answering on its own"
            case let .reDerivesTheRule(answers, tell):
                return "\(answers) derives the rule itself (it names \(tell)) instead of asking StageNavigation"
            case let .unknownSurface(path, name):
                return "\(path) declares \(name), which answers whether the Queue shows a lead, "
                     + "and is neither StageNavigation nor a surface this guard knows about"
            }
        }
    }

    // The tells of a surface deciding queue membership for itself. Each one is an ingredient of the
    // shared predicate, or a piece of the retired second filter #1567 removed, so naming any of them
    // inside a surface means the judgment is being made twice.
    static let reDerivationTells = [
        "isReachableForDeepLink",   // the #1567 filter, deleted from QueueView+Model
        "isReachableInQueue",       // its twin
        "queueOrder(",              // the 90-day window and the untouched-and-gone rule
        "toSendQueue(",             // that window, one call further out
        "leadTimeWindowDays",
        ".status == .",             // a status membership test written inline
        ".status != .",
        "hasOpened(",               // the #861 date rule
        "daysUntil("                // the ingredient of every window that has drifted so far
    ]

    // The source as a guard must read it: comments gone (a brace in prose must not decide where a body
    // ends, and QueueView+Model.swift NAMES isReachableForDeepLink in a comment saying it was removed),
    // string contents kept (a call is code either way).
    static func code(in source: String, skipping: SwiftSource.Skips = []) -> String {
        SwiftSource.scannableLines(in: source, skipping: skipping).map(\.code).joined(separator: "\n")
    }

    // Route one: what the shared predicate actually offers, read from its own declaration file rather
    // than from a list beside it.
    static func entryPoints(inStageNavigation source: String) -> [String] {
        var names: Set<String> = []
        for line in SwiftSource.scannableLines(in: source, skipping: []) {
            guard let range = line.code.range(of: "static func ") else { continue }
            let name = line.code[range.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            if !name.isEmpty { names.insert(String(name)) }
        }
        return names.sorted()
    }

    // Route two: every inventoried surface, checked against route one.
    static func audit(surfaces: [Surface], entryPoints: [String], tells: [String],
                      read: (String) -> String?) -> [Finding] {
        var findings: [Finding] = []
        if surfaces.isEmpty { findings.append(.nothingToInspect(what: "queue showable surfaces")) }
        if entryPoints.isEmpty { findings.append(.nothingToInspect(what: "StageNavigation entry points")) }
        if tells.isEmpty { findings.append(.nothingToInspect(what: "re-derivation tells")) }

        for surface in surfaces {
            for name in surface.mustCall where !entryPoints.contains(name) {
                findings.append(.entryPointMissing(name: name))
            }
            guard let source = read(surface.path), !source.isEmpty else {
                findings.append(.fileUnreadable(path: surface.path))
                continue
            }
            let text = code(in: source)
            let hits = text.components(separatedBy: surface.marker).count - 1
            if hits == 0 {
                findings.append(.declarationMissing(path: surface.path, marker: surface.marker))
                continue
            }
            if hits > 1 {
                findings.append(.declarationAmbiguous(path: surface.path, marker: surface.marker,
                                                      count: hits))
                continue
            }
            guard let body = SourceGuardHelper.propertyBody(surface.marker, in: text) else {
                findings.append(.declarationMissing(path: surface.path, marker: surface.marker))
                continue
            }
            for name in surface.mustCall where !body.contains("StageNavigation.\(name)(") {
                findings.append(.doesNotAskTheSharedPredicate(answers: surface.answers, expected: name))
            }
            for tell in tells where body.contains(tell) {
                findings.append(.reDerivesTheRule(answers: surface.answers, tell: tell))
            }
        }
        return findings
    }

    // Route three: the fourth surface nobody told the guard about. A declaration whose NAME asks
    // whether the Queue will show a lead has to be the shared predicate or an inventoried caller of it.
    static func answersQueueVisibility(_ name: String) -> Bool {
        let lowered = name.lowercased()
        if lowered.contains("showable") || lowered.contains("inqueue") { return true }
        guard lowered.contains("queue") || lowered.contains("stage") else { return false }
        return ["visible", "shown", "render", "opens", "reachab", "keys"].contains { lowered.contains($0) }
    }

    static func declarationNames(in source: String) -> [String] {
        var found: [String] = []
        // DEBUG-only declarations are skipped: DebugStaging builds a fixture named
        // stageReachabilityCompetition, which is a staging scenario for the #1585 reachability check
        // and never a queue surface, and it is compiled out of the app Dan runs.
        for line in SwiftSource.scannableLines(in: source, skipping: .debug) {
            var rest = Substring(line.code)
            while let range = rest.range(of: #"\b(func|var|let)\s+"#, options: .regularExpression) {
                let name = rest[range.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                if !name.isEmpty { found.append(String(name)) }
                rest = rest[range.upperBound...]
            }
        }
        return found
    }

    struct Sweep: Equatable {
        var unknown: [Finding] = []
        var insideThePredicate: [String] = []
        var filesScanned = 0
    }

    static func sweep(files: [(path: String, source: String)], predicatePath: String,
                      knownSurfacePaths: Set<String>) -> Sweep {
        var result = Sweep()
        result.filesScanned = files.count
        if files.isEmpty { result.unknown.append(.nothingToInspect(what: "app source files")) }
        for file in files {
            for name in declarationNames(in: file.source) where answersQueueVisibility(name) {
                if file.path == predicatePath {
                    result.insideThePredicate.append(name)
                } else if !knownSurfacePaths.contains(file.path) {
                    result.unknown.append(.unknownSurface(path: file.path, name: name))
                }
            }
        }
        return result
    }
}

@MainActor
@Suite("Every queue surface answers is-this-showable from the one shared predicate (#1575)")
struct QueueShowableSurfacesAreOnePredicateTests {

    private static let predicatePath = "Overture/Domain/StageNavigation.swift"

    // The inventory. Written from what the product does, surface by surface, not gathered by grepping
    // for the predicate: a list built from the calls it is meant to check would agree with itself by
    // construction and could never report a surface that stopped making them (L70).
    private static let surfaces: [QueueShowableSurfaceAudit.Surface] = [
        .init(path: "Overture/App/RootView.swift",
              marker: "private func routeDeepLink(toKey key: String) {",
              answers: "whether an OmniFocus tap or a search pick opens the Queue or Archive",
              mustCall: ["opensInQueue"]),
        .init(path: "Overture/App/RootView.swift",
              marker: "private var searchableItems: [QueueItem] {",
              answers: "which shows the global search bar is allowed to find",
              mustCall: ["stagedKeys"]),
        .init(path: "Overture/UI/QueueRenderPass.swift",
              marker: "static func make(_ i: Inputs) -> QueueView.RenderData {",
              answers: "the masthead's N in the queue, and the rows the focused stage renders",
              mustCall: ["queueKeys", "focusedKeys"]),
        .init(path: "Overture/UI/QueueView.swift",
              marker: "private func navigateToLead(_ key: String, proxy: ScrollViewProxy) {",
              answers: "which stage a deep-linked lead lands in",
              mustCall: ["stage"]),
        .init(path: "Overture/UI/QueueView.swift",
              marker: "private func scoutRows(_ data: RenderData) -> [QueueItem] {",
              answers: "the Scout rows a night-dismiss acts on",
              mustCall: ["focusedKeys"]),
        .init(path: "Overture/UI/QueueView.swift",
              marker: "private func focusOnStage(_ status: AgentStatus) {",
              answers: "the rows a stage pill's tap lands on",
              mustCall: ["naturalKeys"]),
        .init(path: "Overture/Domain/AgentRoster.swift",
              marker: "-> AgentInputs {",
              answers: "the number each stage pill states",
              mustCall: ["counts"])
    ]

    private static func read(_ relativeToMac: String) -> String? {
        try? String(contentsOf: RepoRoot.mac.appendingPathComponent(relativeToMac), encoding: .utf8)
    }

    private static func appSources() -> [(path: String, source: String)] {
        let root = RepoRoot.mac.appendingPathComponent("Overture")
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        else { return [] }
        var files: [(path: String, source: String)] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let relative = "Overture" + url.path.replacingOccurrences(of: root.path, with: "")
            files.append((path: relative, source: text))
        }
        return files
    }

    // MARK: - The predicate the surfaces are held to

    // Resolved by parsing StageNavigation.swift, and checked against the names written here, which come
    // from reading what each surface needs. Renaming a predicate function fails HERE, loudly, rather
    // than silently shrinking what the rest of this suite asserts.
    @Test func theSharedPredicateStillDeclaresTheEntryPointsTheSurfacesUse() throws {
        let source = try #require(Self.read(Self.predicatePath))
        let entryPoints = QueueShowableSurfaceAudit.entryPoints(inStageNavigation: source)

        #expect(!entryPoints.isEmpty, "StageNavigation.swift parsed to no entry points at all")
        for name in ["opensInQueue", "queueKeys", "stagedKeys", "stage", "focusedKeys",
                     "naturalKeys", "counts"] {
            #expect(entryPoints.contains(name), "StageNavigation no longer declares \(name)")
        }
    }

    // MARK: - The invariant itself

    @Test func everyQueueSurfaceResolvesThroughTheSharedPredicate() throws {
        let source = try #require(Self.read(Self.predicatePath))
        let findings = QueueShowableSurfaceAudit.audit(
            surfaces: Self.surfaces,
            entryPoints: QueueShowableSurfaceAudit.entryPoints(inStageNavigation: source),
            tells: QueueShowableSurfaceAudit.reDerivationTells,
            read: Self.read)

        #expect(findings.isEmpty, "\(findings.map(\.description).joined(separator: "\n"))")
    }

    // The fourth surface: a declaration anywhere in the app whose name asks whether the Queue will show
    // a lead, sitting outside StageNavigation and outside this inventory. That is #1567's opening move.
    @Test func noUnknownDeclarationAnswersWhetherTheQueueWillShowALead() throws {
        let files = Self.appSources()
        let sweep = QueueShowableSurfaceAudit.sweep(
            files: files, predicatePath: Self.predicatePath,
            knownSurfacePaths: Set(Self.surfaces.map(\.path)))

        #expect(sweep.filesScanned > 0, "the sweep walked no app source at all (#1575)")
        #expect(sweep.unknown.isEmpty, "\(sweep.unknown.map(\.description).joined(separator: "\n"))")
        // Non-vacuous: it must still be finding the predicate's own answers, or it has stopped
        // recognising the question and would wave a real second answer straight through (L63).
        for name in ["opensInQueue", "queueKeys", "stagedKeys"] {
            #expect(sweep.insideThePredicate.contains(name),
                    "the sweep no longer recognises StageNavigation.\(name) as answering the question")
        }
    }

    // MARK: - The guard's own failure paths, seen to fail

    @Test func anEmptyInventoryFailsInsteadOfReportingACleanSweep() {
        let findings = QueueShowableSurfaceAudit.audit(
            surfaces: [], entryPoints: ["opensInQueue"],
            tells: QueueShowableSurfaceAudit.reDerivationTells, read: { _ in "" })

        #expect(findings == [.nothingToInspect(what: "queue showable surfaces")])
    }

    @Test func anEmptyPredicateFailsInsteadOfExemptingEverySurface() {
        let findings = QueueShowableSurfaceAudit.audit(
            surfaces: [Self.surfaces[0]], entryPoints: [],
            tells: QueueShowableSurfaceAudit.reDerivationTells, read: Self.read)

        #expect(findings.contains(.nothingToInspect(what: "StageNavigation entry points")))
    }

    @Test func aSurfaceWhoseFileHasMovedFails() {
        let findings = QueueShowableSurfaceAudit.audit(
            surfaces: [Self.surfaces[0]], entryPoints: ["opensInQueue"],
            tells: QueueShowableSurfaceAudit.reDerivationTells, read: { _ in nil })

        #expect(findings == [.fileUnreadable(path: "Overture/App/RootView.swift")])
    }

    @Test func aSurfaceWhoseDeclarationHasBeenRenamedFails() {
        let findings = QueueShowableSurfaceAudit.audit(
            surfaces: [Self.surfaces[0]], entryPoints: ["opensInQueue"],
            tells: QueueShowableSurfaceAudit.reDerivationTells,
            read: { _ in "private func routeTheTap(toKey key: String) { }" })

        #expect(findings == [.declarationMissing(path: "Overture/App/RootView.swift",
                                                 marker: Self.surfaces[0].marker)])
    }

    @Test func aSurfaceThatStopsAskingTheSharedPredicateFails() {
        let findings = QueueShowableSurfaceAudit.audit(
            surfaces: [Self.surfaces[0]], entryPoints: ["opensInQueue"],
            tells: QueueShowableSurfaceAudit.reDerivationTells,
            read: { _ in """
                private func routeDeepLink(toKey key: String) {
                    deepLinkedKey = key
                }
                """ })

        #expect(findings == [.doesNotAskTheSharedPredicate(answers: Self.surfaces[0].answers,
                                                           expected: "opensInQueue")])
    }

    @Test func aSurfaceThatDerivesTheRuleItselfFails() {
        let findings = QueueShowableSurfaceAudit.audit(
            surfaces: [Self.surfaces[0]], entryPoints: ["opensInQueue"],
            tells: QueueShowableSurfaceAudit.reDerivationTells,
            read: { _ in """
                private func routeDeepLink(toKey key: String) {
                    let live = prospects.filter { $0.status == .new && !$0.hasOpened(today: today) }
                    if live.contains(where: { $0.naturalKey == key }),
                       StageNavigation.opensInQueue(key: key, in: live, reachedOutKeys: []) {
                        deepLinkedKey = key
                    }
                }
                """ })

        #expect(findings.contains(.reDerivesTheRule(answers: Self.surfaces[0].answers,
                                                    tell: ".status == .")))
        #expect(findings.contains(.reDerivesTheRule(answers: Self.surfaces[0].answers,
                                                    tell: "hasOpened(")))
    }

    // A rule named only in a comment is not a second answer. QueueView+Model.swift says in prose that
    // isReachableForDeepLink used to live there, and a guard that cannot tell prose from code would
    // report that sentence forever.
    @Test func aTellNamedOnlyInACommentIsNotAReDerivation() {
        let findings = QueueShowableSurfaceAudit.audit(
            surfaces: [Self.surfaces[0]], entryPoints: ["opensInQueue"],
            tells: QueueShowableSurfaceAudit.reDerivationTells,
            read: { _ in """
                private func routeDeepLink(toKey key: String) {
                    // #1567: isReachableForDeepLink used to decide this behind a date window of its own.
                    if StageNavigation.opensInQueue(key: key, in: prospects, reachedOutKeys: []) {
                        deepLinkedKey = key
                    }
                }
                """ })

        #expect(findings.isEmpty, "\(findings.map(\.description).joined(separator: "\n"))")
    }

    @Test func aRenamedPredicateFunctionFailsRatherThanSilentlyCheckingNothing() {
        let findings = QueueShowableSurfaceAudit.audit(
            surfaces: [Self.surfaces[0]], entryPoints: ["queueKeys"],
            tells: QueueShowableSurfaceAudit.reDerivationTells, read: Self.read)

        #expect(findings.contains(.entryPointMissing(name: "opensInQueue")))
    }

    @Test func theSweepFlagsANewSurfaceThatAnswersTheQuestionItself() {
        let sweep = QueueShowableSurfaceAudit.sweep(
            files: [(path: "Overture/UI/SourcesView.swift",
                     source: "static func isShowableInQueue(_ p: Prospect) -> Bool { true }")],
            predicatePath: Self.predicatePath, knownSurfacePaths: [])

        #expect(sweep.unknown == [.unknownSurface(path: "Overture/UI/SourcesView.swift",
                                                  name: "isShowableInQueue")])
    }

    @Test func theSweepFailsWhenItIsHandedNothingToWalk() {
        let sweep = QueueShowableSurfaceAudit.sweep(files: [], predicatePath: Self.predicatePath,
                                                    knownSurfacePaths: [])

        #expect(sweep.filesScanned == 0)
        #expect(sweep.unknown == [.nothingToInspect(what: "app source files")])
    }

    // A DEBUG-only fixture builder is not a queue surface: it is compiled out of the app Dan runs.
    @Test func theSweepIgnoresADebugOnlyDeclaration() {
        let sweep = QueueShowableSurfaceAudit.sweep(
            files: [(path: "Overture/Domain/DebugStaging.swift",
                     source: """
                        #if DEBUG
                        static func stageReachabilityCompetition() -> [Prospect] { [] }
                        #endif
                        """)],
            predicatePath: Self.predicatePath, knownSurfacePaths: [])

        #expect(sweep.unknown.isEmpty)
    }

    // MARK: - And the same answer at runtime

    private let today = ScoutTestClock.stageNavigationAnchor   // 2026-07-12
    private let now = Date(timeIntervalSince1970: 1_768_000_000)

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func show(_ ctx: ModelContext, _ key: String, status: ReviewStatus = .new,
                      date: String = "2026-08-19") -> Prospect {
        let p = Prospect(naturalKey: key, groupName: key, discipline: "music", venue: "Merkin Hall",
                         performanceDate: date, sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: status)
        ctx.insert(p)
        return p
    }

    // The structural half says the surfaces ASK the same predicate. This says what that buys, over a
    // store holding one show of every kind: a row any stage renders is a show the search bar can find
    // and a deep link opens in the Queue, and the masthead counts exactly those minus the pitched ones.
    @Test func everyRowAStageRendersIsShowableToEveryOtherSurface() throws {
        let ctx = try context()
        show(ctx, "to-triage")
        show(ctx, "far-future", date: "2027-03-01")
        show(ctx, "to-review", status: .drafted)
        show(ctx, "approved", status: .approved)
        show(ctx, "pitched", status: .contacted, date: "2020-01-01")
        show(ctx, "cut", status: .dismissed)

        let ps = try ctx.fetch(FetchDescriptor<Prospect>())
        let reachedOut: Set<String> = ["pitched"]
        let staged = StageNavigation.stagedKeys(in: ps, reachedOutKeys: reachedOut, today: today, now: now)
        let counted = StageNavigation.queueKeys(in: ps, reachedOutKeys: reachedOut, today: today, now: now)

        var rendered: Set<String> = []
        for focus in StageNavigation.countedFocuses {
            for key in StageNavigation.naturalKeys(for: focus, in: ps, today: today, now: now) {
                rendered.insert(key)
                #expect(StageNavigation.opensInQueue(key: key, in: ps, reachedOutKeys: reachedOut,
                                                     today: today, now: now),
                        "\(focus) renders \(key) but searching for it opens Archive")
                #expect(staged.contains(key), "\(focus) renders \(key) but the search bar cannot find it")
            }
        }

        #expect(!rendered.isEmpty, "no stage rendered anything, so this proved nothing")
        #expect(counted == rendered.subtracting(reachedOut))
        #expect(staged.contains("pitched"), "a pitched show is a stage of its own and stays reachable")
        #expect(!staged.contains("cut"), "a dismissed show is in no stage")
    }
}
