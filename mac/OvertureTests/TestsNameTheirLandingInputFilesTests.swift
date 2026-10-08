import Testing
import Foundation
import SwiftData

// #4582: every test that reaches a landing names the Downbeat export and the imported booking history it reads.
//
// A landing reads two files besides the store: Downbeat's export (clients, bookings, blocked days) and the
// imported booking history. Each entry point takes both as parameters defaulted to the real files, so the app
// reads Dan's own, and a test that names neither reads whatever the default resolves to. Under test that is
// `StoreLocation.testRunHandoffDirectory`, one temporary folder every test process on the Mac shares, every
// worktree and concurrent run included (#2097 redirected it there, so a test never reaches Dan's real export;
// what it does reach is a folder anything else may have written into). A Downbeat export left there by any of
// them turns a show this test expects cold into a booked client, and the verdict depends on what ran before.
//
// So the rule is enforced from the code rather than remembered (L27): every app declaration whose own parameter
// list carries `exportURL:` defaulted to `DownbeatBridge.defaultURL` is an entry point, derived here rather than
// listed, and every call of one in the test sources names EVERY parameter it declares defaulted to a real
// handoff file, and never passes the default itself. A new entry point that takes the seam is covered the day it
// is written.
//
// What it cannot see, said rather than implied: a test that reaches a landing THROUGH something else (RootView's
// own scout, or a view that builds the lead sheet itself) names no entry point, so it is not judged; and an entry
// point taking the seam as an instance method cannot be addressed by its call text, so the derivation refuses it
// by name rather than leaving it unguarded.
@Suite("Every test that reaches a landing names the export and history it reads (#4582)")
struct TestsNameTheirLandingInputFilesTests {

    // The defaults that mean the real file, which under test is the shared folder.
    static let realFiles = ["DownbeatBridge.defaultURL", "LocalHistory.importedURL"]
    // The seam that makes a declaration an entry point.
    static let seam = "exportURL"

    struct EntryPoint: Hashable, CustomStringConvertible {
        // How it is called in source: `Type.name(` for a static function, `Type(` for an initialiser.
        let call: String
        // Every parameter it declares defaulted to a real handoff file, in declaration order.
        let labels: [String]
        var description: String { call }
    }

    struct Derivation {
        var entryPoints: [EntryPoint] = []
        // A declaration carrying the seam that a call cannot be matched to by its text, by "file:line name".
        var unaddressable: [String] = []
    }

    // MARK: - reading Swift

    // A file's code with comments and string contents removed, its lines where they were.
    static func code(_ text: String) -> String {
        let scan = SwiftSource.tokenize(text)
        let last = scan.codeLines.keys.max() ?? 0
        guard last > 0 else { return "" }
        return (1...last).map { scan.codeLines[$0] ?? "" }.joined(separator: "\n")
    }

