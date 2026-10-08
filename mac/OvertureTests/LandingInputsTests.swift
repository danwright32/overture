import Testing
import Foundation
import SwiftData

// #4339 (A11): the show table reads in the first hold of the calendar ingest and of `runScout` leave the main
// thread, behind the entry flush, and a table that cannot be read is recorded rather than read as empty.
private struct Unreadable: Error {}

private struct NoFeed: SourceExtractor {
    func extract() async throws -> ExtractedListing { ExtractedListing(events: [], verdict: .noDatedContent) }
}

// Which thread each table read ran on, from whatever thread it ran.
private final class Threads: @unchecked Sendable {
    private let lock = NSLock()
    private var onMain: [Bool] = []
    func note() { lock.withLock { onMain.append(Thread.isMainThread) } }
    var all: [Bool] { lock.withLock { onMain } }
}

@MainActor
@Suite("#4339 the landing inputs are read off the main thread, behind the entry flush")
final class LandingInputsTests {
    private func seeded() throws -> (ModelContainer, ModelContext) {
        let c = try TestModelContainer.inMemory(AppSchema.models)
        let ctx = c.mainContext
        ctx.insert(Prospect(naturalKey: "stored-0", groupName: "Stored Show", discipline: "music",
                            venue: "Venue Hall", performanceDate: "2026-11-21",
                            sourceListingURL: "https://stored.example/0", priorRelationship: "none",
                            production: "self", profile: "strong", coverage: "likely_uncovered",
                            fitScore: 5, tier: "mid", fitReason: "r", matchedClientName: nil,
                            possibleMatchSource: nil, possibleMatchName: nil))
        try ctx.save()
        return (c, ctx)
    }

    @Test func theIngestsHistoryIsReadOffTheMainThread() async throws {
        let (container, ctx) = try seeded()
        defer { withExtendedLifetime(container) {} }
        let threads = Threads()
        let inputs = await LandingInputs.read(exportURL: AbsentHandoff.export, historyURL: AbsentHandoff.history,
                                              readProspectTable: { threads.note(); return try ScoutService.readProspectTable($0) },
                                              into: ctx)
        #expect(threads.all == [false], "the show table was read on threads \(threads.all) (true is main)")
        #expect(inputs.degradedReads.isEmpty)
    }

    @Test func anUnreadableTableIsRecordedAndTheHistoryIsTheImportedRecordAlone() async throws {
        let (container, ctx) = try seeded()
        defer { withExtendedLifetime(container) {} }
        let inputs = await LandingInputs.read(exportURL: AbsentHandoff.export, historyURL: AbsentHandoff.history,
                                              readProspectTable: { _ in throw Unreadable() }, into: ctx)
        #expect(inputs.degradedReads == [.repeatClientHistory])
        #expect(inputs.history == LocalHistory.forMatching(existing: [], importedFrom: AbsentHandoff.history))
    }

    // #4526: the idle landing recovery's read. The same builder, off the main thread the same way, but a table
    // that cannot be read REFUSES rather than falling back to the imported history: a replay landed against the
    // imported record alone would retire its kept copy matched against a store it never saw (L215).
    @Test func theRefusingReadIsOffTheMainThreadAndBuildsWhatTheOrdinaryReadBuilds() async throws {
        let (container, ctx) = try seeded()
        defer { withExtendedLifetime(container) {} }
        let threads = Threads()
        let refusing = await LandingInputs.readRefusingUnreadableShowTable(
            exportURL: AbsentHandoff.export, historyURL: AbsentHandoff.history,
            readProspectTable: { threads.note(); return try ScoutService.readProspectTable($0) }, into: ctx)
        #expect(threads.all == [false], "the show table was read on threads \(threads.all) (true is main)")
        let ordinary = await LandingInputs.read(exportURL: AbsentHandoff.export, historyURL: AbsentHandoff.history,
                                                into: ctx)
        guard case .success(let inputs) = refusing else {
            Issue.record("a table that reads was refused")
            return
        }
        #expect(inputs.history == ordinary.history)
        #expect(inputs.clients == ordinary.clients)
        #expect(inputs.degradedReads.isEmpty)
    }

