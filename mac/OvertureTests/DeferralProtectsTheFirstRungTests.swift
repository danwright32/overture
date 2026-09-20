import Testing
import Foundation
import SwiftData

// #4024: why `first` is safe at the top of two survivor ladders, asserted instead of derived.
//
// `DriftedRunMerge:96` and `SameNightTitleVariantMerge:119` both open their ladder with
// `first(where: { hasRecordBeyondADismissal($0, countingFoundAddresses: false) })` over a list nothing
// orders, and the LOSER of that pick is deleted. If two rows could satisfy that predicate the choice
// would be arbitrary and the deleted row would be the most expensive kind in the store.
//
// It cannot happen, and the reason lives in a different function: `mustDefer` refuses the merge outright
// first. Derived rather than taken from the issue, because that is this milestone's whole lesson:
//
//   hasRecordBeyondADismissal(p, countingFoundAddresses: false) implies the permissive form, since the
//   only line that differs is `recipients.contains(where: wasWrittenTo)` against `!recipients.isEmpty`
//   and the first implies the second. So two rows satisfying the strict form both satisfy
//   `hasOutreachHistory`, which takes the filter to 2, and each makes `neverContacted` false, so
//   `mustDefer` returns `!(false && _)` which is true.
//
// So the behaviour is correct as a SIDE EFFECT of a rule written for another purpose, which means it has
// no owner and the first change to that rule removes it silently (L281). This suite is the owner.
@Suite("Deferral is what makes the ladders' first rung safe (#4024)")
struct DeferralProtectsTheFirstRungTests {

    private func container() throws -> ModelContainer {
        let schema = Schema([Prospect.self, Recipient.self])
        return try ModelContainer(for: schema,
                                  configurations: [ModelConfiguration(schema: schema,
                                                                      isStoredInMemoryOnly: true)])
    }

    @discardableResult
    private func row(_ ctx: ModelContext, title: String, sent: Bool) -> Prospect {
        let p = Prospect(naturalKey: "k-\(title)", groupName: title, discipline: "theatre",
                         venue: "SoHo Playhouse", performanceDate: "2026-07-23",
                         sourceListingURL: nil, priorRelationship: "none", production: "self",
                         profile: "strong", coverage: "likely_uncovered", fitScore: 5, tier: "mid",
                         fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil)
        if sent {
            p.statusRaw = ReviewStatus.contacted.rawValue
            p.sentAt = Date(timeIntervalSince1970: 1_800_000_000)
        }
        ctx.insert(p)
        return p
    }

    // THE INVARIANT the two ladders rest on. Stated as the implication itself rather than as a merge
    // outcome, so it keeps meaning the same thing if either pass is restructured.
    @Test func twoRowsWithARecordBeyondADismissalAlwaysForceADeferral() throws {
        let ctx = ModelContext(try container())
        let a = row(ctx, title: "The Passion of Mr. Cardboard", sent: true)
        let b = row(ctx, title: "The Passion of Mr Cardboard", sent: true)
        try ctx.save()

        // The precondition, so a pass here can never come from a fixture where neither row qualifies
        // and the implication is vacuously true (L159).
        for p in [a, b] {
            #expect(NaturalKeyVenueMigration.hasRecordBeyondADismissal(p, countingFoundAddresses: false),
                    "the fixture's rows do not satisfy the predicate the ladders' first rung uses")
        }

        #expect(NaturalKeyVenueMigration.mustDefer([a, b]), """
            two rows carry a record beyond a dismissal and the merge was NOT deferred, so both ladders' \
            first rung is now an arbitrary pick between them and the loser is deleted (#4024)
            """)
    }

    // The step that makes the implication hold, pinned on its own because it is the part a reader would
    // have to work out: the strict form implies the permissive one, so `hasOutreachHistory` is satisfied
    // by anything the ladder's rung accepts.
    @Test func theStrictRecordTestImpliesTheOutreachHistoryTest() throws {
        let ctx = ModelContext(try container())
        let p = row(ctx, title: "One", sent: true)
        try ctx.save()

        #expect(NaturalKeyVenueMigration.hasRecordBeyondADismissal(p, countingFoundAddresses: false))
        #expect(NaturalKeyVenueMigration.hasOutreachHistory(p),
                Comment(rawValue: "the strict record test no longer implies outreach history, so "
                        + "mustDefer's row count can fall below two while both ladders' first "
                        + "rung still matches twice"))
    }

    // AND WHAT THIS DOES NOT COVER, recorded here because it is the question this suite makes obvious
    // and the answer is not reassuring. `ScoutService` never calls `mustDefer`: measured 2026-09-20,
    // zero occurrences in that file. Its two ingest arms use `first(where: hasOutreachHistory)` on an
    // unordered fetch with nothing establishing that at most one row matches, and the live store holds a
    // group where TWO rows sharing one `seriesId` both do (pk 139 and pk 655, both
    // `The Passion of Mr. Cardboard` at SoHo Playhouse, both dismissed). Both of those runs are in the
    // past so no incoming row carries that id today, which makes it latent rather than live.
    //
    // This test pins the contrast so the difference between the two families is visible rather than
    // assumed by a reader who has just read the comment above.
    @Test func theIngestArmsHaveNoSuchProtectionAndTheSourceSaysSo() {
        let source = SourceGuardHelper.source("Overture/Integration/ScoutService.swift")
        #expect(!source.isEmpty, "the guard read no source, so the check below passes on nothing")
        // The CALL shape, not the bare name. The first version of this checked for the name and went
        // red on the comment this test asked to be written, which is the trap
        // `RealStoreLockPairingTests` records about itself: a guard that cannot tell a line describing
        // the thing from a line doing it reports itself.
        #expect(!source.contains("mustDefer("), """
            ScoutService now calls mustDefer, so the ingest arms may have gained the protection the \
            merge passes have. Re-read #4024's note here and say what is true rather than leaving a \
            comment that is now wrong
            """)
    }
}
