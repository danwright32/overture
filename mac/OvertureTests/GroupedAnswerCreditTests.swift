import Testing
import Foundation
import SwiftData

// #1804: a check pays for ONE lookup when several shows share a producer, and the runbook tells the run to
// write a result entry for the item's own key AND for every key in its `alsoAnswersFor`. Nothing enforced
// that. A run that wrote one entry for a group of eight left the other seven unstamped (so they were
// selected and paid for again), never receiving the contact the lookup found, and counted as unanswered in
// the shortfall sentence Dan reads, which would tell him seven shows went unanswered when the lookup that
// covers them came home fine. L27: a rule that lives only in a prompt is a hope.
//
// The app knows the grouping, because it wrote it. So it credits the group itself rather than depending on
// the run to restate it, and a compliant run and a terse one settle identically.
//
// Dan's scope call, 2026-07-31: a covered show inherits the CONTACTS found for its group and never the
// "we looked and found nobody" verdict. The grouping rule (ProducerGate) has been wrong before (it swept in
// Carnegie Hall Presents until #1620), and the asymmetry is deliberate: a wrong group that hands a contact
// to seven shows is corrected by the next check, whereas one that marks seven shows unreachable locks them
// out of a re-check for 90 days.
@MainActor
@Suite("Grouped answer credit (#1804)")
struct GroupedAnswerCreditTests {

    private let lead = "aurora strings|2026-09-12|weill recital hall"
    private let covered1 = "boreal brass|2026-09-13|weill recital hall"
    private let covered2 = "cedar quartet|2026-09-14|zankel hall"

    private func jane() -> PrepContact {
        PrepContact(name: "Jane", role: "Producer", email: "jane@aurora.org",
                    method: "named_decision_maker", confidence: "high", formUrl: nil, provenance: "presenter")
    }

    private func groupOfThree() -> [String: [String]] { [lead: [covered1, covered2]] }

    // MARK: the rule itself

    @Test func aCoveredShowInheritsTheLeadsContacts() {
        let credited = PrepGroupCredit.credited([PrepResult(naturalKey: lead, contacts: [jane()])],
                                                groups: groupOfThree())

        #expect(Set(credited.map(\.naturalKey)) == [lead, covered1, covered2])
        let inherited = credited.first { $0.naturalKey == covered1 }
        #expect(inherited?.contacts == [jane()])
    }

    // Dan's call, 2026-07-31, and the reason the credit is deliberately one-directional: an answer of
    // "there is nobody" is the one a wrong grouping would be most expensive to spread, because a stamp
    // locks a show out of a re-check for 90 days. A group lead that found nothing credits nothing, so its
    // covered shows stay unchecked and are simply offered again.
    @Test func aFoundNobodyVerdictIsNeverInherited() {
        let credited = PrepGroupCredit.credited([PrepResult(naturalKey: lead, contacts: [])],
                                                groups: groupOfThree())

        #expect(credited.map(\.naturalKey) == [lead])
    }

    // The failure path this whole rule could otherwise swallow. The lead is the show that was actually
    // researched, so a results file missing it is a run that never reached the group at all. Crediting
    // anything here would report work that never happened as done, and stamp shows nobody looked at.
    @Test func aGroupWhoseLeadNeverCameBackCreditsNothing() {
        let credited = PrepGroupCredit.credited([PrepResult(naturalKey: "unrelated|2026-09-12|elsewhere",
                                                            contacts: [jane()])],
                                                groups: groupOfThree())

        #expect(credited.map(\.naturalKey) == ["unrelated|2026-09-12|elsewhere"])
    }

    // A draft names one show, its date and its material. Copying it onto a sibling would put another
    // show's pitch in front of Dan under this show's name. Only a check ever carries a grouping today, and
    // a check never drafts, so this is the belt to that braces.
    @Test func aDraftIsNeverCarriedOntoACoveredShow() {
        let credited = PrepGroupCredit.credited(
            [PrepResult(naturalKey: lead, contacts: [jane()],
                        draft: PrepDraft(subject: "s", body: "b", variant: "direct-intent"))],
            groups: groupOfThree())

        #expect(credited.first { $0.naturalKey == covered1 }?.draft == nil)
        #expect(credited.first { $0.naturalKey == lead }?.draft != nil)   // the lead keeps its own
    }