    @Test func theRefusingReadRefusesAnUnreadableTable() async throws {
        let (container, ctx) = try seeded()
        defer { withExtendedLifetime(container) {} }
        let refusing = await LandingInputs.readRefusingUnreadableShowTable(
            exportURL: AbsentHandoff.export, historyURL: AbsentHandoff.history,
            readProspectTable: { _ in throw Unreadable() }, into: ctx)
        guard case .failure(let unreadable) = refusing else {
            Issue.record("an unreadable show table was handed on as inputs")
            return
        }
        #expect(unreadable.description.contains("Unreadable"), Comment(rawValue: unreadable.description))
    }

    // #4558: the lead paste's read. The same builder, but the ONE table read also builds the brand corpus the
    // paste's classify pass needs (#4493: the paste reads the table once, for both), and a table that cannot be
    // read DEGRADES, as the ingest's does, rather than refusing. One stored show is a venue brand (its presenter
    // is a room) and carries a history record (do not contact), so an empty corpus or history would differ.
    @Test func theCorpusReadBuildsTheHistoryAndTheCorpusFromOneTableReadOffTheMainThread() async throws {
        let (container, ctx) = try seeded()
        defer { withExtendedLifetime(container) {} }
        let stored = try #require(try ctx.fetch(FetchDescriptor<Prospect>()).first)
        stored.presenter = "Venue Hall"
        stored.orgDoNotContact = true
        try ctx.save()
        let threads = Threads()
        let read = await LandingInputs.readWithBrandCorpus(
            exportURL: AbsentHandoff.export, historyURL: AbsentHandoff.history,
            readProspectTable: { threads.note(); return try ScoutService.readProspectTable($0) }, into: ctx)
        #expect(threads.all == [false], "the show table was read on threads \(threads.all) (true is main)")
        let ordinary = await LandingInputs.read(exportURL: AbsentHandoff.export, historyURL: AbsentHandoff.history,
                                                into: ctx)
        #expect(!ordinary.history.isEmpty, "the positive control: the stored show is in the history")
        #expect(read.inputs.history == ordinary.history)
        #expect(read.inputs.clients == ordinary.clients)
        #expect(read.inputs.degradedReads.isEmpty)
        #expect(read.corpus.brands == ScoutService.venueBrandCorpus(in: ctx).brands)
        #expect(read.corpus.brands.contains("Venue Hall"), "the corpus was built from no shows")
        #expect(read.corpus.degradedReads.isEmpty)
    }

    @Test func theCorpusReadDegradesAnUnreadableTableRatherThanRefusing() async throws {
        let (container, ctx) = try seeded()
        defer { withExtendedLifetime(container) {} }
        let read = await LandingInputs.readWithBrandCorpus(
            exportURL: AbsentHandoff.export, historyURL: AbsentHandoff.history,
            readProspectTable: { _ in throw Unreadable() }, into: ctx)
        #expect(read.inputs.degradedReads == [.repeatClientHistory])
        #expect(read.inputs.history == LocalHistory.forMatching(existing: [], importedFrom: AbsentHandoff.history))
        #expect(read.corpus.degradedReads == [.venueBrandCorpus])
    }

    // #4558: Downbeat's export is read off the main thread, inside the table read's own background task, by every
    // read (#4493 moved the paste's there; the others used to read it on the main thread, measured at 0.3 ms).
    @Test func everyReadTakesDownbeatsExportOffTheMainThread() async throws {
        let (container, ctx) = try seeded()
        defer { withExtendedLifetime(container) {} }
        let threads = Threads()
        let load: LandingInputs.ExportLoad = { threads.note(); return LandingInputs.loadExportFile($0, $1) }
        _ = await LandingInputs.read(exportURL: AbsentHandoff.export, historyURL: AbsentHandoff.history,
                                     loadExport: load, into: ctx)
        _ = await LandingInputs.readRefusingUnreadableShowTable(exportURL: AbsentHandoff.export,
                                                                historyURL: AbsentHandoff.history,
                                                                loadExport: load, into: ctx)
        _ = await LandingInputs.readWithBrandCorpus(exportURL: AbsentHandoff.export, historyURL: AbsentHandoff.history,
                                                    loadExport: load, into: ctx)
        #expect(threads.all == [false, false, false], "the export was read on threads \(threads.all) (true is main)")
    }

