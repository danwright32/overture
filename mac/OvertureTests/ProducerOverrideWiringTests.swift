import Testing
import Foundation
import SwiftData
@testable import Overture

// #1719: the wiring, which is the whole point of the issue and the thing #1679 records as missing.
//
// ProducerGate has accepted a hand-made override since #1593 and every consumer passed the default empty
// one, so the unit tests of the gate itself were green, correct, and protecting nothing that Dan could
// reach. A rule and its wiring are two separate claims (this repo's own #1598 guard says so), and only
// the second one is tested here: a correction STORED changes what a consumer DOES.
//
// Each test below stores a demotion and asserts the consumer's output changes. Written this way rather
// than by grepping for the parameter, because a call site can pass an override it computed wrongly and a
// source grep would call that wired.
@MainActor
@Suite("A stored producer correction actually reaches its consumers (#1719)")
struct ProducerOverrideWiringTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: AppSchema.schema,
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    // Two shows by one organisation at two of its own rooms. The gate reads this as a travelled producer
    // (the FRIGID shape), so both shows amortise onto ONE paid lookup until Dan says otherwise.
    private func seedHouse(_ ctx: ModelContext) {
        for (i, venue) in ["Under St Marks", "The Kraine Theater"].enumerated() {
            let p = Prospect(naturalKey: "frigid-\(i)", groupName: "Show \(i)", discipline: "theater",
                             venue: venue, performanceDate: "2026-09-1\(i)",
                             sourceListingURL: nil, websiteURL: nil,
                             priorRelationship: "none", production: "self", profile: "strong",
                             coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                             matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
            p.presenter = "FRIGID New York"
            ctx.insert(p)
        }
        try? ctx.save()
    }

    // The money path. buildProbeQueue is what decides how many lookups Dan is charged for, so a
    // correction that fails to reach it costs him real money on every run, silently.
    @Test func theProbeQueueBuilderAppliesAStoredDemotion() throws {
        let ctx = ModelContext(try container())
        seedHouse(ctx)
        let keys: Set<String> = ["frigid-0", "frigid-1"]

        // Amortised: one organisation, one lookup, the second show riding on it.
        let before = PrepQueueService.buildProbeQueue(from: ctx, generatedAt: "2026-07-29", keys: keys)
        #expect(before.items.count == 1)

        ProducerOverrideEditing.demote("FRIGID New York", into: ctx)

        // A house answers for nothing but itself, so each show is now its own lookup.
        let after = PrepQueueService.buildProbeQueue(from: ctx, generatedAt: "2026-07-29", keys: keys)
        #expect(after.items.count == 2)
    }

    // The queue's own rows. An inherited answer is the one that shows a contact Dan never paid for on
    // THIS show, so a demotion that failed to reach the ledger would keep stamping a house's address
    // across its tenants' shows with nothing on the card to reveal it.
    @Test func inheritedAnswersRespectAStoredDemotion() throws {
        let ctx = ModelContext(try container())
        seedHouse(ctx)
        let all = (try? ctx.fetch(FetchDescriptor<Prospect>())) ?? []
        // One show has its own paid answer; the other is the one that would inherit it.
        let answered = all.first { $0.naturalKey == "frigid-0" }
        answered?.reachabilityProbedAt = Date()
        let answer = OrgReachabilityAnswer(
            orgKey: OrgKey.stored(for: "FRIGID New York")!, result: .emailFound, probedAt: Date(),
            sourceNaturalKey: "frigid-0", sourceGroupName: "Show 0", presenterName: "FRIGID New York",
            foundEmails: ["info@frigid.nyc"])
        ctx.insert(answer)
        try? ctx.save()

        let inheritedBefore = QueueModel.items(from: all, answers: [answer], corpus: all)
            .first { $0.id == "frigid-1" }?.inheritedReachability
        #expect(inheritedBefore != nil)

        let inheritedAfter = QueueModel.items(
            from: all, answers: [answer], corpus: all,
            overrides: ProducerOverrideEditing.overrides(in: demoted(ctx)))
            .first { $0.id == "frigid-1" }?.inheritedReachability
        #expect(inheritedAfter == nil)
    }

    private func demoted(_ ctx: ModelContext) -> ModelContext {
        ProducerOverrideEditing.demote("FRIGID New York", into: ctx)
        return ctx
    }

    // The two background consumers cannot be driven end to end from a test (ScoutService's sweep needs a
    // whole fetched feed, PossibleMatchRecheck a loaded booking history), so they are pinned at the seam
    // instead: each must READ the overrides where it reads its corpus. This is deliberately the weaker
    // claim of the two kinds in this file, and it is named as such rather than dressed up as behaviour.
    @Test func theBackgroundConsumersReadTheOverridesToo() {
        let scout = SourceGuardHelper.source("Overture/Integration/ScoutService.swift")
        let recheck = SourceGuardHelper.source("Overture/Domain/PossibleMatchRecheck.swift")
        #expect(scout.contains("overrides: ProducerOverrideEditing.overrides(in: context)"))
        #expect(recheck.contains("overrides: ProducerOverrideEditing.overrides(in: context)"))
    }
}
