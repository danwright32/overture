import Testing
import Foundation
import SwiftData

// #3358 Phase 2. Today there are exactly two probe outcomes and BOTH start a 90 day lockout, so a run
// killed by the stuck-tool watchdog, rate limited, or simply thin is written down as a firm negative on
// a show with a live date. Phase 2's constraint is that the wrong verdict be impossible to STORE, not
// rarer.
//
// This is now answerable because of #3443: `record_web_calls` and `record_run_cost` share one definition
// of a finished stream (the terminal result envelope), so `webCalls.recorded` is a trustworthy statement
// that the run did not finish. Before that it said `recorded: true` about a run that lost seven shows.
//
// Dan's call, 2026-09-01, asked directly because guessing either way costs something real: "Distrust
// them, re-check." If the run did not finish, no show it answered with NOTHING gets the lockout; they
// all come back for another look. A show it answered WITH contacts keeps them, because the contacts are
// evidence and re-checking those would spend money to rediscover an address already on the row.
//
// No new state is invented for this. A distrusted show routes to the UNANSWERED path that #1724 and
// #2621 already built, which sets no `reachabilityProbedAt`, offers a re-check through
// `recheckState`'s `missedByACheck` arm, and has its own badge.
@MainActor
@Suite("A run that did not finish writes off nothing (#3358 Phase 2)")
struct ADeadRunWritesOffNothingTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func scratch() throws -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dead-run-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @discardableResult
    private func show(_ ctx: ModelContext, _ key: String) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: "Kestrel Quartet", discipline: "music",
                         venue: "Rowan Hall", performanceDate: "2027-04-18", sourceListingURL: nil,
                         priorRelationship: "none", production: "unknown", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .new)
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    // `recorded` is what the app branches on; `total` is absent on the incomplete path by design, which
    // is the rule `record_web_calls` follows and #3443 made honest.
    private func results(_ dir: URL, key: String, finished: Bool, contacts: String = "") throws -> URL {
        let url = dir.appendingPathComponent("overture-check-results.json")
        // `items`, `capPerItem` and `allowance` are non-optional on `PrepResults.WebCalls`, and Swift's
        // synthesized decoder requires every non-optional key regardless of its default. Omitting them
        // fails the WHOLE file, which is worth knowing: the first version of this fixture did, so
        // `answeredKeys` returned nothing, nothing was stamped, and the two tests asserting that nothing
        // is stamped passed for entirely the wrong reason while the positive control caught it.
        let web = finished
            ? #"{"recorded":true,"total":4,"items":1,"capPerItem":18,"allowance":18,"streams":1}"#
            : #"{"recorded":false,"items":1,"capPerItem":18,"allowance":18,"streams":2,"streamsReported":1}"#
        try #"""
        {"version":\#(PrepResultsDecoder.supportedVersion),"generatedAt":"now",
         "webCalls":\#(web),
         "results":[{"naturalKey":"\#(key)"\#(contacts)}]}
        """#.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // The defect exactly: a run that did not finish writes a firm negative and a 90 day lockout.
    @Test func aDeadRunsEmptyAnswerDoesNotLockTheShowOut() throws {
        let ctx = ModelContext(try container())
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = "kestrel-2027-04-18-rowan"
        let p = show(ctx, key)
        let url = try results(dir, key: key, finished: false)

        var saveFailed = false
        _ = PrepQueueService.markProbed(keys: [key], answeredIn: url, in: ctx, now: Date(),
                                        anIngestIsStillToCome: true, saveFailed: &saveFailed)

        #expect(p.reachabilityProbedAt == nil, "a run that did not finish started a 90 day lockout")
        #expect(p.reachabilityResult == nil, "and wrote a firm negative")
    }

    // And it comes back for another look, which is the half that makes the refusal useful rather than
    // merely harmless.
    @Test func theShowComesBackForAnotherLook() throws {
        let ctx = ModelContext(try container())
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = "kestrel-2027-04-18-rowan"
        let p = show(ctx, key)
        let url = try results(dir, key: key, finished: false)

        var saveFailed = false
        _ = PrepQueueService.markProbed(keys: [key], answeredIn: url, in: ctx, now: Date(),
                                        anIngestIsStillToCome: true, saveFailed: &saveFailed)

        #expect(Reachability.wasMissedByACheck(probedAt: p.reachabilityProbedAt,
                                               unansweredAt: p.reachabilityUnansweredAt, now: Date()),
                "the show is not offered another look")
    }

    // A run that DID finish is untouched, or the fix would be a reader that refuses every negative and
    // the two tests above would pass for the wrong reason (L159).
    @Test func aFinishedRunStillRecordsItsNegative() throws {
        let ctx = ModelContext(try container())
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = "kestrel-2027-04-18-rowan"
        let p = show(ctx, key)
        let url = try results(dir, key: key, finished: true)

        var saveFailed = false
        _ = PrepQueueService.markProbed(keys: [key], answeredIn: url, in: ctx, now: Date(),
                                        anIngestIsStillToCome: true, saveFailed: &saveFailed)

        #expect(p.reachabilityProbedAt != nil)
        #expect(p.reachabilityResult == .noEmailFound)
    }

    // A results file with NO webCalls block at all says nothing about whether the run finished, and an
    // absent statement must not read as a claim that it died: every file written before #1721 has none,
    // and treating those as dead runs would re-check the whole store (L11, L98).
    @Test func aFileThatSaysNothingAboutTheRunIsTrusted() throws {
        let ctx = ModelContext(try container())
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = "kestrel-2027-04-18-rowan"
        let p = show(ctx, key)
        let url = dir.appendingPathComponent("overture-check-results.json")
        try #"{"version":\#(PrepResultsDecoder.supportedVersion),"generatedAt":"now","results":[{"naturalKey":"\#(key)"}]}"#
            .write(to: url, atomically: true, encoding: .utf8)

        var saveFailed = false
        _ = PrepQueueService.markProbed(keys: [key], answeredIn: url, in: ctx, now: Date(),
                                        anIngestIsStillToCome: true, saveFailed: &saveFailed)

        #expect(p.reachabilityProbedAt != nil, "an absent statement was read as a claim the run died")
    }

    // A show the dead run answered WITH a contact keeps it. Re-checking that would spend money to
    // rediscover an address already on the row, and the contact is evidence the run did reach this show.
    @Test func aContactFoundByADeadRunIsKept() throws {
        let ctx = ModelContext(try container())
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = "kestrel-2027-04-18-rowan"
        let p = show(ctx, key)
        let url = try results(dir, key: key, finished: false,
                              contacts: #","contacts":[{"name":"Kestrel Quartet","email":"booking@kestrelquartet.example","method":"generic_inbox","confidence":"medium","provenance":"performer"}]"#)

        var saveFailed = false
        _ = PrepQueueService.markProbed(keys: [key], answeredIn: url, in: ctx, now: Date(),
                                        anIngestIsStillToCome: true, saveFailed: &saveFailed)

        #expect(p.reachabilityProbedAt != nil,
                "a show the run actually answered was thrown away with the ones it did not")
    }

    // The INGEST runs after markProbed and stamps `reachabilityProbedAt` unconditionally in its probe
    // branch, so fixing only markProbed would leave the lockout to be put straight back by the next step
    // in the same settle. Both writers have to agree, which is the whole reason this is asserted through
    // `ingest` rather than only through `markProbed` above.
    @Test func theIngestDoesNotPutTheLockoutBack() throws {
        let ctx = ModelContext(try container())
        let key = "kestrel-2027-04-18-rowan"
        let p = show(ctx, key)

        let dead = PrepResults.WebCalls(recorded: false, items: 1, capPerItem: 18, allowance: 18)
        _ = PrepImporter.ingest(PrepResults(version: 2, generatedAt: "now",
                                            results: [PrepResult(naturalKey: key, contacts: nil,
                                                                 emptyReason: "nothing_published")],
                                            webCalls: dead),
                                into: ctx, isProbe: true)

        #expect(p.reachabilityProbedAt == nil,
                "the ingest re-stamped a lockout markProbed had correctly withheld")
        #expect(p.reachabilityEmptyReason == nil,
                "and recorded a reason from a run that did not finish")
    }

    // A finished run still ingests exactly as before, so the guard above cannot pass by refusing every
    // empty answer (L159).
    @Test func aFinishedRunsIngestIsUnchanged() throws {
        let ctx = ModelContext(try container())
        let key = "kestrel-2027-04-18-rowan"
        let p = show(ctx, key)

        let whole = PrepResults.WebCalls(recorded: true, total: 4, items: 1, capPerItem: 18, allowance: 18)
        _ = PrepImporter.ingest(PrepResults(version: 2, generatedAt: "now",
                                            results: [PrepResult(naturalKey: key, contacts: nil,
                                                                 emptyReason: "nothing_published")],
                                            webCalls: whole),
                                into: ctx, isProbe: true)

        #expect(p.reachabilityProbedAt != nil)
        #expect(p.reachabilityEmptyReason == .nothingPublished)
    }
}
