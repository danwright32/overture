import Testing
import Foundation
import SwiftData
@testable import Overture

// #1719 (milestone 34 Phase 2), the way in. The store and the wiring shipped first and changed nothing
// Dan could see, because nothing could put a key in either set. This is the half that switches it on.
//
// Dan's choice, asked on 2026-07-29: correct it inline, on the show where the wrong verdict is visible,
// with no management sheet. The control is STATEFUL so it doubles as the way back, which is what makes
// a sheet unnecessary: the same menu that applied a correction shows it in force and takes it back.
@MainActor
@Suite("Correcting a producer/house verdict from the row (#1719)")
struct ProducerCorrectionControlTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: AppSchema.schema,
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func prospect(_ ctx: ModelContext, key: String, presenter: String?) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: "A Show", discipline: "theater",
                         venue: "Under St Marks", performanceDate: "2026-09-10",
                         sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        p.presenter = presenter
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    // The row has to KNOW what is in force, or the control cannot show it and cannot offer the way back.
    // Derived in the model from the same overrides the gate reads, never looked up in the view (#863).
    @Test func theRowCarriesTheCorrectionInForce() throws {
        let ctx = ModelContext(try container())
        _ = prospect(ctx, key: "k1", presenter: "FRIGID New York")
        let all = (try? ctx.fetch(FetchDescriptor<Prospect>())) ?? []

        #expect(QueueModel.items(from: all).first?.producerStanding == ProducerOverrideEditing.Standing.none)

        ProducerOverrideEditing.demote("FRIGID New York", into: ctx)
        let demoted = QueueModel.items(from: all,
                                       overrides: ProducerOverrideEditing.overrides(in: ctx)).first
        #expect(demoted?.producerStanding == .demoted)

        ProducerOverrideEditing.promote("FRIGID New York", into: ctx)
        let promoted = QueueModel.items(from: all,
                                        overrides: ProducerOverrideEditing.overrides(in: ctx)).first
        #expect(promoted?.producerStanding == .promoted)
    }

    // A row with no presenter has no organisation to correct, so the control must not be offered. Offering
    // it would either do nothing on click or store a key nothing can ever match, which is the silent kind
    // of wrong this whole issue exists to end.
    @Test func aRowWithNoOrganisationOffersNothingToCorrect() throws {
        let ctx = ModelContext(try container())
        _ = prospect(ctx, key: "k1", presenter: nil)
        let all = (try? ctx.fetch(FetchDescriptor<Prospect>())) ?? []
        #expect(QueueModel.items(from: all).first?.correctableOrganisation == nil)
    }

    @Test func aRowWithAnOrganisationNamesItForTheControl() throws {
        let ctx = ModelContext(try container())
        _ = prospect(ctx, key: "k1", presenter: "FRIGID New York")
        let all = (try? ctx.fetch(FetchDescriptor<Prospect>())) ?? []
        #expect(QueueModel.items(from: all).first?.correctableOrganisation == "FRIGID New York")
    }

    // The mutation, end to end from the row's own item: it stores the correction the gate will read.
    @Test func correctingFromTheRowStoresWhatTheGateReads() throws {
        let ctx = ModelContext(try container())
        _ = prospect(ctx, key: "k1", presenter: "FRIGID New York")
        let item = QueueModel.items(from: (try? ctx.fetch(FetchDescriptor<Prospect>())) ?? []).first!
        let feedback = ActionFeedback()

        ProspectMutations.correctProducer(item, to: .demoted, context: ctx, feedback: feedback)
        #expect(ProducerOverrideEditing.overrides(in: ctx).demoted == ["frigid new york"])

        // The way back, through the same call. This is what lets the inline control be the only surface.
        ProspectMutations.correctProducer(item, to: ProducerOverrideEditing.Standing.none,
                                          context: ctx, feedback: feedback)
        #expect(ProducerOverrideEditing.overrides(in: ctx).demoted.isEmpty)
        #expect(ProducerOverrideEditing.overrides(in: ctx).promoted.isEmpty)
    }

    // The control is wired into the row Dan actually triages in, not merely defined. A rule and its wiring
    // are two claims, and the view cannot be built by a running test.
    @Test func theRowAndFactoryReallyOfferTheControl() {
        let row = SourceGuardHelper.source("Overture/UI/ProspectRowView.swift")
        let factory = SourceGuardHelper.source("Overture/UI/ProspectRowFactory.swift")
        #expect(row.contains("onCorrectProducer"))
        #expect(row.contains("QueueModel.producerCorrectionLabel"))
        #expect(factory.contains("ProspectMutations.correctProducer"))
    }
}
