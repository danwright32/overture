import Testing
import Foundation
import SwiftData

@MainActor
@Suite("Duplicate contact guard")
struct DuplicateContactGuardTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    @discardableResult
    private func makeProspect(_ ctx: ModelContext, group: String, date: String?, venue: String?,
                              email: String?, closed: Bool = false) -> String {
        let key = Prospect.makeNaturalKey(groupName: group, performanceDate: date, venue: venue)
        let p = Prospect(naturalKey: key, groupName: group, discipline: "music", venue: venue,
                         performanceDate: date, sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .queued)
        if closed { p.outcome = .lostHard }
        ctx.insert(p)
        if let email {
            let r = Recipient(id: email, email: email, provenance: .act)
            p.addRecipient(r)
        }
        try? ctx.save()
        return key
    }

    @Test func flagsWhenSameEmailSameVenueCloseDate() throws {
        let ctx = ModelContext(try container())
        makeProspect(ctx, group: "A", date: "2026-07-08", venue: "Weill Recital Hall", email: "info@act.example")
        let result = DuplicateContactGuard.looksLikeDuplicate(
            email: "info@act.example", venue: "Weill Recital Hall", performanceDate: "2026-07-09",
            excludingProspectKey: "some-other-key", in: ctx)
        #expect(result == true)
    }

    @Test func caseInsensitiveEmailStillMatches() throws {
        let ctx = ModelContext(try container())
        makeProspect(ctx, group: "A", date: "2026-07-08", venue: "Weill Recital Hall", email: "Info@Act.example")
        let result = DuplicateContactGuard.looksLikeDuplicate(
            email: "info@act.example", venue: "Weill Recital Hall", performanceDate: "2026-07-09",
            excludingProspectKey: "some-other-key", in: ctx)
        #expect(result == true)
    }

    @Test func doesNotFlagWhenVenueDiffers() throws {
        let ctx = ModelContext(try container())
        makeProspect(ctx, group: "A", date: "2026-07-08", venue: "Weill Recital Hall", email: "info@act.example")
        let result = DuplicateContactGuard.looksLikeDuplicate(
            email: "info@act.example", venue: "Carnegie Hall", performanceDate: "2026-07-09",
            excludingProspectKey: "some-other-key", in: ctx)
        #expect(result == false)
    }

    @Test func flagsAtExactlyTheThreeDayBoundary() throws {
        let ctx = ModelContext(try container())
        makeProspect(ctx, group: "A", date: "2026-07-05", venue: "Weill Recital Hall", email: "info@act.example")
        let result = DuplicateContactGuard.looksLikeDuplicate(
            email: "info@act.example", venue: "Weill Recital Hall", performanceDate: "2026-07-08",
            excludingProspectKey: "some-other-key", in: ctx)
        #expect(result == true)
    }

    @Test func doesNotFlagJustPastTheThreeDayBoundary() throws {
        let ctx = ModelContext(try container())
        makeProspect(ctx, group: "A", date: "2026-07-05", venue: "Weill Recital Hall", email: "info@act.example")
        let result = DuplicateContactGuard.looksLikeDuplicate(
            email: "info@act.example", venue: "Weill Recital Hall", performanceDate: "2026-07-09",
            excludingProspectKey: "some-other-key", in: ctx)
        #expect(result == false)
    }

    @Test func flagsRegardlessOfWhichDateComesFirst() throws {
        let ctx = ModelContext(try container())
        makeProspect(ctx, group: "A", date: "2026-07-09", venue: "Weill Recital Hall", email: "info@act.example")
        let result = DuplicateContactGuard.looksLikeDuplicate(
            email: "info@act.example", venue: "Weill Recital Hall", performanceDate: "2026-07-08",
            excludingProspectKey: "some-other-key", in: ctx)
        #expect(result == true)
    }

    @Test func doesNotFlagAClosedOtherProspect() throws {
        let ctx = ModelContext(try container())
        makeProspect(ctx, group: "A", date: "2026-07-08", venue: "Weill Recital Hall",
                    email: "info@act.example", closed: true)
        let result = DuplicateContactGuard.looksLikeDuplicate(
            email: "info@act.example", venue: "Weill Recital Hall", performanceDate: "2026-07-09",
            excludingProspectKey: "some-other-key", in: ctx)
        #expect(result == false)
    }

    @Test func doesNotFlagTheSameProspectItself() throws {
        let ctx = ModelContext(try container())
        let key = makeProspect(ctx, group: "A", date: "2026-07-08", venue: "Weill Recital Hall",
                               email: "info@act.example")
        let result = DuplicateContactGuard.looksLikeDuplicate(
            email: "info@act.example", venue: "Weill Recital Hall", performanceDate: "2026-07-08",
            excludingProspectKey: key, in: ctx)
        #expect(result == false)
    }

    @Test func doesNotFlagWithNoPerformanceDate() throws {
        let ctx = ModelContext(try container())
        makeProspect(ctx, group: "A", date: "2026-07-08", venue: "Weill Recital Hall", email: "info@act.example")
        let result = DuplicateContactGuard.looksLikeDuplicate(
            email: "info@act.example", venue: "Weill Recital Hall", performanceDate: nil,
            excludingProspectKey: "some-other-key", in: ctx)
        #expect(result == false)
    }

    @Test func doesNotFlagWithNoEmail() throws {
        let ctx = ModelContext(try container())
        makeProspect(ctx, group: "A", date: "2026-07-08", venue: "Weill Recital Hall", email: "info@act.example")
        let result = DuplicateContactGuard.looksLikeDuplicate(
            email: nil, venue: "Weill Recital Hall", performanceDate: "2026-07-09",
            excludingProspectKey: "some-other-key", in: ctx)
        #expect(result == false)
    }
}