    // A run that DID follow the runbook researched this show specifically, so its own entry is better
    // evidence than the lead's and must not be overwritten by the credit.
    @Test func aCoveredShowsOwnEntryWinsOverTheLeads() {
        let own = PrepContact(name: "Sam", role: "GM", email: "sam@boreal.org",
                              method: "named_decision_maker", confidence: "high", formUrl: nil,
                              provenance: "presenter")
        let credited = PrepGroupCredit.credited([PrepResult(naturalKey: lead, contacts: [jane()]),
                                                 PrepResult(naturalKey: covered1, contacts: [own])],
                                                groups: groupOfThree())

        #expect(credited.first { $0.naturalKey == covered1 }?.contacts == [own])
        #expect(credited.count == 3)
    }

    // MARK: reading the grouping off the queue

    private func dir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func writeQueue(_ url: URL, generatedAt: String, group: [String]) throws {
        let item = PrepQueueItem(naturalKey: lead, groupName: "Aurora Strings", venue: "Weill Recital Hall",
                                 performanceDate: "2026-09-12", discipline: "music", websiteURL: nil,
                                 sourceListingURL: nil, possibleMatchName: nil, priorRelationship: "none",
                                 production: "unknown", reprepMode: "contacts_only",
                                 alsoAnswersFor: group.isEmpty ? nil : group)
        let queue = PrepQueueBuilder.build(from: [item], generatedAt: generatedAt, houses: [])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PrepQueueBuilder.encode(queue).write(to: url)
    }

    private func writeResults(_ url: URL, _ results: [PrepResult]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(PrepResults(version: 7, generatedAt: "now", results: results)).write(to: url)
    }

    @Test func readsTheGroupingOffTheQueueTheAppWrote() throws {
        let d = dir()
        let queueURL = d.appendingPathComponent("queue.json")
        let resultsURL = d.appendingPathComponent("results.json")
        try writeQueue(queueURL, generatedAt: "2026-07-31T10:00:00Z", group: [covered1, covered2])
        try writeResults(resultsURL, [PrepResult(naturalKey: lead, contacts: [jane()])])

        #expect(PrepGroupCredit.groups(queueURL: queueURL, resultsURL: resultsURL) == groupOfThree())
    }

    // startPrep writes a fresh queue but leaves the PREVIOUS run's results file on disk, so a results file
    // that predates its queue is not an answer to it (HandoffShortfall's rule, reused rather than restated).
    // Crediting across that pairing would fan one producer's contact onto an unrelated producer's shows.
    @Test func resultsThatPredateTheQueueCreditNothing() throws {
        let d = dir()
        let queueURL = d.appendingPathComponent("queue.json")
        let resultsURL = d.appendingPathComponent("results.json")
        try writeResults(resultsURL, [PrepResult(naturalKey: lead, contacts: [jane()])])
        // The queue is generated a day AFTER the results file was last written.
        let tomorrow = ISO8601DateFormatter().string(from: Date().addingTimeInterval(86_400))
        try writeQueue(queueURL, generatedAt: tomorrow, group: [covered1, covered2])

        #expect(PrepGroupCredit.groups(queueURL: queueURL, resultsURL: resultsURL).isEmpty)
    }

    @Test func anUnreadableQueueCreditsNothing() throws {
        let d = dir()
        let queueURL = d.appendingPathComponent("queue.json")
        let resultsURL = d.appendingPathComponent("results.json")
        try writeResults(resultsURL, [PrepResult(naturalKey: lead, contacts: [jane()])])

        #expect(PrepGroupCredit.groups(queueURL: queueURL, resultsURL: resultsURL).isEmpty)
    }

