import Testing
import Foundation
import SwiftData

// #1559: collapse the duplicate rows #1528 left behind, without hiding a live show.
//
// #1528 stopped NEW duplicates: a run whose opening night drifts is now recognized by its feed production
// id instead of inserting a fresh prospect every day. It could not fix the rows already stored. Live store
// 2026-07-26: 50 rows carry a seriesId and 4 groups hold more than one (Hungry Women 4, Dukes 2, Jena
// Friedman 2, The Passion of Mr. Cardboard 2).
//
// LOW URGENCY BY DESIGN, and worth stating so nobody oversells this: these rows are NOT in Dan's queue.
// Each stops being listed once its night passes, accrues misses, and FeedReconcile retires it at
// goneThreshold 2. What this buys is tidiness plus one real edge, that a stale row could still be picked
// as the match target for a future scout.
//
// EVERY TEST BELOW EXISTS BECAUSE A RED-TEAM PASS FOUND THE OBVIOUS IMPLEMENTATION BROKEN. The obvious
// implementation was "copy NaturalKeyVenueMigration", and on this data that would have DELETED THE ONLY
// VISIBLE Dukes and Jena Friedman cards, because #1064 picks the earliest-ingested survivor. That was
// right there (contemporaneous spelling variants of one venue) and is backwards here (a time series,
// where earliest reliably means most stale, typically already past the gone threshold and hidden).
@MainActor
@Suite("Collapsing drifted run rows without hiding a live show (#1559)")
struct DriftedRunMergeTests {

    private let venue = "SoHo Playhouse"
    private let feedId = "1280419"

    private func ctx() throws -> ModelContext {
        let container = try ModelContainer(for: Schema([Prospect.self]),
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        return ModelContext(container)
    }

    @discardableResult
    private func row(_ context: ModelContext, night: String, title: String = "Hungry Women",
                     venue: String? = nil, series: String? = nil, ingestedDaysAgo: Int,
                     missed: Int = 0, dismissed: Bool = false) -> Prospect {
        let v = venue ?? self.venue
        let p = Prospect(naturalKey: Prospect.makeNaturalKey(groupName: title, performanceDate: night,
                                                            venue: v),
                         groupName: title, discipline: "theatre", venue: v, performanceDate: night,
                         sourceListingURL: nil, websiteURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 5, tier: "mid", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil)
        p.seriesId = series ?? feedId
        p.ingestedAt = Date(timeIntervalSince1970: 1_800_000_000)
            .addingTimeInterval(-Double(ingestedDaysAgo) * 86_400)
        p.missedScoutCount = missed
        if dismissed {
            p.statusRaw = ReviewStatus.dismissed.rawValue
            p.showOutcomeRaw = "too_soon"
        }
        context.insert(p)
        return p
    }

    private func all(_ context: ModelContext) throws -> [Prospect] {
        try context.fetch(FetchDescriptor<Prospect>())
    }

    // Dan's Hungry Women, exactly as stored: he refused the 07-23 night and three later nights of the same
    // run arrived untouched. #2001, his call: the refused row makes way for one he has not decided about,
    // so the show comes back and he gets to look again. The freshest undecided night is the one kept, for
    // this pass's own reason (the earlier nights are stale and the queue is already hiding them).
    @Test func therefusedRowMakesWayForTheUndecidedOnesSoTheShowComesBack() throws {
        let context = try ctx()
        row(context, night: "2026-07-23", ingestedDaysAgo: 3, missed: 5, dismissed: true)
        row(context, night: "2026-07-24", ingestedDaysAgo: 2, missed: 3)
        row(context, night: "2026-07-25", ingestedDaysAgo: 1, missed: 2)
        row(context, night: "2026-07-26", ingestedDaysAgo: 0, missed: 0)

        let summary = DriftedRunMerge.run(in: context)

        let survivors = try all(context)
        #expect(survivors.count == 1)
        #expect(survivors.first?.performanceDate == "2026-07-26")
        #expect(survivors.first?.status == .new, "the show must come back for another look")
        #expect(summary.duplicatesDeleted == 3)
    }

    // The survivor must not be left looking cancelled. Hungry Women's history row carries
    // missedScoutCount 5, which renders the card STRUCK THROUGH with "No longer in the feed, may be
    // cancelled" for a show that runs to 2026-08-30. Merging without resetting it would trade four hidden
    // rows for one visible lie.
    @Test func theSurvivorStopsLookingLikeItWasCancelled() throws {
        let context = try ctx()
        row(context, night: "2026-07-23", ingestedDaysAgo: 3, missed: 5, dismissed: true)
        row(context, night: "2026-07-26", ingestedDaysAgo: 0, missed: 0)

        DriftedRunMerge.run(in: context)

        #expect(try all(context).first?.missedScoutCount == 0)
    }

    // THE ONE THAT KILLED THE FIRST DESIGN. All rows pristine, so there is no decision to preserve and the
    // survivor is chosen by age. #1064 picks the EARLIEST ingested; here that is the most stale row, the
    // one already past the gone threshold and filtered out of the queue, and keeping it would delete the
    // only card Dan can currently see. Dukes and Jena Friedman both have this shape in the live store.
    @Test func whenAllRowsArePristineTheFreshestSurvivesNotTheOldest() throws {
        let context = try ctx()
        row(context, night: "2026-07-25", title: "Dukes", ingestedDaysAgo: 1, missed: 2)  // hidden
        row(context, night: "2026-07-26", title: "Dukes", ingestedDaysAgo: 0, missed: 0)  // the visible one

        DriftedRunMerge.run(in: context)

        let survivors = try all(context)
        #expect(survivors.count == 1)
        #expect(survivors.first?.performanceDate == "2026-07-26",
                "keeping the oldest row would delete the only card Dan can see")
    }

