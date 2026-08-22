import Testing
import Foundation
import SwiftData

// #3001: a night RELEASED because another card already held it must not stay released once that card is
// gone.
//
// #2997 lets a run card give up a night on the grounds that a stored card already holds it, recorded as a
// `DroppedNight` with reason `.duplicate`. `keeping` then subtracts it from every later scout re-fold,
// permanently, so the run can never carry that night again. Nothing re-checked the premise: if the
// covering card is dismissed or drops out of the venue's listings, the night is in the queue on NO card
// and nothing reports that it left (L92, L162, L200).
//
// Dan never chose to give that night up, which is what separates it from a night he dropped himself.
@MainActor
@Suite("A night released to another card is re-checked at fold time (#3001)")
struct ReleasedNightIsRecheckedTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: AppSchema.schema,
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func run(_ ctx: ModelContext, nights: [String]) -> Prospect {
        let p = Prospect(naturalKey: "fresh out the box|2026-11-14|the players theatre",
                         groupName: "Fresh Out The Box", discipline: "comedy",
                         venue: "The Players Theatre", performanceDate: nights.first,
                         sourceListingURL: nil, websiteURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 8, tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil)
        p.runNights = nights
        ctx.insert(p)
        return p
    }

    private struct StoreIsDown: Error {}

    // The night is still covered, so the release stands. This is the ordinary case and the one #2997 is
    // for: two cards must not both carry it.
    @Test func areleasedNightStaysReleasedWhileItsTwinExists() throws {
        let ctx = ModelContext(try container())
        let p = run(ctx, nights: ["2026-11-14", "2026-11-21"])
        let twin = run(ctx, nights: [])
        p.droppedRunNights = [DroppedNight(night: "2026-11-21", reason: .duplicate, at: Date()).stored]

        let kept = DroppedNight.keeping(["2026-11-14", "2026-11-21"], on: p, lookup: { _ in twin })
        #expect(kept == ["2026-11-14"])
    }

    // THE fix: the twin is gone, so the night comes back to the run that gave it up. Nobody chose to lose
    // it, and with the covering card gone it is on no card at all.
    @Test func areleasedNightComesBackWhenItsTwinIsGone() throws {
        let ctx = ModelContext(try container())
        let p = run(ctx, nights: ["2026-11-14", "2026-11-21"])
        p.droppedRunNights = [DroppedNight(night: "2026-11-21", reason: .duplicate, at: Date()).stored]

        let kept = DroppedNight.keeping(["2026-11-14", "2026-11-21"], on: p, lookup: { _ in nil })
        #expect(kept == ["2026-11-14", "2026-11-21"],
                "the covering card is gone, so the night is on no card and must return to the run")
    }

    // Dan's OWN drop is never re-checked. He decided it, and no other card's fate has anything to say
    // about that: re-checking it would undo a decision he made (L92 again, from the other side).
    @Test func anightDanDroppedHimselfIsNeverGivenBack() throws {
        let ctx = ModelContext(try container())
        let p = run(ctx, nights: ["2026-11-14", "2026-11-21"])
        for reason in [ShowOutcome.dateConflict, .hadPaidWork, .pitchingOtherShows, .dontWantToShoot] {
            p.droppedRunNights = [DroppedNight(night: "2026-11-21", reason: reason, at: Date()).stored]
            let kept = DroppedNight.keeping(["2026-11-14", "2026-11-21"], on: p, lookup: { _ in nil })
            #expect(kept == ["2026-11-14"],
                    Comment(rawValue: "a night dropped as \(reason) came back, undoing Dan's own decision"))
        }
    }

    // A read that FAILED is not evidence the twin is gone. Keeping the release is the steady direction:
    // resurrecting a night on a hiccup would make the run's nights flip back and forth between scouts,
    // and a message may only claim what its check measured (L11).
    @Test func afailedReadLeavesTheReleaseAlone() throws {
        let ctx = ModelContext(try container())
        let p = run(ctx, nights: ["2026-11-14", "2026-11-21"])
        p.droppedRunNights = [DroppedNight(night: "2026-11-21", reason: .duplicate, at: Date()).stored]

        let kept = DroppedNight.keeping(["2026-11-14", "2026-11-21"], on: p,
                                        lookup: { _ in throw StoreIsDown() })
        #expect(kept == ["2026-11-14"])
    }

    // A card that is its OWN twin is not cover: `keyAvailability` already reads a key held by this very
    // row as free, and the same must hold here or a run releases a night to itself and loses it.
    @Test func arowIsNeverItsOwnCover() throws {
        let ctx = ModelContext(try container())
        let p = run(ctx, nights: ["2026-11-14", "2026-11-21"])
        p.droppedRunNights = [DroppedNight(night: "2026-11-21", reason: .duplicate, at: Date()).stored]

        let kept = DroppedNight.keeping(["2026-11-14", "2026-11-21"], on: p, lookup: { _ in p })
        #expect(kept == ["2026-11-14", "2026-11-21"])
    }

    // The scout's fold is the reader this exists for, so it has to pass a real lookup: a fold that kept
    // the old two-argument call would go on subtracting permanently and every test above would still
    // pass (L46).
    @Test func thescoutsFoldRechecksRatherThanSubtractingBlindly() {
        let source = SourceGuardHelper.source("Overture/Integration/ScoutService.swift")
        #expect(!source.isEmpty, "the guard read no source, so it asserts nothing")
        #expect(source.contains("DroppedNight.keeping(p.runNights, on: existing, lookup: storedByKey)"),
                "the re-fold has to hand `keeping` a lookup, or a released night is subtracted forever")
        // #2726: BOTH arms that apply an enriched row, each named. The two calls are identical, so one
        // search was answered by whichever survived, and the arm that re-keys a moved show could have
        // dropped its lookup with this still green (L135).
        for arm in ["apply(enriched, to: existing, now: scoutNow, "
                        + "storedByKey: { try Prospect.stored(key: $0, in: context) })",
                    "apply(enriched, to: match, now: scoutNow, "
                        + "storedByKey: { try Prospect.stored(key: $0, in: context) })"] {
            #expect(SourceGuardHelper.containsCode(arm, in: source),
                    "the upsert has to supply a real store read, not a stub")
        }
    }
}
