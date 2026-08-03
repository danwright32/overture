import Testing
import Foundation
import SwiftData

// #1018: a reply-classify run that comes back with fewer replies than it was queued.
//
// The importer already reports a result that matches no saved prospect (Outcome.unmatchedKeys). It had
// nothing for the other direction: a reply queued in overture-reply-classify-queue.json that the run
// never came back with (it crashed, died mid-batch, or simply skipped it). Left silent, a reply Dan
// needs answered sits unclassified and un-drafted run after run, with no signal anywhere that it was
// missed. The same class of silent loss #1011/#1013 closed for scout and #876 closed for Prep.
//
// The rule mirrors Prep's HandoffShortfall exactly, with one difference that is the whole point:
// reply-classify is per-RECIPIENT, so two contacts on one show are two independent queue items, and a
// shortfall keyed on the show alone would miss a dropped recipient whose show came back for a sibling.
@MainActor
@Suite("A reply-classify run that comes back short says so (#1018)")
struct ReplyClassifyShortfallTests {

    private let queued = Date(timeIntervalSince1970: 1_000_000)
    private let answered = Date(timeIntervalSince1970: 1_000_600)   // ten minutes later

    private func key(_ nk: String, _ rid: String?) -> ReplyClassifyKey {
        ReplyClassifyKey(naturalKey: nk, recipientId: rid)
    }

    // --- The rule, in isolation (shared HandoffShortfall, reply-classify's per-recipient key) --------

    @Test func aRunThatAnswersEveryReplyIsShort0() {
        let missing = HandoffShortfall.missingKeys(
            queuedKeys: [key("a", "r1"), key("b", "r2")],
            answeredKeys: [key("a", "r1"), key("b", "r2")],
            queueGeneratedAt: queued, resultsModifiedAt: answered)
        #expect(missing.isEmpty)
    }

    // THE reason the key is a (naturalKey, recipientId) pair, not the show alone. Both contacts are on
    // the SAME show; the run answered one and dropped the other. A show-keyed diff would see "show" in
    // the results and call it fully answered, losing the dropped recipient in silence.
    @Test func twoContactsOnOneShowAreCountedIndependently() {
        let missing = HandoffShortfall.missingKeys(
            queuedKeys: [key("show", "act@e.com"), key("show", "pres@e.com")],
            answeredKeys: [key("show", "act@e.com")],
            queueGeneratedAt: queued, resultsModifiedAt: answered)
        #expect(missing == [key("show", "pres@e.com")])
    }

    // The cry-wolf guard, same as Prep's: startClassify writes a FRESH queue but leaves the PREVIOUS
    // run's results file on disk, so a run that dies without writing anything leaves a new queue beside
    // stale results. Results that PREDATE the queue are not an answer to it and raise no alarm.
    @Test func resultsOlderThanTheQueueRaiseNoAlarm() {
        let stale = queued.addingTimeInterval(-60)
        let missing = HandoffShortfall.missingKeys(
            queuedKeys: [key("a", "r1"), key("b", "r2")], answeredKeys: [],
            queueGeneratedAt: queued, resultsModifiedAt: stale)
        #expect(missing.isEmpty)
    }