    // #1845: two rows Dan merely REFUSED, for the same reason, are one show he said no to twice, not a
    // conflict. This pass used to deadlock on them forever, which is the defect #1780 named and fixed for
    // #1064's pass; asking the shared decision here brings this one in line. The Passion of Mr. Cardboard
    // is the live pair. His refusal survives on the row that is kept.
    @Test func tworowsRefusedForTheSameReasonAreMerged() throws {
        let context = try ctx()
        row(context, night: "2026-07-23", title: "The Passion of Mr. Cardboard",
            series: "1281174", ingestedDaysAgo: 3, dismissed: true)
        row(context, night: "2026-07-24", title: "The Passion of Mr. Cardboard",
            series: "1281174", ingestedDaysAgo: 2, dismissed: true)

        let summary = DriftedRunMerge.run(in: context)

        let survivors = try all(context)
        #expect(survivors.count == 1)
        #expect(summary.duplicatesDeleted == 1)
        #expect(summary.conflictsDeferred == 0)
        #expect(survivors.first?.status == .dismissed, "his refusal must survive the merge")
    }

    // The safety line, unchanged: two refusals that DISAGREE are a real conflict, because choosing between
    // them silently rewrites why Dan said no, which the outcome reporting reads.
    @Test func tworowsRefusedForDifferentReasonsAreLeftAloneAndCounted() throws {
        let context = try ctx()
        let first = row(context, night: "2026-07-23", title: "The Passion of Mr. Cardboard",
                        series: "1281174", ingestedDaysAgo: 3, dismissed: true)
        first.showOutcomeRaw = "too_soon"
        let second = row(context, night: "2026-07-24", title: "The Passion of Mr. Cardboard",
                         series: "1281174", ingestedDaysAgo: 2, dismissed: true)
        second.showOutcomeRaw = "not_a_fit"

        let summary = DriftedRunMerge.run(in: context)

        #expect(try all(context).count == 2)
        #expect(summary.conflictsDeferred == 1)
        #expect(summary.duplicatesDeleted == 0)
    }

    // The other safety line, and the one that must never move: once a real email has gone out, merging
    // would move it onto the wrong night. Nothing is deleted and the conflict is counted, so a writeup
    // cannot claim these were fixed.
    @Test func tworowsThatBothReachedTheOutsideWorldAreLeftAloneAndCounted() throws {
        let context = try ctx()
        let first = row(context, night: "2026-07-23", title: "The Passion of Mr. Cardboard",
                        series: "1281174", ingestedDaysAgo: 3)
        first.sentAt = Date(timeIntervalSince1970: 1_700_000_000)
        first.gmailMessageId = "msg-1"
        let second = row(context, night: "2026-07-24", title: "The Passion of Mr. Cardboard",
                         series: "1281174", ingestedDaysAgo: 2)
        second.draftBody = "a draft Dan has already read"

        let summary = DriftedRunMerge.run(in: context)

        #expect(try all(context).count == 2)
        #expect(summary.conflictsDeferred == 1)
        #expect(summary.duplicatesDeleted == 0)
    }

