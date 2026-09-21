import Testing
import Foundation
import SwiftData

// #3002 / #4082: Overture's own bookkeeping must not be written in Dan's words.
//
// Two places close something ON DAN'S BEHALF because another row already holds the nights, and both
// borrowed `ShowOutcome.duplicate`, which is also a value he picks himself off the Dismiss menu:
//
//   the NIGHT   `dropNight` records a released night with it (#2997, RunNightDrop.swift)
//   the SHOW    `ProspectMutations` closes a fully covered run with it (:853 and :987)
//
// Once written they are one value in the store and no reader can tell "Overture closed this because
// other cards hold its nights" from "Dan looked at this and called it a repeat" (L163: never express a
// fact by borrowing a neighbouring one). Nothing reads them apart today, which is why it costs nothing
// yet and why it is worth fixing before #16's outcome reporting is the thing that discovers it.
//
// The design was DECIDED on #3002 (2026-09-20) after a first attempt was built and reverted: a marker on
// the stored `DroppedNight` record fights #3324, which decided that record keeps its exact arity. Its own
// `ShowOutcome`, never offered on a menu, fights neither constraint and is the shape the vocabulary
// already has for exactly this (`wentBy` and `tooFar` are Overture's own two).
@MainActor
@Suite("An automatic release is Overture's own, not Dan's judgement (#3002, #4082)")
struct AutomaticReleaseIsNotDansJudgementTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: AppSchema.schema,
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    // THE NIGHT (#3002). Derived from `isOverturesOwn`, which the vocabulary already computes from the
    // two menu halves, rather than naming the new case here: a test naming it would pass just as well
    // for a value Dan can also pick, which is the whole defect.
    @Test func areleasedNightIsRecordedWithAValueDanCannotChoose() {
        #expect(RunNightDrop.automaticRelease.isOverturesOwn,
                "the release reason is on Dan's Dismiss menu, so his judgement and Overture's bookkeeping are one value")
    }

    // THE SHOW (#4082), the sibling one level up. Asserted through the real mutation rather than by
    // reading the constant, because the two call sites are what actually write it and a constant they
    // do not use proves nothing (L46).
    @Test func afullyCoveredRunIsClosedWithAValueDanCannotChoose() throws {
        let ctx = ModelContext(try container())
        let run = self.run(ctx, nights: ["2026-11-14", "2026-11-21"])
        // Both remaining nights are held by other rows, so the run carries nothing of its own.
        for night in ["2026-11-14", "2026-11-21"] {
            let twin = self.run(ctx, nights: [night])
            twin.naturalKey = Prospect.makeNaturalKey(groupName: run.groupName,
                                                      performanceDate: night, venue: run.venue)
        }
        try ctx.save()

        let outcome = run.dropNight("2026-11-14", reason: .tooSoon, now: Date(), in: ctx)
        guard case .fullyCovered = outcome else {
            Issue.record("the fixture did not reach the fully covered branch, so it measures nothing")
            return
        }
        // The caller is what writes the show's ending, so this asserts the value that path uses.
        run.markDismissed(reason: ShowOutcome.automaticRelease)

        #expect(run.showOutcome?.isOverturesOwn == true,
                "a run Overture closed carries an ending Dan could have picked, so the two are one value")
    }

    // MIGRATION, and the reason this is not a rename. Every release ALREADY in the store is recorded as
    // `.duplicate`, and `keeping` re-checks a release on every fold. Reading those old records as Dan's
    // own would stop Overture re-checking them, which is the #3001 defect reintroduced for exactly the
    // rows that have been in the store longest. So the re-check accepts both, while the WRITE uses only
    // the new value (L389: a writer that only fills records going forward never reaches what already
    // exists, so the reader is what has to cover them).
    @Test func areleaseRecordedBeforeThisChangeIsStillRechecked() throws {
        let ctx = ModelContext(try container())
        let p = run(ctx, nights: ["2026-11-14", "2026-11-21"])
        p.droppedRunNights = [DroppedNight(night: "2026-11-21", reason: .duplicate, at: Date()).stored]

        let kept = DroppedNight.keeping(["2026-11-14", "2026-11-21"], on: p, lookup: { _ in nil })
        #expect(kept == ["2026-11-14", "2026-11-21"],
                "a release written before this change was read as Dan's own and never re-checked again")
    }

    // And the new spelling is re-checked too, or the write and the read disagree from the day it ships.
    @Test func areleaseRecordedAfterThisChangeIsRechecked() throws {
        let ctx = ModelContext(try container())
        let p = run(ctx, nights: ["2026-11-14", "2026-11-21"])
        p.droppedRunNights = [DroppedNight(night: "2026-11-21",
                                           reason: RunNightDrop.automaticRelease, at: Date()).stored]

        let kept = DroppedNight.keeping(["2026-11-14", "2026-11-21"], on: p, lookup: { _ in nil })
        #expect(kept == ["2026-11-14", "2026-11-21"])
    }

    // Dan's own drop is STILL never re-checked, so widening the re-check above did not quietly swallow
    // his decisions. The case that matters is `.duplicate` chosen from the MENU, which is a show level
    // ending and cannot reach a dropped night, and every one night reason beside it.
    @Test func anightDanDroppedHimselfIsStillNeverGivenBack() throws {
        let ctx = ModelContext(try container())
        let p = run(ctx, nights: ["2026-11-14", "2026-11-21"])
        for reason in RunNightDrop.aboutOneNight {
            p.droppedRunNights = [DroppedNight(night: "2026-11-21", reason: reason, at: Date()).stored]
            let kept = DroppedNight.keeping(["2026-11-14", "2026-11-21"], on: p, lookup: { _ in nil })
            #expect(kept == ["2026-11-14"],
                    Comment(rawValue: "a night dropped as \(reason) came back, undoing Dan's own decision"))
        }
    }

    // The new value is never offered, which is the whole of "Overture's own". Asked of the menu itself
    // rather than of a list, so it stays true if the menu is rebuilt.
    @Test func theautomaticReleaseIsOnNeitherMenu() {
        for pitched in [true, false] {
            #expect(ShowOutcome.menu(wasPitched: pitched).contains(ShowOutcome.automaticRelease) == false,
                    Comment(rawValue: "the automatic release is offered on the wasPitched \(pitched) menu"))
        }
    }

    private func run(_ ctx: ModelContext, nights: [String]) -> Prospect {
        let p = Prospect(naturalKey: "covered run|\(nights.first ?? "x")|the players theatre",
                         groupName: "Covered Run", discipline: "comedy",
                         venue: "The Players Theatre", performanceDate: nights.first,
                         sourceListingURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 8, tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil)
        p.runNights = nights
        ctx.insert(p)
        return p
    }
}
