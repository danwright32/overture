import Testing
import Foundation
import SwiftData

// #1784: the backfill that has to ship with the rule change, because a rule only ever reaches rows
// written after it. Widening OrgKey to drop a bracket changes what key an organisation's answer SHOULD
// carry, and a row already sitting in the ledger under the old spelling would otherwise be looked up by
// a key nobody computes any more: invisible, and paid for again.
//
// LIVE-STORE-CLAIM verified=2026-08-07 measure="rows in ZORGREACHABILITYANSWER on Dan's live store"
// Measured on Dan's store before writing this: the ledger holds ZERO rows today (the 2026-08-04
// reachability reset cleared it, which is also why #1784's own "two of the twelve answers" no longer
// describes anything). So this migration has nothing to do on his Mac THIS week. It ships anyway,
// because a check he runs between now and the install would write rows under the old key, and a
// backfill that only exists if someone remembers to write it later is the same as no backfill.
@MainActor
@Suite("Realigning ledger keys onto the shared organisation identity (#1784)")
struct OrgKeyRealignmentMigrationTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, OrgReachabilityAnswer.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private let older = Date(timeIntervalSince1970: 1_800_000_000)
    private let newer = Date(timeIntervalSince1970: 1_800_090_000)

    // Inserts a row holding a key SPELLED OUT rather than computed, which is the whole point: it stands
    // for a row a previous build wrote under the old fold.
    @discardableResult
    private func answer(_ ctx: ModelContext, key: String, presenter: String,
                        result: Reachability.ProbeResult = .emailFound,
                        probedAt: Date, emails: [String] = ["hello@example.org"]) -> OrgReachabilityAnswer {
        let row = OrgReachabilityAnswer(orgKey: key, result: result, probedAt: probedAt,
                                        sourceNaturalKey: "k|2026-09-12|somewhere",
                                        sourceGroupName: "A show", presenterName: presenter,
                                        foundEmails: emails)
        ctx.insert(row)
        try? ctx.save()
        return row
    }

    private func rows(_ ctx: ModelContext) throws -> [OrgReachabilityAnswer] {
        try ctx.fetch(FetchDescriptor<OrgReachabilityAnswer>()).sorted { $0.orgKey < $1.orgKey }
    }

    // The plain case: one row, keyed under the old spelling, nothing to collide with.
    @Test func aRowKeyedUnderTheOldSpellingIsMovedOntoTheNewOne() throws {
        let ctx = ModelContext(try container())
        let presenter = "The Golden Hour Series (curated with Jalopy Theatre, and others)"
        answer(ctx, key: "presenter:" + presenter.lowercased(), presenter: presenter, probedAt: older)

        let summary = OrgKeyRealignmentMigration.run(in: ctx)

        #expect(summary.rekeyed == 1)
        #expect(summary.duplicatesDeleted == 0)
        #expect(try rows(ctx).map(\.orgKey) == [OrgKey.stored(for: presenter)!])
    }

    // A row already carrying the right key is left completely alone, which is also what makes a second
    // pass a no-op.
    @Test func aRowAlreadyOnTheNewKeyIsUntouched() throws {
        let ctx = ModelContext(try container())
        answer(ctx, key: OrgKey.stored(for: "Tenet Vocal Artists")!, presenter: "Tenet Vocal Artists",
               probedAt: older)

        #expect(OrgKeyRealignmentMigration.run(in: ctx) == OrgKeyRealignmentMigration.Summary())
        #expect(try rows(ctx).count == 1)
    }

    @Test func runningTwiceChangesNothingTheSecondTime() throws {
        let ctx = ModelContext(try container())
        let presenter = "American Masters Music Awards (AMMA)"
        answer(ctx, key: "presenter:" + presenter.lowercased(), presenter: presenter, probedAt: older)

        OrgKeyRealignmentMigration.run(in: ctx)
        #expect(OrgKeyRealignmentMigration.run(in: ctx) == OrgKeyRealignmentMigration.Summary())
        #expect(try rows(ctx).count == 1)
    }

    // The case the widening actually creates: the same organisation twice, once bracketed and once not.
    // They agree, so the newer answer survives and the older duplicate goes.
    @Test func twoRowsForOneOrganisationCollapseOntoTheNewerAnswer() throws {
        let ctx = ModelContext(try container())
        let bracketed = "The Golden Hour Series (curated with Jalopy Theatre, and others)"
        answer(ctx, key: "presenter:" + bracketed.lowercased(), presenter: bracketed, probedAt: older)
        answer(ctx, key: OrgKey.stored(for: "The Golden Hour Series")!, presenter: "The Golden Hour Series",
               probedAt: newer)

        let summary = OrgKeyRealignmentMigration.run(in: ctx)

        #expect(summary.duplicatesDeleted == 1)
        #expect(summary.conflictsDeferred == 0)
        let survivors = try rows(ctx)
        #expect(survivors.count == 1)
        #expect(survivors.first?.probedAt == newer)
        #expect(survivors.first?.orgKey == OrgKey.stored(for: "The Golden Hour Series"))
    }

    // L5: nothing good is destroyed before its replacement is verified. Two rows that DISAGREE about what
    // the organisation's contact is are not a duplicate, they are a question, and a launch pass may not
    // answer it by picking one. Both are left exactly as they are.
    @Test func twoRowsThatDisagreeAreLeftAloneRatherThanMerged() throws {
        let ctx = ModelContext(try container())
        let bracketed = "The Golden Hour Series (curated with Jalopy Theatre, and others)"
        let oldKey = "presenter:" + bracketed.lowercased()
        answer(ctx, key: oldKey, presenter: bracketed, probedAt: older, emails: ["one@example.org"])
        answer(ctx, key: OrgKey.stored(for: "The Golden Hour Series")!, presenter: "The Golden Hour Series",
               probedAt: newer, emails: ["two@example.org"])

        let summary = OrgKeyRealignmentMigration.run(in: ctx)

        #expect(summary.conflictsDeferred == 1)
        #expect(summary.duplicatesDeleted == 0)
        #expect(summary.rekeyed == 0)
        #expect(try rows(ctx).count == 2)
        #expect(try rows(ctx).contains { $0.orgKey == oldKey })
    }

    // A disagreement about the VERDICT counts too, not only about the addresses: "we found an email" and
    // "there is no email" cannot both be this organisation's answer.
    @Test func aDisagreementAboutTheVerdictIsAlsoDeferred() throws {
        let ctx = ModelContext(try container())
        let bracketed = "Masticate (A Dark Comedy)"
        answer(ctx, key: "presenter:" + bracketed.lowercased(), presenter: bracketed,
               result: .noEmailFound, probedAt: older, emails: [])
        answer(ctx, key: OrgKey.stored(for: "Masticate")!, presenter: "Masticate",
               result: .emailFound, probedAt: newer, emails: ["hi@example.org"])

        #expect(OrgKeyRealignmentMigration.run(in: ctx).conflictsDeferred == 1)
        #expect(try rows(ctx).count == 2)
    }

    // A row whose presenter string no longer produces a key at all (it was blank, or became blank) is not
    // silently dropped: it keeps the key it has, so nothing is lost by a fold that failed.
    @Test func aRowWhosePresenterHasNoKeyIsLeftWhereItIs() throws {
        let ctx = ModelContext(try container())
        answer(ctx, key: "presenter:something", presenter: "   ", probedAt: older)

        #expect(OrgKeyRealignmentMigration.run(in: ctx) == OrgKeyRealignmentMigration.Summary())
        #expect(try rows(ctx).count == 1)
    }
}