    // It must never rewrite the key or the date. That step buys nothing (the next scout re-keys the
    // survivor through #1528's arm anyway) and it is the ONLY step that can throw against the unique key
    // index, inside a launch migration whose single save is shared with every other migration and whose
    // failure AppDelegate currently discards. One constraint violation would silently roll back all of
    // them, every launch, with nothing anywhere saying so.
    // Asserted against whichever row survives rather than a hardcoded one, so this pins the claim in its
    // own sentence (the key is never rewritten) and not the survivor rule, which lives in its own tests.
    @Test func itNeverRewritesTheKeyOrTheDate() throws {
        let context = try ctx()
        let refused = row(context, night: "2026-07-23", ingestedDaysAgo: 3, dismissed: true)
        let untouched = row(context, night: "2026-07-26", ingestedDaysAgo: 0)
        let keysAsMinted = [refused.performanceDate: refused.naturalKey,
                            untouched.performanceDate: untouched.naturalKey]

        DriftedRunMerge.run(in: context)

        let survivor = try #require(try all(context).first)
        #expect(survivor.naturalKey == keysAsMinted[survivor.performanceDate],
                "the survivor must still carry the key it was minted with")
        #expect(["2026-07-23", "2026-07-26"].contains(survivor.performanceDate ?? ""),
                "the merge must not invent a date")
    }

    // Idempotent: a second launch changes nothing and deletes nothing.
    @Test func runningItTwiceChangesNothingTheSecondTime() throws {
        let context = try ctx()
        row(context, night: "2026-07-23", ingestedDaysAgo: 3, missed: 5, dismissed: true)
        row(context, night: "2026-07-26", ingestedDaysAgo: 0)

        DriftedRunMerge.run(in: context)
        let second = DriftedRunMerge.run(in: context)

        #expect(try all(context).count == 1)
        #expect(second.duplicatesDeleted == 0)
        #expect(second.conflictsDeferred == 0)
    }

    // MARK: - What it must never touch

    @Test func aSingleRowIsLeftAlone() throws {
        let context = try ctx()
        row(context, night: "2026-07-23", ingestedDaysAgo: 0, missed: 4)

        DriftedRunMerge.run(in: context)

        let only = try #require(try all(context).first)
        #expect(try all(context).count == 1)
        #expect(only.missedScoutCount == 4, "a lone row's miss count is real, not a merge artifact")
    }

    // A feed id is only unique within its own source, so the same number at another venue is another show.
    @Test func theSameFeedIdAtADifferentVenueIsNeverMerged() throws {
        let context = try ctx()
        row(context, night: "2026-07-23", ingestedDaysAgo: 1)
        row(context, night: "2026-07-24", venue: "The Cutting Room", ingestedDaysAgo: 0)

        DriftedRunMerge.run(in: context)

        #expect(try all(context).count == 2)
    }

    // The #797 guard, same as #1528's: a shared "Series:" marker can be a SEASON spanning different
    // productions. Two different shows must never be fused, or a dismissal and a sent email end up on a
    // show they have nothing to do with.
    @Test func twoDifferentShowsSharingASeriesMarkerAreNeverMerged() throws {
        let context = try ctx()
        row(context, night: "2026-09-01", title: "An Evening with Rossini",
            series: "broadway-sessions", ingestedDaysAgo: 1)
        row(context, night: "2026-09-15", title: "The Sondheim Songbook",
            series: "broadway-sessions", ingestedDaysAgo: 0)

        DriftedRunMerge.run(in: context)

        #expect(try all(context).count == 2)
    }

    // The guard and its wiring are two claims (#887). Every rule above is inert unless launch actually
    // calls it, and a migration nobody runs is the easiest kind of dead code to ship believing it works.
    // Behavioural, not a source grep: it goes through the real LaunchMigrations entry point.
    @Test func launchActuallyRunsTheMerge() throws {
        let context = try ctx()
        row(context, night: "2026-07-23", ingestedDaysAgo: 3, missed: 5, dismissed: true)
        row(context, night: "2026-07-26", ingestedDaysAgo: 0)

        LaunchMigrations.run(in: context)

        let survivors = try all(context)
        #expect(survivors.count == 1)
        #expect(survivors.first?.performanceDate == "2026-07-26")
        #expect(survivors.first?.missedScoutCount == 0)
    }

    // Wisard in the live store: one row with an id and one without. Not a group, and deliberately not
    // covered, so nobody should claim this cleans it up.
    @Test func aRowWithNoFeedIdIsNeverPartOfAGroup() throws {
        let context = try ctx()
        row(context, night: "2026-07-24", title: "Wisard", series: "1276943", ingestedDaysAgo: 1)
        let idless = row(context, night: "2026-07-24", title: "Wisard", ingestedDaysAgo: 0)
        idless.seriesId = nil

        DriftedRunMerge.run(in: context)

        #expect(try all(context).count == 2)
    }
}