    // The read phase saves nothing: with an edit of Dan's pending, the history is read on the main thread, where
    // the context sees the edit, and the edit is left pending for the landing's own flush to save.
    @Test func aPendingEditKeepsTheReadOnTheMainThreadAndIsNotSaved() async throws {
        let (container, ctx) = try seeded()
        defer { withExtendedLifetime(container) {} }
        let stored = try #require(try ctx.fetch(FetchDescriptor<Prospect>()).first)
        stored.groupName = "Renamed By Dan"
        let threads = Threads()
        _ = await LandingInputs.read(exportURL: AbsentHandoff.export, historyURL: AbsentHandoff.history,
                                     readProspectTable: { threads.note(); return try ScoutService.readProspectTable($0) },
                                     into: ctx)
        #expect(threads.all == [true], "a read with an edit pending ran on \(threads.all), where the edit is unseen")
        #expect(ctx.hasChanges, "the read phase saved Dan's pending edit")
        let fresh = try ModelContext(container).fetch(FetchDescriptor<Prospect>()).map(\.groupName)
        #expect(fresh == ["Stored Show"], "the read phase wrote the store: \(fresh)")
    }

    @Test func runScoutReadsItsHistoryOffTheMainThread() async throws {
        let (container, ctx) = try seeded()
        defer { withExtendedLifetime(container) {} }
        let threads = Threads()
        _ = try await ScoutService.runScout(
            into: ctx, depth: .watchOnly, extractor: NoFeed(), extractorRegistry: { _ in nil },
            fetch: { url, _, _ in FetchedPage(normalizedHTML: "<p/>", finalURL: url.absoluteString, contentHash: "x") },
            pin: { _, id in URL(fileURLWithPath: "/dev/null/\(id).html") }, launch: { _ in },
            defaults: ScratchDefaults.make("LandingInputsTests"),
            readProspectTable: { threads.note(); return try ScoutService.readProspectTable($0) },
            landings: LandingSingleFlight(),
            exportURL: AbsentHandoff.export, importedHistory: AbsentHandoff.history)
        #expect(threads.all.first == false, "runScout's first table read, its history, ran on the main thread: \(threads.all)")
    }
}

// #4558: ONE builder of a landing's inputs, `LandingInputs`, so no entry point can come to judge a show against a
// different history, client list or blocked calendar from the others (L370). DERIVED from the code rather than a
// list of names (L96): the files holding a landing call are `LandingEntryPointsAreDerivedTests.derive`'s own
// sites, so a new landing is covered the day it is written.
//
// Two rules. The history the matcher sees (`LocalHistory.forMatching`) is built in `LandingInputs.swift` and
// nowhere else in the app. And no file holding a landing reads Downbeat's export (`DownbeatBridge.loadWithHealth`)
// or builds the blocked calendar (`blockedCalendar(export:`) itself. What it cannot see, so its silence is read
// correctly: an export read or a calendar built in a file holding NO landing and handed in from there (both have
// readers that are not landings, the Days off sheet and the client roster among them, so they cannot be refused
// tree wide), and a bare `forMatching(` inside `LocalHistory` itself.
@MainActor
enum LandingInputsBuilderScan {
    static let inputsFile = "Integration/LandingInputs.swift"

    struct Finding: Equatable, CustomStringConvertible {
        let file: String
        let line: Int
        let builds: String
        var description: String { "\(file):\(line) builds \(builds)" }
    }

