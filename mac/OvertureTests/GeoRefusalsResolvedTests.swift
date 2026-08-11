import Testing
import Foundation
import SwiftData

// #1962, measured with `sample` against the live Release build on 2026-08-01 after Dan reported that
// dismissing a show takes too long to go away: of 14,856 main-thread samples, 4,762 were inside
// QueueView.body, and the largest slice of those was `EventPlace.resolve` reached through
// `GeoRefusals.hidesFromQueue`, about 1,270 samples. Three sweeps in ONE rebuild each asked it about
// every show, and none reused the others' answer.
//
// The verdict is a pure function of the place, the discipline and Dan's standing refusals, so a pass can
// resolve each distinct place once and answer every show from that. The rule is untouched: the table is
// a memo of the same function, and a place missing from it is resolved exactly as before.
@MainActor
@Suite("A pass resolves each place once (#1962)")
struct GeoRefusalsResolvedTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    @discardableResult
    private func show(_ ctx: ModelContext, key: String, location: String?,
                      discipline: String = "music", status: ReviewStatus = .new) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: "Aurora Strings", discipline: discipline,
                         venue: "A room", performanceDate: "2026-11-14", sourceListingURL: nil,
                         websiteURL: nil, priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: status)
        p.location = location
        ctx.insert(p)
        return p
    }

    // A spread that covers each way a show can place: comfortably in range, plainly out of it, and a
    // location Overture cannot read at all, which must always keep the show.
    private func corpus(_ ctx: ModelContext) -> [Prospect] {
        [show(ctx, key: "a", location: "New York, NY"),
         show(ctx, key: "b", location: "New York, NY"),
         show(ctx, key: "c", location: "Brooklyn, NY"),
         show(ctx, key: "d", location: "Los Angeles, CA"),
         show(ctx, key: "e", location: "Los Angeles, CA", discipline: "theater"),
         show(ctx, key: "f", location: nil),
         show(ctx, key: "g", location: ""),
         show(ctx, key: "h", location: "Somewhere nobody has heard of"),
         // The pair that proves the discipline is part of the question rather than decoration: in New
         // York State but outside the boroughs, which is out of range for music and in range for theater.
         // Without these two the table could forget the discipline entirely and every verdict would still
         // come out right.
         show(ctx, key: "i", location: "Yonkers, NY", discipline: "music"),
         show(ctx, key: "j", location: "Yonkers, NY", discipline: "theater")]
    }

    // The whole claim: the memo answers exactly what the rule answers, for every show.
    @Test func theResolvedGateAgreesWithTheRuleOnEveryShow() throws {
        let ctx = ModelContext(try container())
        let shows = corpus(ctx)
        let plain = GeoRefusals(userExcludedTowns: ["los angeles"])
        let resolved = plain.resolving(shows)

        for p in shows {
            #expect(resolved.hidesFromQueue(p) == plain.hidesFromQueue(p), "disagreed about \(p.naturalKey)")
        }
        // Without this the agreement above could be two identical "nothing is hidden" answers.
        #expect(shows.contains { plain.hidesFromQueue($0) })
    }

    // The countable win (#1913): ten shows, nine distinct questions between them.
    @Test func eachDistinctPlaceIsResolvedOnceHoweverManyShowsSitOnIt() throws {
        let ctx = ModelContext(try container())
        let shows = corpus(ctx)

        let resolved = GeoRefusals().resolving(shows)

        // The two New York shows collapse onto one question. The two Los Angeles ones do NOT, because
        // they are different disciplines and the verdict depends on both. A missing location and an empty
        // one stay separate too: they reach the resolver as different inputs, and it is not this table's
        // business to decide they mean the same thing.
        #expect(resolved.resolvedPlaceCount == 9)
        #expect(resolved.resolvedPlaceCount < shows.count)
    }

    // A place the pass never saw must still get the right answer rather than a default. A memo that
    // answered "not hidden" on a miss would quietly keep shows Dan has refused.
    @Test func aPlaceMissingFromTheTableIsResolvedNormally() throws {
        let ctx = ModelContext(try container())
        let seen = [show(ctx, key: "seen", location: "New York, NY")]
        let unseen = show(ctx, key: "unseen", location: "Los Angeles, CA")
        let plain = GeoRefusals(userExcludedTowns: ["los angeles"])

        let resolved = plain.resolving(seen)

        #expect(resolved.resolvedPlaceCount == 1)
        #expect(resolved.hidesFromQueue(unseen) == plain.hidesFromQueue(unseen))
        #expect(resolved.hidesFromQueue(unseen))
    }

    // The table is derived, so it must not make two gates carrying the same refusals look different.
    // One of them is read as an input fingerprint, and a difference there reports as a change.
    @Test func resolvingChangesNothingAboutWhatTheGateIs() throws {
        let ctx = ModelContext(try container())
        let shows = corpus(ctx)
        let plain = GeoRefusals(userExcludedTowns: ["los angeles"], allowedSeedTowns: ["yonkers"])

        #expect(plain.resolving(shows) == plain)
        #expect(plain.resolving(shows).userExcludedTowns == plain.userExcludedTowns)
        #expect(plain.resolving(shows).allowedSeedTowns == plain.allowedSeedTowns)
    }

    // The status half of the gate is untouched by any of this: a show carrying live outreach is never
    // hidden by geography, whatever its town says, because burying it would lose a reply silently.
    @Test func aShowCarryingLiveOutreachIsStillNeverHidden() throws {
        let ctx = ModelContext(try container())
        let approved = show(ctx, key: "approved", location: "Los Angeles, CA", status: .approved)
        let untriaged = show(ctx, key: "untriaged", location: "Los Angeles, CA", status: .new)
        let resolved = GeoRefusals(userExcludedTowns: ["los angeles"]).resolving([approved, untriaged])

        #expect(!resolved.hidesFromQueue(approved))
        #expect(resolved.hidesFromQueue(untriaged))
    }
}

// The wiring. The memo can be perfect and the queue can still resolve every show three times if the pass
// does not build one, and no running test can evaluate QueueView's body (its @Query properties need a
// live container), so this guards the shape the way QueueInvalidationGuardTests does.
@Suite("The render pass resolves the geography once and shares it (#1962)")
struct GeoRefusalsRenderPassWiringTests {
    private var queueView: String { SourceGuardHelper.source("Overture/UI/QueueView.swift") }
    // #1913: the derivation moved here, so the guards on its shape moved with it.
    private var renderPass: String { SourceGuardHelper.source("Overture/UI/QueueRenderPass.swift") }

    @Test func thePassResolvesEveryShowsPlaceOnce() {
        guard let body = SourceGuardHelper.propertyBody("static func make(_ i: Inputs) -> QueueView.RenderData {",
                                                        in: renderPass) else {
            Issue.record("expected to find the render pass")
            return
        }
        // #2365: the resolve happens through the CONTEXT, so the pass carries one value through its
        // sweeps rather than unpacking the gate and passing the pieces separately.
        #expect(body.contains("let context = i.context.resolvingPlaces(of: i.prospects.all)"))
    }

    // And carries it, so the surfaces built from the same pass answer from the same table rather than
    // reaching for the unresolved value and sweeping the store again.
    @Test func theResolvedGateRidesInTheRenderSnapshot() {
        #expect(queueView.contains("let geo: GeoRefusals"))
        guard let empty = SourceGuardHelper.propertyBody("private func stageEmptyState(for stage: StageFocus, data: RenderData) -> some View {",
                                                         in: queueView) else {
            Issue.record("expected to find stageEmptyState")
            return
        }
        #expect(empty.contains("geo: data.geo"))
    }
}