    @Test func anUnknownQueueOrResultsFileRaisesNoAlarm() {
        #expect(HandoffShortfall.missingKeys(queuedKeys: [key("a", "r1")], answeredKeys: [],
                                             queueGeneratedAt: nil, resultsModifiedAt: answered).isEmpty)
        #expect(HandoffShortfall.missingKeys(queuedKeys: [key("a", "r1")], answeredKeys: [],
                                             queueGeneratedAt: queued, resultsModifiedAt: nil).isEmpty)
    }

    // --- Through the importer, against real files -----------------------------------------------------

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private func prospect(_ ctx: ModelContext, key: String, recipientIds: [String]) {
        let p = Prospect(naturalKey: key, groupName: "Aurora Strings", discipline: "music",
                         venue: "Weill Recital Hall", performanceDate: "2099-09-19",
                         sourceListingURL: nil, websiteURL: nil, priorRelationship: "warm",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 8, tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil)
        p.outcome = .replied
        let recipients = recipientIds.map { rid -> Recipient in
            let r = Recipient(id: rid, email: rid, provenance: .act)
            r.sendState = .sent; r.replied = true
            return r
        }
        p.setRecipients(recipients)
        ctx.insert(p)
        try? ctx.save()
    }

    // Every file goes into a TEMP directory with an explicit URL. A test that reaches for a default
    // handoff path writes into the LIVE Debug store's directory and can leave a fake work-list on disk.
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reply-classify-shortfall-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeQueue(_ pairs: [(String, String)], to dir: URL, generatedAt: String) throws -> URL {
        let items = pairs.map {
            ReplyClassifyItem(naturalKey: $0.0, groupName: "Aurora Strings", venue: "Weill Recital Hall",
                              performanceDate: "2099-09-19", replyText: "Sounds good.", recipientId: $0.1)
        }
        let url = dir.appendingPathComponent("overture-reply-classify-queue.json")
        try ReplyClassifyQueueBuilder.encode(
            ReplyClassifyQueue(version: ReplyClassifyQueueBuilder.version,
                               generatedAt: generatedAt, items: items)).write(to: url)
        return url
    }

    private func writeResults(_ pairs: [(String, String)], to dir: URL) throws -> URL {
        let results = ReplyClassifyResults(version: 3, generatedAt: "2099-01-01T00:00:00Z",
            results: pairs.map {
                ReplyClassifyResult(naturalKey: $0.0, intent: "interested", recipientId: $0.1,
                                    draftSubject: "Re: your concert", draftBody: "Thanks for writing.")
            })
        let url = dir.appendingPathComponent("overture-reply-classify-results.json")
        try JSONEncoder().encode(results).write(to: url)
        return url
    }

    // THE issue, end to end. Two contacts on one show were queued; the run came back with one, and the
    // dropped one now has a detectable shortfall entry keyed to the exact recipient.
    @Test func theImporterNamesTheRepliesThatNeverCameBack() throws {
        let ctx = try context()
        prospect(ctx, key: "show", recipientIds: ["act@e.com", "pres@e.com"])
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let queueURL = try writeQueue([("show", "act@e.com"), ("show", "pres@e.com")], to: dir,
                                      generatedAt: ISO8601DateFormatter().string(
                                        from: Date().addingTimeInterval(-3600)))
        let resultsURL = try writeResults([("show", "act@e.com")], to: dir)

        let outcome = try ReplyClassifyImporter.ingestFile(at: resultsURL, into: ctx, queueURL: queueURL)

        #expect(outcome.matched == 1)
        #expect(outcome.missingKeys == [ReplyClassifyKey(naturalKey: "show", recipientId: "pres@e.com")])
    }

    @Test func aFullRunNamesNobody() throws {
        let ctx = try context()
        prospect(ctx, key: "show", recipientIds: ["act@e.com", "pres@e.com"])
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let queueURL = try writeQueue([("show", "act@e.com"), ("show", "pres@e.com")], to: dir,
                                      generatedAt: ISO8601DateFormatter().string(
                                        from: Date().addingTimeInterval(-3600)))
        let resultsURL = try writeResults([("show", "act@e.com"), ("show", "pres@e.com")], to: dir)

        let outcome = try ReplyClassifyImporter.ingestFile(at: resultsURL, into: ctx, queueURL: queueURL)

        #expect(outcome.missingKeys.isEmpty)
    }

    // A queue generated AFTER the results on disk (a run that died without writing anything, leaving the
    // previous run's results behind). Nothing was dropped BY this queue's run, because it never produced
    // anything at all: never "2 didn't come back" about a run that never ran.
    @Test func aQueueNewerThanTheResultsOnDiskRaisesNoAlarm() throws {
        let ctx = try context()
        prospect(ctx, key: "show", recipientIds: ["act@e.com", "pres@e.com"])
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let resultsURL = try writeResults([("old", "gone@e.com")], to: dir)   // last run's leftovers
        let queueURL = try writeQueue([("show", "act@e.com"), ("show", "pres@e.com")], to: dir,
                                      generatedAt: ISO8601DateFormatter().string(
                                        from: Date().addingTimeInterval(3600)))

        let outcome = try ReplyClassifyImporter.ingestFile(at: resultsURL, into: ctx, queueURL: queueURL)

        #expect(outcome.missingKeys.isEmpty)
    }

    // A missing queue file means we have no record of what was asked. Ingest Dan's drafts anyway; a gap
    // in our own bookkeeping is never a reason to invent a failure.
    @Test func aMissingQueueFileClaimsNothing() throws {
        let ctx = try context()
        prospect(ctx, key: "show", recipientIds: ["act@e.com"])
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let resultsURL = try writeResults([("show", "act@e.com")], to: dir)
        let absentQueue = dir.appendingPathComponent("no-such-queue.json")

        let outcome = try ReplyClassifyImporter.ingestFile(at: resultsURL, into: ctx, queueURL: absentQueue)

        #expect(outcome.matched == 1)
        #expect(outcome.missingKeys.isEmpty)
    }
}
