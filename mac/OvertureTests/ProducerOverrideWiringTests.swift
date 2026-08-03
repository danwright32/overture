import Testing
import Foundation
import SwiftData

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

    // LIVE-STORE-CLAIM verified=2026-07-29 measure="FRIGID New York's presenter, venue and distinct venue count over all 702 prospects"
    // The store's real shape, two of its 41 rows: one organisation, several different companies' shows,
    // ALL in the single room it rents out, "Under St Marks". Deliberately not a second invented venue.
    // On this shape the venue-count arm already refuses FRIGID, so PROMOTION is the direction that
    // changes what the consumers do, and it is what these tests drive. Demotion's own consumer is the
    // shared venue-brand verdict, covered by theDemotionDirectionReachesTheQueuesRows below.
    private func seedRentedRoom(_ ctx: ModelContext) {
        for i in 0...1 {
            let p = Prospect(naturalKey: "frigid-\(i)", groupName: "Show \(i)", discipline: "theater",
                             venue: "Under St Marks", performanceDate: "2026-09-1\(i)",
                             sourceListingURL: nil, websiteURL: nil,
                             priorRelationship: "none", production: "self", profile: "strong",
                             coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                             matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
            p.presenter = "FRIGID New York"
            ctx.insert(p)
        }
        try? ctx.save()
    }

    // The money path. buildProbeQueue decides how many lookups Dan is charged for, so a correction that
    // fails to reach it costs him real money on every run, silently.
    @Test func theProbeQueueBuilderAppliesAStoredCorrection() throws {
        let ctx = ModelContext(try container())
        seedRentedRoom(ctx)
        let keys: Set<String> = ["frigid-0", "frigid-1"]

        // One room, so the gate refuses to amortise and each show is its own paid lookup.
        let before = PrepQueueService.buildProbeQueue(from: ctx, generatedAt: "2026-07-29", keys: keys)
        #expect(before.items.count == 2)

        ProducerOverrideEditing.promote("FRIGID New York", into: ctx)

        // Dan's judgment overrules the venue count: one organisation, one lookup, the rest riding on it.
        let after = PrepQueueService.buildProbeQueue(from: ctx, generatedAt: "2026-07-29", keys: keys)
        #expect(after.items.count == 1)
    }

    // The queue's own rows. An inherited answer shows a contact Dan never paid for on THIS show, so a
    // correction that failed to reach the ledger would leave the sharing he asked for simply not
    // happening, with the correction still reading as applied.
    @Test func inheritedAnswersApplyAStoredCorrection() throws {
        let ctx = ModelContext(try container())
        seedRentedRoom(ctx)
        let all = (try? ctx.fetch(FetchDescriptor<Prospect>())) ?? []
        // One show has its own paid answer; the other is the one that would inherit it.
        all.first { $0.naturalKey == "frigid-0" }?.reachabilityProbedAt = Date()
        let answer = OrgReachabilityAnswer(
            orgKey: OrgKey.stored(for: "FRIGID New York")!, result: .emailFound, probedAt: Date(),
            sourceNaturalKey: "frigid-0", sourceGroupName: "Show 0", presenterName: "FRIGID New York",
            foundEmails: ["info@frigid.nyc"])
        ctx.insert(answer)
        try? ctx.save()

        let before = QueueModel.items(from: all, answers: [answer], corpus: all)
            .first { $0.id == "frigid-1" }?.inheritedReachability
        #expect(before == nil)

        ProducerOverrideEditing.promote("FRIGID New York", into: ctx)

        let after = QueueModel.items(from: all, answers: [answer], corpus: all,
                                     overrides: ProducerOverrideEditing.overrides(in: ctx))
            .first { $0.id == "frigid-1" }?.inheritedReachability
        #expect(after != nil)
    }

    // The DEMOTE direction, on the consumer where it actually bites. A demoted organisation becomes a
    // venue brand, and the queue reads that to decide whether naming the presenter on the card would
    // just be repeating the room. Without this the new direction would reach no behaviour a test drives
    // at all, and its only cover would be the two source pins below.
    @Test func theDemotionDirectionReachesTheQueuesRows() throws {
        let ctx = ModelContext(try container())
        seedRentedRoom(ctx)
        let all = (try? ctx.fetch(FetchDescriptor<Prospect>())) ?? []

        let before = QueueModel.items(from: all, corpus: all).first { $0.id == "frigid-0" }?.presenterLine

        ProducerOverrideEditing.demote("FRIGID New York", into: ctx)

        let after = QueueModel.items(from: all, corpus: all,
                                     overrides: ProducerOverrideEditing.overrides(in: ctx))
            .first { $0.id == "frigid-0" }?.presenterLine
        #expect(before != after)
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
