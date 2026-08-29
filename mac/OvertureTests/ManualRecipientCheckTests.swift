import Testing
import Foundation
import SwiftData

@MainActor
@Suite("Manual recipient check (#399)")
struct ManualRecipientCheckTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func makeProspect(_ ctx: ModelContext, venue: String? = nil) -> Prospect {
        let p = Prospect(naturalKey: "k", groupName: "Aurora Strings", discipline: "music", venue: venue,
                         performanceDate: nil, sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        ctx.insert(p)
        return p
    }

    private func recipient(_ email: String, sendState: SendState = .sent,
                           resolution: RecipientResolution? = nil,
                           suppressionReason: RecipientSuppressionReason? = nil) -> Recipient {
        let r = Recipient(id: email, email: email, provenance: .manual)
        r.sendState = sendState
        r.resolution = resolution
        if let suppressionReason { r.suppressionReason = suppressionReason }
        return r
    }

    @Test func blocksAnAlreadyActiveExactMatch() throws {
        let ctx = ModelContext(try container())
        let p = makeProspect(ctx)
        p.setRecipients([recipient("jane@example.com")])

        let result = ManualRecipientCheck.evaluate(email: "Jane@Example.com",
                                                    existingRecipients: p.recipients, venue: nil)

        #expect(result.action == .blocked(existingId: "jane@example.com"))
    }

    @Test func resumesARemovedByDanMatch() throws {
        let ctx = ModelContext(try container())
        let p = makeProspect(ctx)
        p.setRecipients([recipient("jane@example.com", sendState: .suppressed, suppressionReason: .removedByDan)])

        let result = ManualRecipientCheck.evaluate(email: "jane@example.com",
                                                    existingRecipients: p.recipients, venue: nil)

        #expect(result.action == .resume(existingId: "jane@example.com"))
    }

    @Test func resumesADeclinedSuppressionMatch() throws {
        let ctx = ModelContext(try container())
        let p = makeProspect(ctx)
        p.setRecipients([recipient("jane@example.com", sendState: .suppressed, suppressionReason: .declined)])

        let result = ManualRecipientCheck.evaluate(email: "jane@example.com",
                                                    existingRecipients: p.recipients, venue: nil)

        #expect(result.action == .resume(existingId: "jane@example.com"))
    }

    @Test func resumesADeclinedSoftMatch() throws {
        let ctx = ModelContext(try container())
        let p = makeProspect(ctx)
        p.setRecipients([recipient("jane@example.com", resolution: .declinedSoft)])

        let result = ManualRecipientCheck.evaluate(email: "jane@example.com",
                                                    existingRecipients: p.recipients, venue: nil)

        #expect(result.action == .resume(existingId: "jane@example.com"))
    }

    @Test func resumesADeclinedHardMatch() throws {
        let ctx = ModelContext(try container())
        let p = makeProspect(ctx)
        p.setRecipients([recipient("jane@example.com", resolution: .declinedHard)])

        let result = ManualRecipientCheck.evaluate(email: "jane@example.com",
                                                    existingRecipients: p.recipients, venue: nil)

        #expect(result.action == .resume(existingId: "jane@example.com"))
    }

    @Test func blocksABookedMatch() throws {
        let ctx = ModelContext(try container())
        let p = makeProspect(ctx)
        p.setRecipients([recipient("jane@example.com", resolution: .booked)])

        let result = ManualRecipientCheck.evaluate(email: "jane@example.com",
                                                    existingRecipients: p.recipients, venue: nil)

        #expect(result.action == .blocked(existingId: "jane@example.com"))
    }

    @Test func blocksABookedElsewhereSuppressedMatch() throws {
        let ctx = ModelContext(try container())
        let p = makeProspect(ctx)
        p.setRecipients([recipient("jane@example.com", sendState: .suppressed, suppressionReason: .bookedElsewhere)])

        let result = ManualRecipientCheck.evaluate(email: "jane@example.com",
                                                    existingRecipients: p.recipients, venue: nil)

        #expect(result.action == .blocked(existingId: "jane@example.com"))
    }

    @Test func flagsASharedDomainWithAnotherExistingRecipient() throws {
        let ctx = ModelContext(try container())
        let p = makeProspect(ctx)
        p.setRecipients([recipient("jane@aurorastrings.example")])

        let result = ManualRecipientCheck.evaluate(email: "bob@aurorastrings.example",
                                                    existingRecipients: p.recipients, venue: nil)

        #expect(result.action == .create)
        #expect(result.sharesOrgWith == "jane@aurorastrings.example")
    }

    @Test func flagsAVenueWordSuffixedDomain() throws {
        let result = ManualRecipientCheck.evaluate(email: "info@carnegiehall.org",
                                                    existingRecipients: [], venue: "Carnegie Hall")
        #expect(result.looksLikeVenue == true)
    }

    @Test func flagsABareProperNounVenueWithNoVenueWord() throws {
        let result = ManualRecipientCheck.evaluate(email: "info@wavehill.org",
                                                    existingRecipients: [], venue: "Wave Hill")
        #expect(result.looksLikeVenue == true)
    }

    @Test func flagsAMultiWordVenue() throws {
        let result = ManualRecipientCheck.evaluate(email: "info@madisonsquarepark.org",
                                                    existingRecipients: [], venue: "Madison Square Park")
        #expect(result.looksLikeVenue == true)
    }

    @Test func doesNotFlagAnUnrelatedDomain() throws {
        let result = ManualRecipientCheck.evaluate(email: "jane@aurorastrings.example",
                                                    existingRecipients: [], venue: "Carnegie Hall")
        #expect(result.looksLikeVenue == false)
    }

    @Test func aCleanAddHasNoFlagsAndCreates() throws {
        let result = ManualRecipientCheck.evaluate(email: "new@newcontact.example",
                                                    existingRecipients: [], venue: nil)
        #expect(result.action == .create)
        #expect(result.sharesOrgWith == nil)
        #expect(result.looksLikeVenue == false)
    }
}