    // The text directly inside the parentheses opening at `open`: not inside a nested call, closure or literal,
    // so a label belonging to a nested call never answers for the outer one. Commas at that level split it.
    static func ownArguments(_ code: String, openingAt open: String.Index) -> (parts: [String], end: String.Index) {
        // `end` is just past the closing parenthesis.
        var parens = 1, braces = 0, brackets = 0
        var parts: [String] = [], current = ""
        var i = code.index(after: open)
        while i < code.endIndex {
            let ch = code[i]
            let ownBefore = parens == 1 && braces == 0 && brackets == 0
            switch ch {
            case "(": parens += 1
            case ")": parens -= 1
            case "{": braces += 1
            case "}": braces -= 1
            case "[": brackets += 1
            case "]": brackets -= 1
            default: break
            }
            i = code.index(after: i)
            if parens == 0 { break }   // the call's own closing parenthesis
            // A nested call, closure or literal stands as blanks, so its labels and commas are never the call's.
            if ownBefore && parens == 1 && braces == 0 && brackets == 0 {
                if ch == "," { parts.append(current); current = "" } else { current.append(ch) }
            } else {
                current.append(" ")
            }
        }
        parts.append(current)
        return (parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }, i)
    }

    static func lineNumber(of index: String.Index, in code: String) -> Int {
        code[code.startIndex..<index].filter { $0 == "\n" }.count + 1
    }

    // The type each column-zero declaration opens, by the line it starts on, so a declaration's owner is the
    // last one above it. Nested types are indented and so never mistaken for the owner.
    static let typeLine = try! NSRegularExpression(
        pattern: #"^(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|internal|final|private|fileprivate|nonisolated)\s+)*(?:enum|struct|class|actor|extension)\s+([A-Za-z_]\w*)"#,
        options: [.anchorsMatchLines])
    static let declaration = try! NSRegularExpression(pattern: #"\b(?:func\s+([A-Za-z_]\w*)\s*(?:<[^>]*>)?|init)\s*\("#)

    // MARK: - the derivation

    static func derive(_ files: [(name: String, text: String)]) -> Derivation {
        var out = Derivation()
        for file in files {
            let code = Self.code(file.text)
            let ns = code as NSString
            let types = typeLine.matches(in: code, range: NSRange(location: 0, length: ns.length))
                .map { (at: $0.range.location, name: ns.substring(with: $0.range(at: 1))) }
            for match in declaration.matches(in: code, range: NSRange(location: 0, length: ns.length)) {
                guard let range = Range(match.range, in: code) else { continue }
                let open = code.index(before: range.upperBound)
                let parameters = ownArguments(code, openingAt: open).parts
                var labels: [String] = []
                var carriesSeam = false
                for parameter in parameters {
                    guard let colon = parameter.firstIndex(of: ":"), let equals = parameter.firstIndex(of: "=")
                    else { continue }
                    let names = parameter[parameter.startIndex..<colon].split(separator: " ")
                        .filter { !$0.hasPrefix("@") }
                    guard let label = names.first.map(String.init) else { continue }
                    let fallback = parameter[parameter.index(after: equals)...]
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard realFiles.contains(fallback) else { continue }
                    labels.append(label)
                    if label == seam && fallback == "DownbeatBridge.defaultURL" { carriesSeam = true }
                }
                guard carriesSeam else { continue }
                let owner = types.last { $0.at < match.range.location }?.name ?? "?"
                let line = lineNumber(of: range.lowerBound, in: code)
                let lineStart = code[..<range.lowerBound].lastIndex(of: "\n").map { code.index(after: $0) }
                    ?? code.startIndex
                let head = String(code[lineStart..<range.lowerBound])
                if match.range(at: 1).location == NSNotFound {
                    out.entryPoints.append(EntryPoint(call: owner + "(", labels: labels))
                } else if head.contains("static ") {
                    out.entryPoints.append(EntryPoint(call: owner + "." + ns.substring(with: match.range(at: 1)) + "(",
                                                      labels: labels))
                } else {
                    out.unaddressable.append("\(file.name):\(line) \(ns.substring(with: match.range(at: 1)))")
                }
            }
        }
        return out
    }

    // MARK: - the scan

    // Each call of an entry point that names one of its handoff files nowhere in its own arguments, or names the
    // real file itself, as "file:line call what".
    static func findings(in text: String, file: String, entryPoints: [EntryPoint]) -> [String] {
        findings(inCode: Self.code(text), file: file, entryPoints: entryPoints)
    }

    static func findings(inCode code: String, file: String, entryPoints: [EntryPoint]) -> [String] {
        var out: [String] = []
        for entry in entryPoints {
            var from = code.startIndex
            while let found = code.range(of: entry.call, range: from..<code.endIndex) {
                from = found.upperBound
                if found.lowerBound > code.startIndex {
                    let before = code[code.index(before: found.lowerBound)]
                    if before.isLetter || before.isNumber || before == "_" || before == "." { continue }
                }
                let arguments = ownArguments(code, openingAt: code.index(before: found.upperBound)).parts
                let named = Dictionary(arguments.compactMap { argument -> (String, String)? in
                    guard let colon = argument.firstIndex(of: ":") else { return nil }
                    let label = argument[..<colon].trimmingCharacters(in: .whitespaces)
                    guard !label.isEmpty, label.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
                        return nil
                    }
                    return (label, argument[argument.index(after: colon)...].trimmingCharacters(in: .whitespaces))
                }, uniquingKeysWith: { first, _ in first })
                let missing = entry.labels.filter { named[$0] == nil }
                let real = entry.labels.filter { named[$0].map(realFiles.contains) ?? false }
                guard !missing.isEmpty || !real.isEmpty else { continue }
                let line = lineNumber(of: found.lowerBound, in: code)
                var said: [String] = []
                if !missing.isEmpty { said.append("names no " + missing.map { $0 + ":" }.joined(separator: ", ")) }
                if !real.isEmpty { said.append("passes the real file for " + real.joined(separator: ", ")) }
                out.append("\(file):\(line) \(entry.call) " + said.joined(separator: "; "))
            }
        }
        return out
    }

    // The files `scripts/landing-oracle.sh` overlays onto a worktree of 6d3453d8, read from the script itself.
    // They are compiled against that commit's app, where no entry point has the seam, so they cannot name one;
    // each refuses to land instead when either file is present in the shared folder (`handoffInputsRefusal`).
    static func oracleOverlay(script: String) -> [String] {
        guard let start = script.range(of: "ORACLE_OVERLAY=(") else { return [] }
        guard let end = script.range(of: ")", range: start.upperBound..<script.endIndex) else { return [] }
        return script[start.upperBound..<end.lowerBound].split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("mac/OvertureTests/") }
            .map { ($0 as NSString).lastPathComponent }
    }

    static var testRoots: [URL] {
        ["OvertureTests", "OvertureHostedTests", "TestSupport"].map { RepoRoot.mac.appendingPathComponent($0) }
    }

    // MARK: - the rule, over the real sources

    @Test func everyTestThatReachesALandingNamesTheExportAndHistoryItReads() throws {
        let app = AppSourceWalk.appFiles().map { (name: $0.name, text: $0.text) }
        let derived = Self.derive(app)
        #expect(derived.unaddressable.isEmpty, Comment(rawValue: """
            these declarations take Downbeat's export as an instance method, which this guard cannot match a call \
            to by its text, so no test calling them is judged: \(derived.unaddressable)
            """))
        // The derivation found the entry points it exists for, or it is passing over nothing (L98).
        let calls = Set(derived.entryPoints.map(\.call))
        #expect(calls.isSuperset(of: ["ScoutService.runScout(", "LeadPasteLanding.landPastedLead(", "LeadIntakeModel("]),
                Comment(rawValue: "the entry points derived from the app were \(calls.sorted())"))

        let script = try String(contentsOf: RepoRoot.url.appendingPathComponent("scripts/landing-oracle.sh"),
                                encoding: .utf8)
        let overlay = Set(Self.oracleOverlay(script: script))
        let tests = AppSourceWalk.files(underAll: Self.testRoots, floor: AppSourceWalk.appFloor)
        var found: [String] = []
        var reaching: [String: Int] = [:]
        for file in tests where !overlay.contains(file.name) {
            let code = Self.code(file.text)
            found += Self.findings(inCode: code, file: file.name, entryPoints: derived.entryPoints)
            for entry in derived.entryPoints where code.contains(entry.call) {
                reaching[entry.call, default: 0] += 1
            }
        }
        #expect(found.isEmpty, Comment(rawValue: """
            \(found.count) calls reach a landing without naming the files it reads, so they read the folder every \
            test shares. Pass AbsentHandoff.export and AbsentHandoff.history, or a file of the test's own:
            \(found.joined(separator: "\n"))
            """))
        // And the scan met the calls it exists to judge in the test sources.
        for call in ["ScoutService.runScout(", "LeadPasteLanding.landPastedLead(", "LeadIntakeModel("] {
            #expect((reaching[call] ?? 0) > 0, Comment(rawValue: "no test file was found calling \(call)"))
        }
    }

    // The exemption, held to its reason: the overlay was read from the script, it names the corpus that lands
    // through runScout and the lead sheet, and every overlaid file that reaches a landing refuses on a file present.
    @Test func theOracleOverlayIsExemptOnlyWhileItRefusesAPresentFile() throws {
        let script = try String(contentsOf: RepoRoot.url.appendingPathComponent("scripts/landing-oracle.sh"),
                                encoding: .utf8)
        let overlay = Self.oracleOverlay(script: script)
        #expect(overlay.contains("LandingOracleCorpus.swift"), Comment(rawValue: "the overlay read was \(overlay)"))
        let derived = Self.derive(AppSourceWalk.appFiles().map { (name: $0.name, text: $0.text) })
        let tests = AppSourceWalk.files(underAll: Self.testRoots, floor: AppSourceWalk.appFloor)
        var judged = 0
        for file in tests where overlay.contains(file.name) {
            let unrefused = Self.functionsReachingALandingUnrefused(Self.code(file.text), entryPoints: derived.entryPoints)
            judged += unrefused.reaching
            #expect(unrefused.names.isEmpty, Comment(rawValue: """
                \(file.name) is overlaid onto 6d3453d8, where no landing takes its files, and these functions reach \
                one without calling handoffInputsRefusal() first, so they land whatever the shared folder holds: \
                \(unrefused.names)
                """))
        }
        #expect(judged > 0, "no overlaid function reaching a landing was found, so the exemption was judged on nothing")
    }

    // Each function in `code` that calls an entry point, and those of them that do not also CALL
    // `handoffInputsRefusal()` (a call with the default inputs, the shared folder's two files; the declaration
    // alone refuses nothing). Judged per function, not per file, so one refusing function never answers for
    // another that lands without refusing (L135).
    static func functionsReachingALandingUnrefused(_ code: String, entryPoints: [EntryPoint])
        -> (reaching: Int, names: [String]) {
        let ns = code as NSString
        // Functions only: an `init(` here is as likely a call (`.init(`) as a declaration.
        let starts = declaration.matches(in: code, range: NSRange(location: 0, length: ns.length))
            .filter { $0.range(at: 1).location != NSNotFound }.map(\.range)
        var reaching = 0
        var names: [String] = []
        for (i, start) in starts.enumerated() {
            let end = i + 1 < starts.count ? starts[i + 1].location : ns.length
            let body = ns.substring(with: NSRange(location: start.location, length: end - start.location))
            guard entryPoints.contains(where: { body.contains($0.call) }) else { continue }
            reaching += 1
            if !body.contains("handoffInputsRefusal()") {
                names.append(String(ns.substring(with: start).dropLast()).trimmingCharacters(in: .whitespaces))
            }
        }
        return (reaching, names)
    }

    // MARK: - the rule, on sources written here

    static let fixtureApp = """
        @MainActor
        enum Landing {
            enum Nested { case a }
            static func land(_ x: Int, exportURL: URL = DownbeatBridge.defaultURL,
                             history: URL = LocalHistory.importedURL,
                             done: (Int, Int) -> Void = { _, _ in }, into c: Int) {}
            static func other(url: URL = DownbeatBridge.defaultURL) {}
        }
        final class Sheet {
            init(a: Int = 0, exportURL: URL = DownbeatBridge.defaultURL) {}
        }
        final class Ticker {
            func tick(exportURL: URL = DownbeatBridge.defaultURL) {}
        }
        // static func commented(exportURL: URL = DownbeatBridge.defaultURL)
        """

    @Test func theDerivationFindsEveryDeclarationCarryingTheSeamAndRefusesOneItCannotAddress() {
        let derived = Self.derive([(name: "Fixture.swift", text: Self.fixtureApp)])
        #expect(derived.entryPoints == [EntryPoint(call: "Landing.land(", labels: ["exportURL", "history"]),
                                        EntryPoint(call: "Sheet(", labels: ["exportURL"])],
                Comment(rawValue: "\(derived.entryPoints.map { "\($0.call) \($0.labels)" })"))
        #expect(derived.unaddressable == ["Fixture.swift:13 tick"], Comment(rawValue: "\(derived.unaddressable)"))
    }

    @Test func theScanFindsACallMissingAFileAndIgnoresCommentsStringsAndNestedLabels() {
        let entries = Self.derive([(name: "Fixture.swift", text: Self.fixtureApp)]).entryPoints
        let tests = """
            Landing.land(1, into: 2)
            Landing.land(1, exportURL: e, history: h, into: 2)
            Landing.land(1, done: { _, _ in f(exportURL: e, history: h) }, into: 2)
            Landing.land(1, exportURL: DownbeatBridge.defaultURL, history: h, into: 2)
            // Landing.land(1)
            let s = "Landing.land(1)"
            let m = Sheet(a: 1)
            let n = Sheet(exportURL: e)
            let o = MySheet(a: 1)
            """
        #expect(Self.findings(in: tests, file: "T.swift", entryPoints: entries) == [
            "T.swift:1 Landing.land( names no exportURL:, history:",
            "T.swift:3 Landing.land( names no exportURL:, history:",
            "T.swift:4 Landing.land( passes the real file for exportURL",
            "T.swift:7 Sheet( names no exportURL:",
        ])
    }

    @Test func anOverlaidFunctionIsJudgedOnItsOwnRefusalNotTheFiles() {
        let entries = Self.derive([(name: "Fixture.swift", text: Self.fixtureApp)]).entryPoints
        let corpus = """
            enum Corpus {
                static func handoffInputsRefusal(_ inputs: [URL] = []) -> String? { nil }
                static func refusing() { if handoffInputsRefusal() != nil { return }; Landing.land(1, into: 2) }
                static func landing() { Landing.land(1, into: 2) }
                // static func commented() { handoffInputsRefusal() }
            }
            """
        let judged = Self.functionsReachingALandingUnrefused(Self.code(corpus), entryPoints: entries)
        #expect(judged.reaching == 2)
        #expect(judged.names == ["func landing"], Comment(rawValue: "\(judged.names)"))
    }

    @Test func theOverlayIsReadFromTheScriptsOwnList() {
        let script = """
            ORACLE_OVERLAY=(
              mac/OvertureTests/LandingOracle.swift
              mac/OvertureTests/LandingOracleCorpus.swift
            )
            OTHER=(
              mac/OvertureTests/NotOverlaid.swift
            )
            """
        #expect(Self.oracleOverlay(script: script) == ["LandingOracle.swift", "LandingOracleCorpus.swift"])
        #expect(Self.oracleOverlay(script: "nothing here").isEmpty)
    }
}

// #4582: the two entry points read the export they are HANDED, so a test's own file decides what a landing sees,
// and a Mac with no export lands every show cold and says the client list is missing rather than failing.
@MainActor
@Suite("runScout and the lead paste read the Downbeat export they are handed (#4582)")
final class LandingsReadTheExportTheyAreHandedTests {
    private let sandboxes = TemporarySandboxes()

    private static let client = "Pier Nine Players"
    private static let today = "2026-10-05"
    private static let now = ISO8601DateFormatter().date(from: "2026-10-05T16:00:00Z")!

    // A Downbeat export of the test's own holding one client, the presenter of the show each test lands.
    private func exportNamingTheClient() throws -> URL {
        let url = try sandboxes.make(named: "landing-export-4582").appendingPathComponent("downbeat-export.json")
        try Data("""
            {"version":2,"clients":[{"id":"C1","displayName":"\(Self.client)","email":"a@piernine.example",
            "contractEmail":"a@piernine.example","hasLeftReview":false,"specialBehaviors":[],"hostingSite":"pixieset"}],
            "venues":[],"bookings":[],"blockedDates":[]}
            """.utf8).write(to: url)
        return url
    }

    private static let event = ExtractedEvent(title: "Harbor Lights", presenter: client, venue: "Pier Nine Room",
                                              performanceDate: "2026-11-21",
                                              sourceUrl: "https://piernine.example/harbor-lights",
                                              location: "New York, NY")

    private func container() throws -> ModelContainer {
        try TestModelContainer.inMemory(AppSchema.models)
    }

    private func runScout(_ ctx: ModelContext, export: URL) async throws -> ScoutService.Outcome {
        ctx.insert(WatchedSource(sourceId: WatchedSource.carnegieId, orgName: "Carnegie Hall", kind: .algolia))
        return try await ScoutService.runScout(
            into: ctx, extractor: StubSourceExtractor(listing: ExtractedListing(events: [Self.event],
                                                                                verdict: .upcomingListings)),
            launch: { _ in }, now: Self.now, defaults: ScratchDefaults.make("LandingsReadTheExportTheyAreHanded"),
            landings: LandingSingleFlight(),
            exportURL: export, importedHistory: AbsentHandoff.history)
    }

    private func landed(_ container: ModelContainer) throws -> Prospect {
        let shows = try ModelContext(container).fetch(FetchDescriptor<Prospect>())
        return try #require(shows.first { $0.groupName == "Harbor Lights" }, "the show did not land: \(shows.map(\.groupName))")
    }

    @Test func runScoutRecognisesAClientFromTheExportItIsHanded() async throws {
        let container = try container()
        let outcome = try await runScout(container.mainContext, export: try exportNamingTheClient())
        #expect(outcome.inserted == 1, "inserted \(outcome.inserted)")
        #expect(outcome.clientListWarning == nil, Comment(rawValue: outcome.clientListWarning ?? ""))
        #expect(try landed(container).matchedClientName == Self.client)
    }

    // The failure path: no export at all. The run still lands its show, cold, and says why.
    @Test func runScoutWithNoExportLandsTheShowColdAndSaysTheClientListIsMissing() async throws {
        let container = try container()
        let outcome = try await runScout(container.mainContext, export: AbsentHandoff.export)
        #expect(outcome.inserted == 1, "inserted \(outcome.inserted)")
        #expect(outcome.clientListWarning == DownbeatBridge.warningText(for: .missing),
                Comment(rawValue: outcome.clientListWarning ?? "no warning"))
        #expect(try landed(container).matchedClientName == nil)
    }

    private func paste(_ context: ModelContext, export: URL) async -> LeadPasteLanding.Result {
        await LeadPasteLanding.landPastedLead(
            [Self.event], today: Self.today, now: Self.now, landings: LandingSingleFlight(),
            exportURL: export, importedHistory: AbsentHandoff.history,
            into: context)
    }

    @Test func thePasteRecognisesAClientFromTheExportItIsHanded() async throws {
        let container = try container()
        let result = await paste(container.mainContext, export: try exportNamingTheClient())
        guard case .landed(let outcome) = result else {
            Issue.record("the paste did not land: \(result)")
            return
        }
        #expect(outcome.inserted == 1)
        #expect(try landed(container).matchedClientName == Self.client)
    }

    @Test func aPasteWithNoExportLandsTheShowCold() async throws {
        let container = try container()
        let result = await paste(container.mainContext, export: AbsentHandoff.export)
        guard case .landed = result else {
            Issue.record("the paste did not land: \(result)")
            return
        }
        #expect(try landed(container).matchedClientName == nil)
    }

    // The lead sheet hands its export on to the paste it lands through.
    @Test func theLeadSheetHandsItsExportToThePaste() async throws {
        let container = try container()
        let url = URL(string: "https://piernine.example/season")!
        let leadId = LeadIntakeModel.sourceId(for: url)
        let answer = ScoutExtractResults(version: 1, generatedAt: Self.today + "T12:00:00Z", results: [
            ScoutExtractResult(sourceId: leadId, verdict: .upcomingListings,
                               events: [ScoutExtractEvent(title: "Harbor Lights", presenter: Self.client,
                                                          venue: "Pier Nine Room", performanceDate: "2026-11-21",
                                                          sourceUrl: "https://piernine.example/harbor-lights",
                                                          location: "New York, NY")],
                               note: nil)])
        let model = LeadIntakeModel(
            defaults: ScratchDefaults.make("LandingsReadTheExportTheyAreHanded.sheet"),
            fetch: { FetchedPage(normalizedHTML: LandingOracleCorpus.leadPage, finalURL: $0.absoluteString,
                                 contentHash: "lead-export-4582") },
            pin: { _, _ in URL(fileURLWithPath: "/dev/null/lead-export-4582.html") },
            launch: { _ in },
            readResults: { $0 == leadId ? answer : nil },
            isRunAlive: { false },
            landings: LandingSingleFlight(),
            exportURL: try exportNamingTheClient(), importedHistory: AbsentHandoff.history)
        model.urlText = url.absoluteString
        await model.start(into: container.mainContext, now: Self.now, today: Self.today, pollEvery: 0,
                          giveUpAfter: 0, sleep: { _ in })
        #expect(try landed(container).matchedClientName == Self.client, "the sheet said \(model.phase)")
    }
}
