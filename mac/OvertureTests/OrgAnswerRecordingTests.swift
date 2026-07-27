import Testing
import Foundation
import SwiftData
@testable import Overture

// #1598 (milestone 32 Phase 5): the ONE moment an organisation's answer is written down, when a check
// settles. Everything about reuse depends on this record being honest about what was actually learned,
// so the failure paths are pinned at least as hard as the happy one.
@MainActor
@Suite("Recording an organisation's reachability answer (#1598)")
struct OrgAnswerRecordingTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, OrgReachabilityAnswer.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "org-answer-\(UUID().uuidString)")!
    }

    @discardableResult
    private func makeShow(_ ctx: ModelContext, group: String, presenter: String?,
                          venue: String = "Church of the Ascension") -> Prospect {
        let key = Prospect.makeNaturalKey(groupName: group, performanceDate: "2026-09-12", venue: venue)
        let p = Prospect(naturalKey: key, groupName: group, discipline: "music", venue: venue,
                         performanceDate: "2026-09-12", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .new)
        p.presenter = presenter
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    private func contact(_ email: String, venueLooking: Bool = false) -> Recipient {
        let r = Recipient(id: Recipient.makeId(email: email, formURL: nil) ?? email, email: email,
                          name: "Someone", provenance: .presenter)
        r.looksLikeVenue = venueLooking
        return r
    }

    private func answers(_ ctx: ModelContext) throws -> [OrgReachabilityAnswer] {
        try ctx.fetch(FetchDescriptor<OrgReachabilityAnswer>())
    }

    @Test func aCheckThatFoundAContactRecordsItAgainstTheOrganisation() throws {
        let ctx = ModelContext(try container())
        let p = makeShow(ctx, group: "Monteverdi's Orfeo", presenter: "Tenet Vocal Artists")
        p.setRecipients([contact("hello@tenet.example")])
        try ctx.save()

        OrgAnswerRecording.record(answeredKeys: [p.naturalKey], in: ctx, now: now)

        let stored = try #require(try answers(ctx).first)
        #expect(stored.orgKey == OrgKey.stored(for: "Tenet Vocal Artists"))
        #expect(stored.result == .emailFound)
        #expect(stored.probedAt == now)
        #expect(stored.foundEmails == ["hello@tenet.example"])
        // Auditable: which show was actually paid for.
        #expect(stored.sourceNaturalKey == p.naturalKey)
        #expect(stored.sourceGroupName == "Monteverdi's Orfeo")
    }

    // A check that looked and found nobody is a real answer worth recording, and it is recorded. It
    // simply never travels (OrgAnswerLedgerTests). Keeping it is what makes the ledger a record of what
    // Dan spent rather than only of what succeeded.
    @Test func aCheckThatFoundNothingIsRecordedAsSuch() throws {
        let ctx = ModelContext(try container())
        let p = makeShow(ctx, group: "Light as Air", presenter: "Tenet Vocal Artists")

        OrgAnswerRecording.record(answeredKeys: [p.naturalKey], in: ctx, now: now)

        let stored = try #require(try answers(ctx).first)
        #expect(stored.result == .noEmailFound)
        #expect(stored.foundEmails.isEmpty)
    }

    // #1324: an address held by the venue or press guard is a fact about the room this one show played.
    // It must never be carried to the organisation's show at another venue, so it is recorded as the
    // weak result it is and no address rides along.
    @Test func aVenueFrontDeskIsRecordedWeakAndCarriesNoAddress() throws {
        let ctx = ModelContext(try container())
        let p = makeShow(ctx, group: "Here Let Me Forever Dwell", presenter: "Tenet Vocal Artists")
        p.setRecipients([contact("frontdesk@thechurch.example", venueLooking: true)])
        try ctx.save()

        OrgAnswerRecording.record(answeredKeys: [p.naturalKey], in: ctx, now: now)

        let stored = try #require(try answers(ctx).first)
        #expect(stored.result == .weakContactOnly)
        #expect(stored.foundEmails.isEmpty)
    }

    // #1594's rule, carried into the ledger: a show the run never reached has no answer, so it must not
    // produce one here either. This is the failure that would be worst, because a fabricated "no email"
    // for a whole organisation is invisible and lasts 90 days.
    @Test func aShowTheRunNeverAnsweredRecordsNothing() throws {
        let ctx = ModelContext(try container())
        let answered = makeShow(ctx, group: "Light as Air", presenter: "Tenet Vocal Artists")
        makeShow(ctx, group: "Never Reached", presenter: "Heartbeat Opera")

        OrgAnswerRecording.record(answeredKeys: [answered.naturalKey], in: ctx, now: now)

        #expect(try answers(ctx).count == 1)
        #expect(try answers(ctx).first?.presenterName == "Tenet Vocal Artists")
    }

    @Test func aShowWithNoPresenterRecordsNothing() throws {
        let ctx = ModelContext(try container())
        let p = makeShow(ctx, group: "Anonymous Night", presenter: nil)

        OrgAnswerRecording.record(answeredKeys: [p.naturalKey], in: ctx, now: now)

        #expect(try answers(ctx).isEmpty)
    }

    @Test func asecondCheckOfTheSameOrganisationUpdatesTheOneRow() throws {
        let ctx = ModelContext(try container())
        let first = makeShow(ctx, group: "Light as Air", presenter: "Tenet Vocal Artists")
        OrgAnswerRecording.record(answeredKeys: [first.naturalKey], in: ctx, now: now)

        let second = makeShow(ctx, group: "Auld Acquaintances", presenter: "Tenet Vocal Artists",
                              venue: "House of the Redeemer")
        second.setRecipients([contact("hello@tenet.example")])
        try ctx.save()
        let later = now.addingTimeInterval(86_400)
        OrgAnswerRecording.record(answeredKeys: [second.naturalKey], in: ctx, now: later)

        #expect(try answers(ctx).count == 1)
        let stored = try #require(try answers(ctx).first)
        #expect(stored.result == .emailFound)
        #expect(stored.probedAt == later)
    }

    // A results file consumed twice, or a run re-settled after a relaunch, must never walk a fresher
    // answer backwards to what an older check concluded.
    @Test func anOlderSettlementNeverOverwritesANewerAnswer() throws {
        let ctx = ModelContext(try container())
        let good = makeShow(ctx, group: "Auld Acquaintances", presenter: "Tenet Vocal Artists")
        good.setRecipients([contact("hello@tenet.example")])
        try ctx.save()
        OrgAnswerRecording.record(answeredKeys: [good.naturalKey], in: ctx, now: now)

        let stale = makeShow(ctx, group: "Light as Air", presenter: "Tenet Vocal Artists",
                             venue: "House of the Redeemer")
        OrgAnswerRecording.record(answeredKeys: [stale.naturalKey], in: ctx,
                                  now: now.addingTimeInterval(-86_400))

        let stored = try #require(try answers(ctx).first)
        #expect(stored.result == .emailFound)
        #expect(stored.probedAt == now)
    }

    // The whole point of the phase, end to end: a real settlement writes the ledger, so a sibling show
    // by the same organisation can be told apart from one nobody has ever looked at.
    @Test func settlingARealProbeWritesTheLedger() throws {
        let ctx = ModelContext(try container())
        let p = makeShow(ctx, group: "Monteverdi's Orfeo", presenter: "Tenet Vocal Artists")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let markerURL = dir.appendingPathComponent("probe-run.json")
        let resultsURL = dir.appendingPathComponent("results.json")
        try ReachabilityProbeMarker.write(
            ReachabilityProbeMarker(keys: [p.naturalKey], startedAt: "s"), to: markerURL)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: p.naturalKey,
                       contacts: [PrepContact(name: "Jane", role: "Mgr", email: "jane@tenet.example",
                                              method: "named_decision_maker", confidence: "high",
                                              formUrl: nil, provenance: "act")], draft: nil)
        ])).write(to: resultsURL)

        _ = PrepQueueService.settleReachabilityProbe(markerURL: markerURL, resultsURL: resultsURL,
                                                     into: ctx, now: now, defaults: freshDefaults())

        let stored = try #require(try answers(ctx).first)
        #expect(stored.result == .emailFound)
        #expect(stored.foundEmails == ["jane@tenet.example"])
    }
}
