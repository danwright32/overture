import Testing
import Foundation
import SwiftData
@testable import Overture

// #367: the single shared helper both the per-prospect and bulk re-prep UI actions use to set a
// prospect's re-prep flags from a requested mode. Gates the DRAFT-affecting half on sentAt == nil
// (red-team finding 3): a multi-recipient show can have one recipient already sent while the
// prospect is still .approved, so redrafting the shared body could create two different pitches
// for the same show. Contacts-only is never restricted by send state.
@MainActor
@Suite("Re-prep request: shared gated-apply helper")
struct ReprepRequestTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func prospect(_ ctx: ModelContext, sentAt: Date? = nil) -> Prospect {
        let p = Prospect(naturalKey: "k", groupName: "G", discipline: "choral", venue: "V",
                         performanceDate: "2026-07-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .drafted)
        p.draftBody = "Hi"
        p.sentAt = sentAt
        ctx.insert(p)
        return p
    }

    @Test func draftOnlyOnUnsentProspectSetsOnlyDraftFlag() throws {
        let ctx = ModelContext(try container())
        let p = prospect(ctx, sentAt: nil)

        let draftGranted = ReprepRequest.apply(.draftOnly, to: p)

        #expect(p.reprepDraftRequested == true)
        #expect(p.reprepContactsRequested == false)
        #expect(draftGranted == true)
    }

    @Test func contactsOnlyOnUnsentProspectSetsOnlyContactsFlag() throws {
        let ctx = ModelContext(try container())
        let p = prospect(ctx, sentAt: nil)

        ReprepRequest.apply(.contactsOnly, to: p)

        #expect(p.reprepDraftRequested == false)
        #expect(p.reprepContactsRequested == true)
    }

    @Test func bothOnUnsentProspectSetsBothFlags() throws {
        let ctx = ModelContext(try container())
        let p = prospect(ctx, sentAt: nil)

        ReprepRequest.apply(.both, to: p)

        #expect(p.reprepDraftRequested == true)
        #expect(p.reprepContactsRequested == true)
    }

    @Test func draftOnlyOnAlreadySentProspectIsRefused() throws {
        let ctx = ModelContext(try container())
        let p = prospect(ctx, sentAt: Date(timeIntervalSince1970: 10))

        let draftGranted = ReprepRequest.apply(.draftOnly, to: p)

        #expect(p.reprepDraftRequested == false)
        #expect(p.reprepContactsRequested == false)
        #expect(draftGranted == false)
    }

    @Test func bothOnAlreadySentProspectOnlyGrantsContacts() throws {
        let ctx = ModelContext(try container())
        let p = prospect(ctx, sentAt: Date(timeIntervalSince1970: 10))

        let draftGranted = ReprepRequest.apply(.both, to: p)

        #expect(p.reprepDraftRequested == false)
        #expect(p.reprepContactsRequested == true)
        #expect(draftGranted == false)
    }

    @Test func contactsOnlyOnAlreadySentProspectStillGrantsContacts() throws {
        let ctx = ModelContext(try container())
        let p = prospect(ctx, sentAt: Date(timeIntervalSince1970: 10))

        ReprepRequest.apply(.contactsOnly, to: p)

        #expect(p.reprepContactsRequested == true)
    }

    // #733: guard against repeatedly re-prepping the same prospect. A 24h cooldown from when a
    // Prep run last actually served this prospect (normal draft or a served re-prep).
    @Test func isInCooldownTrueWithinTwentyFourHours() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let twentyThreeHoursAgo = now.addingTimeInterval(-23 * 3600)
        #expect(ReprepRequest.isInCooldown(lastServedAt: twentyThreeHoursAgo, now: now) == true)
    }

    @Test func isInCooldownFalsePastTwentyFourHours() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let twentyFiveHoursAgo = now.addingTimeInterval(-25 * 3600)
        #expect(ReprepRequest.isInCooldown(lastServedAt: twentyFiveHoursAgo, now: now) == false)
    }

    @Test func isInCooldownFalseWhenNeverServed() {
        #expect(ReprepRequest.isInCooldown(lastServedAt: nil, now: Date()) == false)
    }
}
