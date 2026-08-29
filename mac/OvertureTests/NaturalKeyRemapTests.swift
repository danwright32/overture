import Testing
import Foundation
import SwiftData

// #1606: a paid check in flight when a launch rewrites natural keys settles into silence and the answer
// is lost.
//
// The probe's marker holds natural keys, and so does the results file the runner writes. A rekey rewrites
// `Prospect.naturalKey` with no record of the old value, so after it BOTH sides are stale in the same way
// and the settle's intersection matches nothing. Dan paid Opus tokens for a contact, the show goes back to
// looking unchecked, and he pays again. It is silent by construction.
//
// The fix is the durable one the issue prefers and the standing rule requires: when a key must change,
// record the old-to-new mapping for everything still holding the old one (L15). A second identifier on the
// marker alone would not have worked, because the results file is stale in exactly the same way.
@Suite("Carrying a key across a rekey (#1606)")
struct NaturalKeyRemapTests {

    private func dir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,
                                                                              isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private let at = Date(timeIntervalSince1970: 1_780_000_000)

    @Test func akeyThatWasNeverRenamedTranslatesToItself() {
        let remap = NaturalKeyRemap(entries: [])
        #expect(remap.current("a|2026-09-12|hall") == "a|2026-09-12|hall")
    }

    @Test func arenamedKeyTranslatesToItsNewOne() {
        let remap = NaturalKeyRemap(entries: [.init(from: "old", to: "new", at: at)])
        #expect(remap.current("old") == "new")
    }

    // A key renamed twice before anything read it must land on the final one, not the middle. A probe can
    // be in flight across more than one launch.
    @Test func achainOfRenamesLandsOnTheLast() {
        let remap = NaturalKeyRemap(entries: [.init(from: "a", to: "b", at: at),
                                              .init(from: "b", to: "c", at: at.addingTimeInterval(60))])
        #expect(remap.current("a") == "c")
    }

    // A cycle must not hang the settle. It cannot happen from a migration that only ever folds toward a
    // canonical key, which is exactly why it is worth pinning: the loop guard is invisible until something
    // upstream changes and it is the difference between a wrong answer and a frozen app.
    @Test func acycleTerminatesRatherThanSpinning() {
        let remap = NaturalKeyRemap(entries: [.init(from: "a", to: "b", at: at),
                                              .init(from: "b", to: "a", at: at.addingTimeInterval(60))])
        let resolved = remap.current("a")
        #expect(resolved == "a" || resolved == "b")
    }

    @Test func itsurvivesBeingWrittenAndReadBack() throws {
        let url = dir().appendingPathComponent("remap.json")
        try NaturalKeyRemap(entries: [.init(from: "old", to: "new", at: at)]).write(to: url)
        #expect(try NaturalKeyRemap.read(from: url).current("old") == "new")
    }

    // Nothing on disk is not an error. Every caller translates through it, so a first launch, or a Mac
    // where no rekey has ever run, has to read as "no renames" rather than as a failure that stops a
    // settle from happening at all.
    @Test func nofileReadsAsNoRenames() {
        let url = dir().appendingPathComponent("absent.json")
        #expect((try? NaturalKeyRemap.read(from: url))?.current("a") == "a")
    }

    // A rename recorded long ago cannot still be in flight, and keeping every one forever would grow a
    // file nothing prunes. The window is generous, because the thing it protects is a paid run.
    @Test func oldrenamesAreDroppedWhenRecording() {
        let stale = NaturalKeyRemap.Entry(from: "ancient", to: "x",
                                          at: at.addingTimeInterval(-NaturalKeyRemap.keepFor - 60))
        let fresh = NaturalKeyRemap.Entry(from: "recent", to: "y", at: at)
        let kept = NaturalKeyRemap(entries: [stale, fresh]).pruned(now: at)
        #expect(kept.current("recent") == "y")
        #expect(kept.current("ancient") == "ancient")
    }
}

// The end to end claim, and the one the issue is actually about: a check paid for before a rekey still
// lands its answer on the row afterwards.
@MainActor
@Suite("A paid answer survives a rekey (#1606)")
struct PaidAnswerSurvivesARekeyTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, OrgReachabilityAnswer.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func dir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,
                                                                              isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    // A show whose key the launch rewrote while a check was in flight. The marker and the results file
    // both hold the OLD key; the row holds the new one.
    @Test func ananswerKeyedToTheOldNameStillStampsTheRow() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let oldKey = "aurora strings|2026-09-12|weill recital hall (57th st)"
        let newKey = "aurora strings|2026-09-12|weill recital hall"

        let p = Prospect(naturalKey: newKey, groupName: "Aurora Strings", discipline: "music",
                         venue: "Weill Recital Hall", performanceDate: "2026-09-12",
                         sourceListingURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 6, tier: "mid", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .new)
        ctx.insert(p)
        try ctx.save()

        let d = dir()
        let remapURL = d.appendingPathComponent("remap.json")
        try NaturalKeyRemap.record([(from: oldKey, to: newKey)], at: now, url: remapURL)

        let resultsURL = d.appendingPathComponent("results.json")
        try JSONEncoder().encode(
            PrepResults(version: 2, generatedAt: "now",
                        results: [PrepResult(naturalKey: oldKey, contacts: nil, draft: nil)]))
            .write(to: resultsURL)

        var saveFailed = false
        let stamped = PrepQueueService.markProbed(keys: [oldKey], answeredIn: resultsURL, in: ctx,
                                                  now: now, anIngestIsStillToCome: false,
                                                  saveFailed: &saveFailed, remapURL: remapURL)

        #expect(stamped == [newKey], "the answer must land on the row the rekey produced")
        #expect(try #require(ctx.fetch(FetchDescriptor<Prospect>()).first).reachabilityProbedAt == now,
                "the show Dan paid to research must not read as unchecked afterwards")
    }

    // And it is not recorded as a shortfall either, which would tell Dan a run came home short when it
    // answered everything it was asked.
    @Test func arekeyedShowIsNotCountedAsMissed() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let oldKey = "old|2026-09-12|hall"
        let newKey = "new|2026-09-12|hall"

        let p = Prospect(naturalKey: newKey, groupName: "Aurora", discipline: "music", venue: "Hall",
                         performanceDate: "2026-09-12", sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .new)
        ctx.insert(p)
        try ctx.save()

        let d = dir()
        let remapURL = d.appendingPathComponent("remap.json")
        try NaturalKeyRemap.record([(from: oldKey, to: newKey)], at: now, url: remapURL)
        let resultsURL = d.appendingPathComponent("results.json")
        try JSONEncoder().encode(
            PrepResults(version: 2, generatedAt: "now",
                        results: [PrepResult(naturalKey: oldKey, contacts: nil, draft: nil)]))
            .write(to: resultsURL)

        var saveFailed = false
        _ = PrepQueueService.markProbed(keys: [oldKey], answeredIn: resultsURL, in: ctx, now: now,
                                        anIngestIsStillToCome: false, saveFailed: &saveFailed,
                                        remapURL: remapURL)

        #expect(try #require(ctx.fetch(FetchDescriptor<Prospect>()).first).reachabilityUnansweredAt == nil)
    }
}