    private static let history = try! NSRegularExpression(pattern: #"\bLocalHistory\s*\.\s*forMatching\s*\("#)
    private static let export = try! NSRegularExpression(pattern: #"\bDownbeatBridge\s*\.\s*loadWithHealth\s*\("#)
    private static let blocked = try! NSRegularExpression(pattern: #"(?<!func )\bblockedCalendar\s*\(\s*export\s*:"#)

    // `code` is each file's code lines, comments and string contents removed (`StoreWriteScan.Index.code`).
    static func findings(code: [String: [(line: Int, code: String)]], landingFiles: Set<String>) -> [Finding] {
        var out: [Finding] = []
        for (file, lines) in code where file != inputsFile {
            let joined = LandingEntryPointsAreDerivedTests.joined(lines)
            var rules: [(NSRegularExpression, String)] = [(history, "the match history")]
            if landingFiles.contains(file) {
                rules += [(export, "Downbeat's export read"), (blocked, "the blocked calendar")]
            }
            for (re, builds) in rules {
                for m in re.matches(in: joined.text, range: NSRange(location: 0, length: joined.text.utf16.count)) {
                    out.append(Finding(file: file, line: joined.line(at: m.range.location), builds: builds))
                }
            }
        }
        return out.sorted { ($0.file, $0.line) < ($1.file, $1.line) }
    }
}

@MainActor
@Suite("#4558 every landing builds its inputs through LandingInputs, and only there")
struct LandingInputsHaveOneBuilderTests {

    @Test func noLandingBuildsItsOwnInputs() {
        let files = LandingEntryPointsAreDerivedTests.appFiles()
        let index = StoreWriteScan.Index(files: files)
        let sites = Set(LandingEntryPointsAreDerivedTests.derive(files).sites)
        let landingFiles = Set(index.functions.filter { sites.contains($0.qualifiedName) }.map(\.file))
        // POSITIVE CONTROL (L98): the landings were found where the code is known to hold them, so an empty
        // derivation cannot read as a tree with no second builder in it.
        for known in ["Integration/ScoutService.swift", "Integration/LeadPasteLanding.swift"] {
            #expect(landingFiles.contains(known), Comment(rawValue: "no landing found in \(known): \(landingFiles.sorted())"))
        }
        let findings = LandingInputsBuilderScan.findings(code: index.code, landingFiles: landingFiles)
        #expect(findings.isEmpty, Comment(rawValue: """
            a landing builds its own inputs beside LandingInputs: \
            \(findings.map(\.description).joined(separator: "; ")). Read them through LandingInputs, adding an \
            option there with its own test where the difference is deliberate.
            """))
    }

    // Each deliberate difference is wired where it belongs: runScout REFUSES an unreadable show table (#3071), and
    // the lead paste reads its brand corpus from the same table read and degrades (#4493).
    @Test func eachEntryPointReadsThroughItsOwnOption() throws {
        let scout = SourceGuardHelper.source("Overture/Integration/ScoutService.swift")
        let run = try #require(SourceGuardHelper.bodyOfFunction(named: "runScout", in: scout))
        #expect(run.contains("LandingInputs.readRefusingUnreadableShowTable("), "runScout does not refuse through LandingInputs")
        let paste = SourceGuardHelper.source("Overture/Integration/LeadPasteLanding.swift")
        let land = try #require(SourceGuardHelper.bodyOfFunction(named: "landPastedLead", in: paste))
        #expect(land.contains("LandingInputs.readWithBrandCorpus("), "the paste does not read through LandingInputs")
    }

    // The rule on sources written here, so the scan is seen to find each kind of second builder, and to leave the
    // builder's own file, a definition, a comment and a file holding no landing alone.
    @Test func theScanFindsASecondBuilderAndNothingElse() {
        let files: [(name: String, text: String)] = [
            (name: "Integration/LandingInputs.swift", text: """
                enum LandingInputs {
                    static func read() { _ = LocalHistory.forMatching(existing: []) }
                    static func more() { _ = DownbeatBridge.loadWithHealth(now: Date()) }
                }
                """),
            (name: "Integration/Paste.swift", text: """
                enum Paste {
                    // LocalHistory.forMatching(existing: rows) is only named here
                    static func land() {
                        let loaded = DownbeatBridge.loadWithHealth(
                            now: Date())
                        _ = ScoutService.blockedCalendar(
                            export: loaded, context: c)
                    }
                    static func blockedCalendar(export: Int, context: Int) {}
                }
                """),
            (name: "Domain/Elsewhere.swift", text: """
                enum Elsewhere {
                    static func a() { _ = DownbeatBridge.loadWithHealth(now: Date()) }
                    static func b() { _ = LocalHistory . forMatching(existing: []) }
                }
                """),
        ]
        let index = StoreWriteScan.Index(files: files)
        let found = LandingInputsBuilderScan.findings(code: index.code, landingFiles: ["Integration/Paste.swift"])
        #expect(found == [
            .init(file: "Domain/Elsewhere.swift", line: 3, builds: "the match history"),
            .init(file: "Integration/Paste.swift", line: 4, builds: "Downbeat's export read"),
            .init(file: "Integration/Paste.swift", line: 6, builds: "the blocked calendar"),
        ], Comment(rawValue: found.map(\.description).joined(separator: "; ")))
    }
}
