import Testing
import Foundation
import SwiftData

// #1724, the half #1769 did not cover.
//
// A check runs as up to ten concurrent claudes over a work-list the app wrote. A chunk that dies partway
// leaves the shows it never reached with no answer, and #1594 is deliberate about what happens then: those
// shows are NOT stamped, because stamping them would put "No email found" on a show nobody looked at and
// lock it out of a re-check for 90 days.
//
// The consequence nobody closed is that they are then stored as literally nothing. `reachabilityProbedAt`
// stays nil, which is the one thing `hasFreshReachabilityAnswer` reads, so a show a check was paid for and
// missed is indistinguishable from a show no check has ever been near. It is offered again, paid for
// again, and nothing anywhere says it already failed once. Measured on the live store 2026-07-29: a run
// asked for 5 shows and answered 1, and the other 4 went back into the pool unmarked.
//
// This is LESSONS L47, which was written from this very issue: a batch that partly fails must record the
// attempt on the items it failed, not only on the ones it completed.
//
// What this suite deliberately does NOT assert, because #1594 owns it: the missed show stays unchecked,
// stays a candidate, and is never refused (L54). The record is something Dan reads, not a gate.
@MainActor
@Suite("A check that missed a show (#1724)")
struct CheckMissedAShowTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, OrgReachabilityAnswer.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func newProspect(_ ctx: ModelContext, group: String) -> String {
        let key = Prospect.makeNaturalKey(groupName: group, performanceDate: "2026-09-12", venue: "Weill Recital Hall")
        let p = Prospect(naturalKey: key, groupName: group, discipline: "music", venue: "Weill Recital Hall",
                         performanceDate: "2026-09-12", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .new)
        ctx.insert(p)
        try? ctx.save()
        return key
    }

    private func fetch(_ ctx: ModelContext, _ key: String) throws -> Prospect? {
        try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })).first
    }

    private func dir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func writeResults(_ url: URL, _ results: PrepResults) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(results).write(to: url)
    }

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "missed-\(UUID().uuidString)")!
    }

    private func answer(_ key: String) -> PrepResult {
        PrepResult(naturalKey: key,
                   contacts: [PrepContact(name: "Jane", role: "Mgr", email: "jane@aurora.org",
                                          method: "named_decision_maker", confidence: "high",
                                          formUrl: nil, provenance: "act")],
                   draft: nil)
    }

    // THE CORE. Two shows go into one check and one answer comes back. The show the run never reached
    // carries a record that a check missed it, and is still, by every other measure, unchecked.
    @Test func aShowTheCheckNeverReachedIsRecordedAsMissed() throws {
        let ctx = ModelContext(try container())
        let a = newProspect(ctx, group: "Aurora Strings")
        let b = newProspect(ctx, group: "Boreal Brass")
        let d = dir()
        let markerURL = d.appendingPathComponent("probe-run.json")
        let resultsURL = d.appendingPathComponent("results.json")
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        try ReachabilityProbeMarker.write(ReachabilityProbeMarker(keys: [a, b], startedAt: "s"), to: markerURL)
        try writeResults(resultsURL, PrepResults(version: 2, generatedAt: "now", results: [answer(a)]))

        _ = PrepQueueService.settleReachabilityProbe(slot: .check, markerURL: markerURL, resultsURL: resultsURL,
                                                     into: ctx, now: now, defaults: freshDefaults())

        let pb = try fetch(ctx, b)
        #expect(pb?.reachabilityUnansweredAt == now,
                "the show the run never reached must record that a check missed it")
        // #1594 stays exactly as it was: no stamp, no verdict, so the badge does not claim an answer and
        // the 90-day lockout is not reintroduced through the back door.
        #expect(pb?.reachabilityProbedAt == nil)
        #expect(pb?.reachabilityResult == nil)
        // And the show that WAS answered carries no such record.
        #expect(try fetch(ctx, a)?.reachabilityUnansweredAt == nil)
    }

    // The mark is not a refusal. Dan can still select this show and pay for it again, which is the whole
    // point: the check is the only way it will ever get an answer (L54).
    @Test func aMissedShowIsStillOfferedForAnotherCheck() throws {
        let ctx = ModelContext(try container())
        let b = newProspect(ctx, group: "Boreal Brass")
        let d = dir()
        let markerURL = d.appendingPathComponent("probe-run.json")
        let resultsURL = d.appendingPathComponent("results.json")
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        try ReachabilityProbeMarker.write(ReachabilityProbeMarker(keys: [b], startedAt: "s"), to: markerURL)
        try writeResults(resultsURL, PrepResults(version: 2, generatedAt: "now", results: []))

        _ = PrepQueueService.settleReachabilityProbe(slot: .check, markerURL: markerURL, resultsURL: resultsURL,
                                                     into: ctx, now: now, defaults: freshDefaults())

        let item = QueueItem(try #require(try fetch(ctx, b)))
        #expect(item.reachabilityUnansweredAt == now)
        #expect(QueueModel.reachabilityProbeCandidateKeys([item], now: now, today: "2026-09-01").contains(b),
                "a missed show must stay selectable; the record informs Dan, it does not gate him")
    }

    // A later check that answers the show clears the record. Nothing carries a permanent scar, and a card
    // can never show an answer and "a check missed this" at the same time.
    @Test func ananswerClearsTheRecord() throws {
        let ctx = ModelContext(try container())
        let b = newProspect(ctx, group: "Boreal Brass")
        let d = dir()
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let later = now.addingTimeInterval(3600)

        let firstMarker = d.appendingPathComponent("probe-run-1.json")
        let firstResults = d.appendingPathComponent("results-1.json")
        try ReachabilityProbeMarker.write(ReachabilityProbeMarker(keys: [b], startedAt: "s1"), to: firstMarker)
        try writeResults(firstResults, PrepResults(version: 2, generatedAt: "now", results: []))
        _ = PrepQueueService.settleReachabilityProbe(slot: .check, markerURL: firstMarker, resultsURL: firstResults,
                                                     into: ctx, now: now, defaults: freshDefaults())
        #expect(try fetch(ctx, b)?.reachabilityUnansweredAt == now, "precondition: the first check missed it")

        let secondMarker = d.appendingPathComponent("probe-run-2.json")
        let secondResults = d.appendingPathComponent("results-2.json")
        try ReachabilityProbeMarker.write(ReachabilityProbeMarker(keys: [b], startedAt: "s2"), to: secondMarker)
        try writeResults(secondResults, PrepResults(version: 2, generatedAt: "now", results: [answer(b)]))
        _ = PrepQueueService.settleReachabilityProbe(slot: .check, markerURL: secondMarker, resultsURL: secondResults,
                                                     into: ctx, now: later, defaults: freshDefaults())

        let pb = try fetch(ctx, b)
        #expect(pb?.reachabilityUnansweredAt == nil, "an answer supersedes the record of a check that missed it")
        #expect(pb?.reachabilityProbedAt == later)
    }

    // THE FAILURE PATH THIS FEATURE LIVES ON. #1677: a settle whose save did not commit keeps its marker
    // and settles AGAIN on a later launch. By then `PrepImporter.consumeIfNew` refuses the results file it
    // has already read, so there is no ingest Outcome at all and `markProbed` is the only writer that runs.
    // If the record were written anywhere but there, a re-settle would silently drop it and the show would
    // go back into the pool unmarked, which is the exact defect this issue is about.
    @Test func aReSettleOfAnAlreadyConsumedRunStillRecordsTheMiss() throws {
        let ctx = ModelContext(try container())
        let a = newProspect(ctx, group: "Aurora Strings")
        let b = newProspect(ctx, group: "Boreal Brass")
        let d = dir()
        let markerURL = d.appendingPathComponent("probe-run.json")
        let resultsURL = d.appendingPathComponent("results.json")
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let defaults = freshDefaults()      // SHARED, so the second settle sees the file as consumed
        try writeResults(resultsURL, PrepResults(version: 2, generatedAt: "now", results: [answer(a)]))

        try ReachabilityProbeMarker.write(ReachabilityProbeMarker(keys: [a, b], startedAt: "s"), to: markerURL)
        _ = PrepQueueService.settleReachabilityProbe(slot: .check, markerURL: markerURL, resultsURL: resultsURL,
                                                     into: ctx, now: now, defaults: defaults)
        // Wipe the record, so the re-settle below has to write it itself rather than inheriting it.
        try fetch(ctx, b)?.reachabilityUnansweredAt = nil
        try ctx.save()

        let again = now.addingTimeInterval(7200)
        try ReachabilityProbeMarker.write(ReachabilityProbeMarker(keys: [a, b], startedAt: "s"), to: markerURL)
        let report = PrepQueueService.settleReachabilityProbe(slot: .check, markerURL: markerURL, resultsURL: resultsURL,
                                                             into: ctx, now: again, defaults: defaults)

        #expect(report?.outcome == nil, "precondition: the results file was already consumed, so no ingest ran")
        #expect(try fetch(ctx, b)?.reachabilityUnansweredAt == again,
                "the only writer that runs on a re-settle must still record the miss")
    }

    // The sentence Dan reads and the rows he can act on come from ONE set. The shortfall says "1 of 2
    // shows never got an answer"; exactly one show must carry the record. Two counts derived separately
    // are how a number stops being a promise about rows (L16).
    @Test func theRecordAndTheShortfallSentenceDescribeTheSameShows() throws {
        let ctx = ModelContext(try container())
        let a = newProspect(ctx, group: "Aurora Strings")
        let b = newProspect(ctx, group: "Boreal Brass")
        let c = newProspect(ctx, group: "Cobalt Consort")
        let d = dir()
        let markerURL = d.appendingPathComponent("probe-run.json")
        let resultsURL = d.appendingPathComponent("results.json")
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        try ReachabilityProbeMarker.write(ReachabilityProbeMarker(keys: [a, b, c], startedAt: "s"), to: markerURL)
        try writeResults(resultsURL, PrepResults(version: 2, generatedAt: "now", results: [answer(a)]))

        let report = PrepQueueService.settleReachabilityProbe(slot: .check, markerURL: markerURL, resultsURL: resultsURL,
                                                             into: ctx, now: now, defaults: freshDefaults())

        let marked = try ctx.fetch(FetchDescriptor<Prospect>()).filter { $0.reachabilityUnansweredAt != nil }
        #expect(report?.unanswered == 2)
        #expect(marked.count == report?.unanswered)
        #expect(Set(marked.map(\.naturalKey)) == Set([b, c]))
    }

    // The row says it. Before this the card was silent, which is what made a missed show and a never
    // checked one look identical to the person paying for both.
    @Test func theRowSaysACheckMissedIt() throws {
        let ctx = ModelContext(try container())
        let b = newProspect(ctx, group: "Boreal Brass")
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let p = try #require(try fetch(ctx, b))
        #expect(QueueItem(p).reachabilityBadge(now: now) == Reachability.Badge.none,
                "precondition: nothing to say about a show no check has been near")

        p.reachabilityUnansweredAt = now
        #expect(QueueItem(p).reachabilityBadge(now: now) == .checkMissedIt)
    }

    // A real answer outranks the record, whichever way round they arrive. Belt and braces beside the
    // clearing above: the badge must never depend on a write having happened in the right order.
    @Test func ananswerOutranksTheRecordOnTheRow() throws {
        let ctx = ModelContext(try container())
        let b = newProspect(ctx, group: "Boreal Brass")
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let p = try #require(try fetch(ctx, b))
        p.reachabilityUnansweredAt = now
        p.reachabilityProbedAt = now
        p.reachabilityResult = .noEmailFound
        #expect(QueueItem(p).reachabilityBadge(now: now) == .noEmailFound)
    }

    // EDGE CASE. A check that missed a show six months ago says nothing useful about today, so the record
    // goes quiet on the same 90-day window a real answer does. Otherwise the mark accumulates on rows
    // forever and stops meaning anything, which is L36's cry-wolf shape one surface along.
    @Test func aLongExpiredRecordGoesQuiet() throws {
        let ctx = ModelContext(try container())
        let b = newProspect(ctx, group: "Boreal Brass")
        let missedAt = Date(timeIntervalSince1970: 1_780_000_000)
        let p = try #require(try fetch(ctx, b))
        p.reachabilityUnansweredAt = missedAt
        let wayLater = missedAt.addingTimeInterval(Reachability.probeFreshness + 86_400)
        #expect(QueueItem(p).reachabilityBadge(now: wayLater) == Reachability.Badge.none)
    }

    // The confirm sheet is where money is committed, so it is where the count has to appear. Dan's call,
    // 2026-07-31: the sheet says how many, the rows say which.
    @Test func theConfirmSheetSaysHowManyAreBeingPaidForASecondTime() {
        let shows = (0..<3).map { ProbeBatch.Show(key: "k\($0)", presenter: "Solo \($0)", venue: "Room \($0)") }
        let s = ProbeSelection.summarize(dateCount: 1, candidates: shows, alreadyAnswered: 0,
                                         previouslyMissed: 2, among: shows)
        #expect(s.previouslyMissedCount == 2)
        let message = ProbeSelectionCopy.multiDateMessage(s)
        #expect(message.contains("2 of them"))
        // The run's own shortfall phrase, so the sheet and the report describe one event one way.
        #expect(message.contains("never got an answer"))

        // And a selection nothing has missed says nothing about it, rather than "0 of them".
        let clean = ProbeSelection.summarize(dateCount: 1, candidates: shows, alreadyAnswered: 0,
                                             previouslyMissed: 0, among: shows)
        #expect(!ProbeSelectionCopy.multiDateMessage(clean).contains("earlier check"))
    }
}
