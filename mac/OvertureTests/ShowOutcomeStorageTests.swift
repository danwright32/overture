import Testing
import Foundation
import SwiftData

// #2394, phase 1 of docs/plans/2026-08-09-one-outcome-vocabulary.md: the one show-level field, its
// single writer, and the backfill that carries every ending already recorded onto it.
//
// The reason this field has to be at the SHOW level is measured, not stylistic. `closeOutFromRow`
// recorded the ending on the CONTACT and only touched the show when the answer was booked, while
// `OutcomeStats.tally` and `LocalHistory` read show-level lost values nothing ever wrote. So the
// funnel's lost count was structurally zero and the scout could never learn which orgs turned Dan
// down (#2401). One home for the fact, written once, read everywhere.
@MainActor
@Suite("The one show outcome field (#2394)")
struct ShowOutcomeStorageTests {

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self, DayOff.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private func show(_ ctx: ModelContext, key: String = "k",
                      status: ReviewStatus = .new) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: "G", discipline: "music", venue: "V",
                         performanceDate: "2026-11-18", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: status)
        ctx.insert(p)
        return p
    }

    private func contact(_ ctx: ModelContext, on p: Prospect, email: String = "a@b.com",
                         sendState: SendState = .pending,
                         resolution: RecipientResolution? = nil) -> Recipient {
        let r = Recipient(id: email, email: email, provenance: .manual)
        r.sendState = sendState
        if sendState == .sent { r.sentAt = Date() }
        r.resolution = resolution
        r.prospect = p
        ctx.insert(r)
        return r
    }

    // MARK: nothing recorded means nothing recorded

    // The absence of a value is what "still open" means. Giving open a spelling of its own is how
    // "still waiting to hear" and "they never answered" became the same record, so a fresh show must
    // carry no outcome at all rather than a default.
    @Test func afreshShowCarriesNoOutcome() throws {
        let ctx = try context()
        let p = show(ctx)
        #expect(p.showOutcome == nil)
        #expect(p.showOutcomeRaw == nil)
    }

    // MARK: was it pitched

    // Whether a show was pitched is a fact about the SEND RECORD, which is what decides the menu. Both
    // halves of that record count: the lead rollup stamp, and any one contact having been sent to. A
    // show whose contact went out but whose rollup was never stamped is still a pitched show, and
    // reading only the rollup would offer Dan "Date conflict" on a show he has already emailed.
    @Test func aShowWithNoSendWasNotPitched() throws {
        let ctx = try context()
        let p = show(ctx)
        _ = contact(ctx, on: p, sendState: .pending)
        #expect(p.wasPitched == false)
    }

    @Test func theLeadStampMakesItPitched() throws {
        let ctx = try context()
        let p = show(ctx)
        p.sentAt = Date()
        #expect(p.wasPitched)
    }

    @Test func aSentContactAloneMakesItPitched() throws {
        let ctx = try context()
        let p = show(ctx)
        _ = contact(ctx, on: p, sendState: .sent)
        #expect(p.sentAt == nil)   // the rollup was never stamped
        #expect(p.wasPitched)
    }

    // MARK: one writer

    // markDismissed is the ONE place a show is recorded as leaving the queue, and it now owns the
    // outcome too, so the four paths that dismiss a show cannot each remember to write it separately.
    @Test func dismissingAShowRecordsTheOutcomeAndDatesIt() throws {
        let ctx = try context()
        let p = show(ctx)
        p.markDismissed(reason: .hadPaidWork, at: Date(timeIntervalSince1970: 1_000))

        #expect(p.showOutcome == .hadPaidWork)
        #expect(p.status == .dismissed)
        #expect(p.dismissedAt == Date(timeIntervalSince1970: 1_000))
    }

    // Re-labelling why a dismissed show was cut is not a second exit, so the exit date is kept.
    @Test func relabellingADismissalKeepsTheOriginalExitDate() throws {
        let ctx = try context()
        let p = show(ctx)
        p.markDismissed(reason: .notAFit, at: Date(timeIntervalSince1970: 1_000))
        p.markDismissed(reason: .dontWantToShoot, at: Date(timeIntervalSince1970: 9_000))

        #expect(p.showOutcome == .dontWantToShoot)
        #expect(p.dismissedAt == Date(timeIntervalSince1970: 1_000))
    }

    @Test func restoringAShowClearsTheOutcomeAndTheExitDate() throws {
        let ctx = try context()
        let p = show(ctx)
        p.markDismissed(reason: .duplicate)
        p.clearDismissal()

        #expect(p.showOutcome == nil)
        #expect(p.dismissedAt == nil)
        #expect(p.status == .new)
    }

    // A restore has to clear the LEGACY column too, not only the live field. The backfill reads that
    // column, so a row restored while it still held an old reason would be handed its ending straight
    // back by the next launch, and the restore would quietly undo itself overnight.
    @Test func restoringAShowAlsoClearsWhatTheBackfillWouldReadBack() throws {
        let ctx = try context()
        let p = show(ctx, status: .dismissed)
        p.dismissReasonRaw = "already_booked"
        _ = ShowOutcomeBackfill.run(in: ctx)
        #expect(p.showOutcome == .hadPaidWork)

        p.clearDismissal()
        _ = ShowOutcomeBackfill.run(in: ctx)

        #expect(p.showOutcome == nil)
        #expect(p.status == .new)
    }

    // A brand new row records its ending on the one field, so nothing inserted after this shipped ever
    // needs backfilling and the legacy column stays empty for good.
    @Test func aNewRowWritesTheOneFieldNotTheLegacyColumn() throws {
        let ctx = try context()
        let p = Prospect(naturalKey: "n", groupName: "G", discipline: "music", venue: "V",
                         performanceDate: "2026-11-18", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .dismissed, dismissReason: .alreadyBooked)
        ctx.insert(p)

        #expect(p.showOutcome == .hadPaidWork)
        #expect(p.dismissReasonRaw == nil)
    }

    // MARK: the backfill

    // The two renames. "Already booked" meant Dan was busy and read as the client having hired him,
    // which is the collision the whole vocabulary exists to remove, so every row already carrying it
    // has to be moved onto the honest word.
    @Test func alreadyBookedBecomesPaidWork() throws {
        let ctx = try context()
        let p = show(ctx, status: .dismissed)
        p.dismissReasonRaw = "already_booked"

        _ = ShowOutcomeBackfill.run(in: ctx)

        #expect(p.showOutcome == .hadPaidWork)
    }

    @Test func notInterestedBecomesNotAFit() throws {
        let ctx = try context()
        let p = show(ctx, status: .dismissed)
        p.dismissReasonRaw = "not_interested"

        _ = ShowOutcomeBackfill.run(in: ctx)

        #expect(p.showOutcome == .notAFit)
    }

    @Test func theOtherSevenReasonsCarryAcrossUnchanged() throws {
        let ctx = try context()
        let pairs: [(String, ShowOutcome)] = [("date_conflict", .dateConflict),
                                              ("pitching_other_shows", .pitchingOtherShows),
                                              ("too_soon", .tooSoon),
                                              ("dont_want_to_shoot", .dontWantToShoot),
                                              ("duplicate", .duplicate),
                                              ("went_by", .wentBy),
                                              ("too_far", .tooFar)]
        var shows: [(Prospect, ShowOutcome)] = []
        for (i, pair) in pairs.enumerated() {
            let p = show(ctx, key: "k\(i)", status: .dismissed)
            p.dismissReasonRaw = pair.0
            shows.append((p, pair.1))
        }

        _ = ShowOutcomeBackfill.run(in: ctx)

        for (p, expected) in shows { #expect(p.showOutcome == expected) }
    }

    // A booking is the one ending Overture already recorded at the show level, so it comes across from
    // there rather than from a contact.
    @Test func aBookedShowBecomesBooked() throws {
        let ctx = try context()
        let p = show(ctx, status: .contacted)
        p.sentAt = Date()
        p.outcome = .booked

        _ = ShowOutcomeBackfill.run(in: ctx)

        #expect(p.showOutcome == .booked)
    }

    // The four endings that only ever lived on a CONTACT, which is why the funnel could not see them.
    @Test func aContactsEndingIsLiftedOntoTheShow() throws {
        let cases: [(RecipientResolution, ShowOutcome)] = [(.declinedSoft, .theySaidNotNow),
                                                           (.declinedHard, .theySaidNo),
                                                           (.stoodDown, .turnedThemDown),
                                                           (.neverHeardBack, .neverHeardBack),
                                                           (.booked, .booked)]
        for (resolution, expected) in cases {
            let ctx = try context()
            let p = show(ctx, status: .contacted)
            p.sentAt = Date()
            _ = contact(ctx, on: p, sendState: .sent, resolution: resolution)

            _ = ShowOutcomeBackfill.run(in: ctx)

            #expect(p.showOutcome == expected)
        }
    }

    // A booking outranks a decline on a sibling contact, matching how a show's status is already
    // derived: one yes ends the question however many people said no.
    @Test func aBookingOutranksASiblingsDecline() throws {
        let ctx = try context()
        let p = show(ctx, status: .contacted)
        p.sentAt = Date()
        _ = contact(ctx, on: p, email: "no@b.com", sendState: .sent, resolution: .declinedHard)
        _ = contact(ctx, on: p, email: "yes@b.com", sendState: .sent, resolution: .booked)

        _ = ShowOutcomeBackfill.run(in: ctx)

        #expect(p.showOutcome == .booked)
    }

    // A live pitch is not an ending. A show that went out and has heard nothing back yet must come
    // through the backfill with no outcome, because the alternative is filing every open pitch as
    // closed on the day this ships.
    @Test func anOpenPitchIsLeftWithNoOutcome() throws {
        let ctx = try context()
        let p = show(ctx, status: .contacted)
        p.sentAt = Date()
        _ = contact(ctx, on: p, sendState: .sent, resolution: nil)

        let result = ShowOutcomeBackfill.run(in: ctx)

        #expect(p.showOutcome == nil)
        // Counted as deliberately left open, not silently skipped, so the backfill's own report can say
        // how many live pitches it walked past rather than implying it closed everything it saw.
        #expect(result.leftOpen == 1)
    }

    // A show with a contact still to try is NOT over, even though another contact already said no. The
    // backfill must not close it, because the act-then-presenter ladder means there is somebody left to
    // ask, and an ending written here would take the show off Dan's list while a route to it remained.
    @Test func aShowWithSomebodyLeftToTryIsLeftOpen() throws {
        let ctx = try context()
        let p = show(ctx, status: .contacted)
        p.sentAt = Date()
        _ = contact(ctx, on: p, email: "no@b.com", sendState: .sent, resolution: .declinedHard)
        _ = contact(ctx, on: p, email: "next@b.com", sendState: .pending, resolution: nil)

        let result = ShowOutcomeBackfill.run(in: ctx)

        #expect(p.showOutcome == nil)
        #expect(result.leftOpen == 1)
    }

    // A legacy row can be pitched AND carry a never-pitched reason, because the two used to be
    // recorded independently. The backfill keeps what was actually recorded rather than reclassifying
    // it to fit the menu split: the split governs what Dan is OFFERED next, not what history says.
    @Test func aPitchedShowKeepsALegacyNeverPitchedReason() throws {
        let ctx = try context()
        let p = show(ctx, status: .dismissed)
        p.sentAt = Date()
        p.dismissReasonRaw = "date_conflict"

        _ = ShowOutcomeBackfill.run(in: ctx)

        #expect(p.showOutcome == .dateConflict)
    }

    // MARK: the backfill's own honesty

    @Test func itNeverOverwritesAnOutcomeAlreadyRecorded() throws {
        let ctx = try context()
        let p = show(ctx, status: .dismissed)
        p.showOutcome = .turnedThemDown
        p.dismissReasonRaw = "date_conflict"   // stale legacy value

        let result = ShowOutcomeBackfill.run(in: ctx)

        #expect(p.showOutcome == .turnedThemDown)
        #expect(result.filled == 0)
    }

    @Test func itIsIdempotent() throws {
        let ctx = try context()
        let p = show(ctx, status: .dismissed)
        p.dismissReasonRaw = "already_booked"

        let first = ShowOutcomeBackfill.run(in: ctx)
        let second = ShowOutcomeBackfill.run(in: ctx)

        #expect(first.filled == 1)
        #expect(second.filled == 0)
        #expect(p.showOutcome == .hadPaidWork)
    }

    // An unrecognised legacy value is reported, never guessed. A backfill that quietly picked the
    // nearest value would file a show under an ending nobody chose, and the row would be
    // indistinguishable from one Dan closed himself.
    @Test func anUnrecognisedLegacyReasonIsCountedAndLeftAlone() throws {
        let ctx = try context()
        let p = show(ctx, status: .dismissed)
        p.dismissReasonRaw = "some_reason_that_never_existed"

        let result = ShowOutcomeBackfill.run(in: ctx)

        #expect(p.showOutcome == nil)
        #expect(result.filled == 0)
        #expect(result.unrecognised == 1)
    }
}
