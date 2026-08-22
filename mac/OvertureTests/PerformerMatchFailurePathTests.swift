import Testing
import Foundation
import SwiftData

// Phase 6 (#754): the failure paths. The performer matcher is only as good as the reference data it
// reads, and both of its inputs are files on disk written by other processes. If either is missing or
// corrupt at Prep time, EVERY match quietly finds nothing and a real past client reads as a cold
// lead, with no symptom at all. That is the exact "fail loud, not silent" trap: an empty result that
// looks identical to a healthy run that genuinely found nothing.
@MainActor
@Suite("Performer match: failure paths and idempotency (#754)")
struct PerformerMatchFailurePathTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("performer-failure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - The matcher itself never crashes and never guesses

    // Reference data can be legitimately empty (a fresh install). The matcher must return a clean
    // no-match, never a crash and never a false-positive default.
    @Test func aMatcherWithNoReferenceDataAtAllReturnsACleanNoMatch() {
        let verdict = HistoryMatch.matchPerformer(
            performerName: "Larkin Sable", performerEmail: "larkin@sableviolin.example",
            production: .selfProduced, clients: [], history: [])

        #expect(verdict == .noMatch)
        #expect(!verdict.isMatch)
        #expect(verdict.relationship == .none)
        #expect(verdict.note == nil)
    }

    // Garbage in the reference data must not become a match. A history record with an empty group
    // name is the dangerous one: two empty token sets are "equal", so a careless implementation would
    // match EVERY performer against it.
    @Test func emptyOrGarbageReferenceRecordsNeverMatchAnyone() {
        let junk = [
            HistoryRecord(groupName: "", status: "booked"),
            HistoryRecord(groupName: "   ", status: "booked"),
            HistoryRecord(groupName: ",,,", status: "warm"),
        ]
        let verdict = HistoryMatch.matchPerformer(
            performerName: "Larkin Sable", performerEmail: "", production: .selfProduced,
            clients: [], history: junk)

        #expect(verdict == .noMatch)
    }

    // MARK: - Missing or corrupt reference files are reported, not swallowed

    @Test func anAbsentBookingHistoryIsNormalAndNotAnError() throws {
        let missing = try tempDir().appendingPathComponent("overture-history.json")
        let loaded = LocalHistory.importedWithHealth(from: missing)

        #expect(loaded.records.isEmpty)
        #expect(!loaded.unreadable)   // no legacy import yet is a normal state, not a fault
    }

    // The one that matters: a CORRUPT file used to be indistinguishable from an absent one, because
    // both just returned an empty array.
    @Test func aCorruptBookingHistoryIsReportedAsUnreadableRatherThanReadingAsEmpty() throws {
        let path = try tempDir().appendingPathComponent("overture-history.json")
        try Data("{ this is not the history file }".utf8).write(to: path)

        let loaded = LocalHistory.importedWithHealth(from: path)

        #expect(loaded.records.isEmpty)
        #expect(loaded.unreadable)
    }

    @Test func healthyReferenceDataRaisesNoWarning() {
        #expect(PrepImporter.matchDataWarning(clientHealth: .ok, historyUnreadable: false) == nil)
    }

    @Test func everyBrokenReferenceStateRaisesAWarningThatNamesTheConsequence() {
        for health in [DownbeatBridge.Health.missing, .unreadable, .stale(ageDays: 45)] {
            let warning = PrepImporter.matchDataWarning(clientHealth: health, historyUnreadable: false)
            let text = try! #require(warning, "\(health) must warn")
            #expect(text.contains("cold"))   // says what it COSTS Dan, not just that a file is bad
        }

        let historyWarning = PrepImporter.matchDataWarning(clientHealth: .ok, historyUnreadable: true)
        #expect(historyWarning?.contains("booking history") == true)

        // Both broken at once: both are named, neither is masked by the other.
        let both = PrepImporter.matchDataWarning(clientHealth: .missing, historyUnreadable: true)
        #expect(both?.contains("Downbeat") == true)
        #expect(both?.contains("booking history") == true)
    }

    // MARK: - End to end through the real entry point

    private func writePrepResults(_ dir: URL, key: String) throws -> URL {
        let path = dir.appendingPathComponent("overture-prep-results.json")
        let json = """
        {"version":3,"generatedAt":"now","results":[{"naturalKey":"\(key)",
        "contacts":[{"name":"Larkin Sable","role":"Violinist","email":"larkin@sableviolin.example",
        "method":"named_decision_maker","confidence":"high","provenance":"performer"}]}]}
        """
        try Data(json.utf8).write(to: path)
        return path
    }

    private func coldProspect(_ ctx: ModelContext) -> Prospect {
        let key = Prospect.makeNaturalKey(groupName: "Emerging Artists Series",
                                          performanceDate: "2026-08-02", venue: "Weill Recital Hall")
        let p = Prospect(naturalKey: key, groupName: "Emerging Artists Series", discipline: "music",
                         venue: "Weill Recital Hall", performanceDate: "2026-08-02",
                         sourceListingURL: nil, websiteURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 7, tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .queued)
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    // A corrupt client export at Prep time: the prospect is still ingested normally (a bad reference
    // file must not take the whole run down), the performer match correctly finds nothing, AND Dan is
    // told why, rather than being left with a silently cold lead.
    @Test func aCorruptClientExportStillIngestsButWarnsInsteadOfSilentlyScoringCold() throws {
        let ctx = ModelContext(try container())
        let p = coldProspect(ctx)
        let dir = try tempDir()
        let results = try writePrepResults(dir, key: p.naturalKey)
        let downbeat = dir.appendingPathComponent("downbeat-export.json")
        try Data("<<not json>>".utf8).write(to: downbeat)

        let outcome = try PrepImporter.ingestFile(at: results, into: ctx,
                                                  downbeatURL: downbeat,
                                                  historyURL: dir.appendingPathComponent("nope.json"))

        #expect(outcome.matched == 1)                          // the run itself survives
        #expect(!p.relationshipCorrectedByPerformerMatch)      // no match, correctly
        #expect(p.fitScore == 7)
        let warning = try #require(outcome.matchDataWarning)   // and it is NOT silent
        #expect(warning.contains("cold"))
    }

    // MARK: - Assume it runs twice

    // Ingesting the identical prep-results file twice through the real entry point must be a true
    // no-op the second time: no re-snapshot (which would destroy the record of what the scout had),
    // and no reset of a review Dan has already given.
    @Test func ingestingTheIdenticalFileTwiceIsATrueNoOp() throws {
        let ctx = ModelContext(try container())
        let p = coldProspect(ctx)
        let dir = try tempDir()
        let results = try writePrepResults(dir, key: p.naturalKey)

        let downbeat = dir.appendingPathComponent("downbeat-export.json")
        let export = """
        {"version":2,"clients":[{"id":"client-larkin","displayName":"Larkin Sable","email":"",
        "contractEmail":"","hasLeftReview":false,"specialBehaviors":[],"hostingSite":""}],
        "venues":[],"bookings":[],"blockedDates":[]}
        """
        try Data(export.utf8).write(to: downbeat)
        let history = dir.appendingPathComponent("overture-history.json")
        try Data("[]".utf8).write(to: history)

        let first = try PrepImporter.ingestFile(at: results, into: ctx,
                                                downbeatURL: downbeat, historyURL: history)
        #expect(first.matchDataWarning == nil)   // healthy data, no noise
        #expect(p.relationshipCorrectedByPerformerMatch)
        #expect(p.fitScore == 27)

        p.confirmPerformerMatch()   // Dan agrees with it
        try ctx.save()

        _ = try PrepImporter.ingestFile(at: results, into: ctx,
                                        downbeatURL: downbeat, historyURL: history)

        #expect(p.performerMatchReviewed)                  // his review is not silently thrown away
        #expect(p.performerMatchPreviousFitScore == 7)     // still the SCOUT's score, not 27
        #expect(p.performerMatchPreviousRelationship == "none")
        #expect(p.fitScore == 27)
        #expect(p.matchedPerformerName == "Larkin Sable")
    }
}