    // MARK: through the real settle path

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    @discardableResult
    private func insert(_ ctx: ModelContext, key: String, group: String, venue: String, date: String) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: group, discipline: "music", venue: venue,
                         performanceDate: date, sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil, status: .new)
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    private func insertGroupOfThree(_ ctx: ModelContext) {
        insert(ctx, key: lead, group: "Aurora Strings", venue: "Weill Recital Hall", date: "2026-09-12")
        insert(ctx, key: covered1, group: "Boreal Brass", venue: "Weill Recital Hall", date: "2026-09-13")
        insert(ctx, key: covered2, group: "Cedar Quartet", venue: "Zankel Hall", date: "2026-09-14")
    }

    private func fetch(_ ctx: ModelContext, _ key: String) throws -> Prospect? {
        try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })).first
    }

    // A per-test defaults suite, so the consumed-results fingerprint one test writes can never make the
    // next test's ingest skip (L2: a test must be structurally unable to touch shared state).
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "grouped-credit-\(UUID().uuidString)")!
    }

    // The whole issue, end to end: one paid lookup, eight shows in the real case, three here. Every show
    // Dan paid for gets the contact, gets stamped so it is not selected and paid for again, and the run
    // reports itself complete rather than claiming two shows went unanswered.
    @Test func aGroupedCheckSettlesEveryShowItPaidFor() throws {
        let ctx = ModelContext(try container())
        insertGroupOfThree(ctx)
        let d = dir()
        let markerURL = d.appendingPathComponent("probe-run.json")
        let queueURL = d.appendingPathComponent("queue.json")
        let resultsURL = d.appendingPathComponent("results.json")
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        try ReachabilityProbeMarker.write(
            ReachabilityProbeMarker(keys: [lead, covered1, covered2], startedAt: "s"), to: markerURL)
        try writeQueue(queueURL, generatedAt: "2026-07-31T10:00:00Z", group: [covered1, covered2])
        // The terse run: ONE entry for a group of three.
        try writeResults(resultsURL, [PrepResult(naturalKey: lead, contacts: [jane()])])

        let report = PrepQueueService.settleReachabilityProbe(slot: .check, 
            markerURL: markerURL, resultsURL: resultsURL, queueURL: queueURL,
            into: ctx, now: now, defaults: freshDefaults())

        #expect(report?.requested == 3)
        #expect(report?.answered == 3)   // not 1: nothing went unanswered
        for key in [lead, covered1, covered2] {
            let p = try fetch(ctx, key)
            #expect(p?.reachabilityProbedAt == now, "\(key) should be stamped, not paid for again")
            #expect(p?.recipients.first?.email == "jane@aurora.org", "\(key) should carry the paid-for contact")
            #expect(p?.status == .new, "a check never drafts")
        }
    }

    // The honest half, through the same path. A run that died before reaching the group researched nothing,
    // so all three shows stay unchecked and the shortfall says so. If this ever goes green while the test
    // above does too by a route other than the lead, the credit rule has started papering over real misses.
    @Test func aGroupWhoseLeadNeverCameBackLeavesEveryShowUnchecked() throws {
        let ctx = ModelContext(try container())
        insertGroupOfThree(ctx)
        let d = dir()
        let markerURL = d.appendingPathComponent("probe-run.json")
        let queueURL = d.appendingPathComponent("queue.json")
        let resultsURL = d.appendingPathComponent("results.json")
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        try ReachabilityProbeMarker.write(
            ReachabilityProbeMarker(keys: [lead, covered1, covered2], startedAt: "s"), to: markerURL)
        try writeQueue(queueURL, generatedAt: "2026-07-31T10:00:00Z", group: [covered1, covered2])
        try writeResults(resultsURL, [])

        let report = PrepQueueService.settleReachabilityProbe(slot: .check, 
            markerURL: markerURL, resultsURL: resultsURL, queueURL: queueURL,
            into: ctx, now: now, defaults: freshDefaults())

        #expect(report?.answered == 0)
        for key in [lead, covered1, covered2] {
            #expect(try fetch(ctx, key)?.reachabilityProbedAt == nil, "\(key) was never researched")
        }
    }
}
