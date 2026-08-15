import Testing
import Foundation
import SwiftData

// #2691: dismissing ONE night of a multi-night run must not throw away every other night.
//
// Found live 2026-08-13: `Rachel Sandler's Singer Showcase` at The Green Room 42 is one row whose
// `runNights` are 2026-08-19, 2026-09-30 and 2026-10-21. Aug 19 is blocked, so the card carries the
// Unavailable badge; Dan wants Sep 30 or Oct 21 and cannot say so. Dismissing archives all three, and
// the dismissal then follows the show forward, because when Aug 19 leaves the feed
// `ScoutService.matchByAnyRunURL` re-keys the stored dismissed row onto Sep 30 deliberately, so the
// show never comes back at all.
//
// The REASON decides the scope. Four of the seven reasons on the menu are statements about one night.
//
// Every test injects `now` (L130).
@MainActor
@Suite("Dropping one night of a run (#2691)")
struct RunNightDropTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, Inquiry.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private let now = Date(timeIntervalSince1970: 1_786_000_000)

    // The live row this issue was found on.
    private func sandler(_ ctx: ModelContext) -> Prospect {
        let p = Prospect(naturalKey: Prospect.makeNaturalKey(groupName: "Rachel Sandler's Singer Showcase",
                                                             performanceDate: "2026-08-19",
                                                             venue: "The Green Room 42"),
                         groupName: "Rachel Sandler's Singer Showcase", discipline: "music",
                         venue: "The Green Room 42", performanceDate: "2026-08-19",
                         sourceListingURL: nil, websiteURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 7, tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil)
        p.runEndDate = "2026-10-21"
        p.runNights = ["2026-08-19", "2026-09-30", "2026-10-21"]
        ctx.insert(p)
        return p
    }

    // MARK: which reasons are about one night

    // Dan's rule, in his words, 2026-08-13. All seven items on the card's Dismiss menu are covered, so
    // a reason cannot fall between the two halves and get whichever behaviour the code happens to
    // reach.
    @Test("the four reasons that are statements about one night drop only that night")
    func theFourNightReasons() {
        for reason in [ShowOutcome.dateConflict, .hadPaidWork, .pitchingOtherShows, .tooSoon] {
            #expect(RunNightDrop.isAboutOneNight(reason), "\(reason.label) is about one night")
        }
    }

    // FOUR, not the three the issue lists. It says `noWayToReachThem` is applied by the app rather than
    // offered on this menu; the card renders `ShowOutcome.menu(wasPitched:)`, which for an unpitched show
    // includes it, so Dan can choose it and it needed a scope. The completeness check below is what
    // caught that, which is why it is derived from the menu rather than copied from the issue (L96).
    @Test("the reasons that are statements about the show take the whole run")
    func theShowReasons() {
        for reason in [ShowOutcome.notAFit, .dontWantToShoot, .duplicate, .noWayToReachThem] {
            #expect(RunNightDrop.isAboutOneNight(reason) == false, "\(reason.label) is about the show")
        }
    }

    // The menu is the whole vocabulary this rule has to answer for. Derived from `ShowOutcome` rather
    // than listed again here, so a reason added to the menu later cannot quietly get no answer (L96).
    @Test("every reason on the card's menu has an answer")
    func everyMenuReasonIsClassified() {
        for reason in ShowOutcome.menu(wasPitched: false) {
            // The assertion is that asking is meaningful, not that the answer is a particular one: the
            // two tests above pin the answers. This one fails if the menu grows a reason nobody decided.
            #expect(RunNightDrop.classified.contains(reason),
                    "\(reason.label) is on the Dismiss menu and nobody decided its scope")
        }
    }

    // MARK: the drop itself

    @Test("dropping the opening night moves the card to the next night")
    func droppingTheOpeningNightMovesTheCard() throws {
        let ctx = ModelContext(try container())
        let p = sandler(ctx)

        let outcome = p.dropNight("2026-08-19", reason: .dateConflict, now: now)

        #expect(outcome == .moved(to: "2026-09-30"))
        #expect(p.performanceDate == "2026-09-30")
        #expect(p.runEndDate == "2026-10-21")
        #expect(p.runNights == ["2026-09-30", "2026-10-21"])
    }

    // "The card should essentially disappear because I dismissed it. The catch is that it should
    // reappear in the next night of the run." The queue groups on `performanceDate`, so moving that IS
    // the card leaving the Aug 19 group and turning up under Sep 30.
    @Test("the card stays untriaged and in the queue, it does not go to Archive")
    func theCardStaysInTheQueue() throws {
        let ctx = ModelContext(try container())
        let p = sandler(ctx)

        _ = p.dropNight("2026-08-19", reason: .dateConflict, now: now)

        #expect(p.status != .dismissed)
        #expect(p.dismissedAt == nil)
    }

    // A per-night drop is NOT the show being cut. `markDismissed` stamps `dismissedAt` and
    // `showOutcomeRaw`, which is what #16's funnel reads to say a show was cut, and stamping it would
    // report a show as dismissed while it sits in the queue: zero is indistinguishable from a real
    // measurement (L90).
    @Test("a dropped night is not recorded as the show leaving the queue")
    func aDroppedNightIsNotAnExit() throws {
        let ctx = ModelContext(try container())
        let p = sandler(ctx)

        _ = p.dropNight("2026-08-19", reason: .pitchingOtherShows, now: now)

        #expect(p.showOutcomeRaw == nil, "the show has not ended, so it has no outcome")
        #expect(p.dismissedAt == nil)
    }

    // The natural key IS the opening night, so dropping it changes the key. ONE card, re-keyed in place
    // and keeping its history, never a second card beside the old one.
    @Test("the row is re-keyed in place to its new opening night")
    func theRowIsRekeyedInPlace() throws {
        let ctx = ModelContext(try container())
        let p = sandler(ctx)
        let before = p.naturalKey

        _ = p.dropNight("2026-08-19", reason: .dateConflict, now: now)

        #expect(p.naturalKey != before)
        #expect(p.naturalKey == Prospect.makeNaturalKey(groupName: "Rachel Sandler's Singer Showcase",
                                                        performanceDate: "2026-09-30",
                                                        venue: "The Green Room 42"))
        #expect((try ctx.fetch(FetchDescriptor<Prospect>())).count == 1, "one card, not two")
    }

    // MARK: the drop has to survive the next scout

    // `runNights` is rebuilt from the venue's feed on every run and the feed still lists Aug 19, so a
    // drop that is not PERSISTED lasts until the next scout and then quietly undoes itself. Same shape
    // as L92: a removal recorded against nothing recurs.
    @Test("a dropped night is remembered, with its reason and when")
    func aDroppedNightIsRemembered() throws {
        let ctx = ModelContext(try container())
        let p = sandler(ctx)

        _ = p.dropNight("2026-08-19", reason: .hadPaidWork, now: now)

        let dropped = DroppedNight.all(on: p)
        #expect(dropped.count == 1)
        #expect(dropped.first?.night == "2026-08-19")
        #expect(dropped.first?.reason == .hadPaidWork)
        #expect(dropped.first?.at == now)
    }

    @Test("re-folding the run from the feed does not put a dropped night back")
    func theScoutDoesNotPutItBack() throws {
        let ctx = ModelContext(try container())
        let p = sandler(ctx)
        _ = p.dropNight("2026-08-19", reason: .dateConflict, now: now)

        // What the next scout hands back: the feed still lists all three nights.
        let refolded = DroppedNight.keeping(["2026-08-19", "2026-09-30", "2026-10-21"], on: p)

        #expect(refolded == ["2026-09-30", "2026-10-21"])
    }

    @Test("a night that was never dropped survives a re-fold")
    func anUndroppedNightSurvives() throws {
        let ctx = ModelContext(try container())
        let p = sandler(ctx)

        #expect(DroppedNight.keeping(["2026-08-19", "2026-09-30"], on: p) == ["2026-08-19", "2026-09-30"])
    }

    // MARK: the clash badge

    // `BlockedCalendar.conflict` reports the earliest blocked night of the run. Once Aug 19 is dropped
    // the card should stop showing Unavailable at all, because Sep 30 and Oct 21 are clear. If the badge
    // survives the drop, the drop did not reach `conflictKey`.
    @Test("dropping the blocked night clears the clash")
    func droppingTheBlockedNightClearsTheClash() throws {
        let ctx = ModelContext(try container())
        let p = sandler(ctx)
        // The live block: Dan's own day off on Aug 19, named Empire Harmony Rehearsal.
        let calendar = BlockedCalendar.build(
            bookings: [], exportedBlockedDates: [],
            daysOff: [DayOffRange(startDate: "2026-08-19", endDate: "2026-08-19",
                                  note: "Empire Harmony Rehearsal")])
        p.setScoutConflict(calendar.conflict(performanceDate: p.performanceDate,
                                             runEndDate: p.runEndDate, nights: p.runNights)?.key)
        #expect(p.conflictOpen, "the live card really does carry the badge")

        _ = p.dropNight("2026-08-19", reason: .dateConflict, now: now)
        p.setScoutConflict(calendar.conflict(performanceDate: p.performanceDate,
                                             runEndDate: p.runEndDate, nights: p.runNights)?.key)

        #expect(p.conflictOpen == false)
        #expect(p.conflictKey == nil)
    }

    // MARK: the last remaining night

    // When the dropped night is the only one left there is no run to move to, so it becomes an ordinary
    // whole-show dismissal carrying that reason and the card goes to Archive as it does today.
    @Test("dropping the last remaining night is an ordinary dismissal")
    func droppingTheLastNightIsADismissal() throws {
        let ctx = ModelContext(try container())
        let p = sandler(ctx)
        _ = p.dropNight("2026-08-19", reason: .dateConflict, now: now)
        _ = p.dropNight("2026-09-30", reason: .dateConflict, now: now)

        let outcome = p.dropNight("2026-10-21", reason: .dateConflict, now: now)

        #expect(outcome == .wholeShow)
        #expect(p.performanceDate == "2026-10-21", "the last night is still what the card is about")
    }

    @Test("a single-night show is never a per-night drop")
    func aSingleNightShowIsAlwaysAWholeShow() throws {
        let ctx = ModelContext(try container())
        let p = sandler(ctx)
        p.runNights = ["2026-08-19"]
        p.runEndDate = nil

        #expect(p.dropNight("2026-08-19", reason: .dateConflict, now: now) == .wholeShow)
    }

    // A row stored before `runNights` existed carries an empty list, and the SPAN is all there is. It
    // must not be treated as a run whose nights can be picked off one at a time, because nobody knows
    // which nights those are: `BlockedCalendar.conflict` already reads an empty list as "fall back to
    // the span" for the same reason.
    @Test("a run with no recorded nights is dismissed whole rather than guessed at")
    func aRunWithNoRecordedNightsIsNotPickedApart() throws {
        let ctx = ModelContext(try container())
        let p = sandler(ctx)
        p.runNights = []

        #expect(p.dropNight("2026-08-19", reason: .dateConflict, now: now) == .wholeShow)
    }

    // MARK: putting it back

    @Test("undoing a drop puts the night back and restores the key")
    func undoingADropPutsTheNightBack() throws {
        let ctx = ModelContext(try container())
        let p = sandler(ctx)
        let key = p.naturalKey
        _ = p.dropNight("2026-08-19", reason: .dateConflict, now: now)

        p.restoreNight("2026-08-19")

        #expect(p.runNights == ["2026-08-19", "2026-09-30", "2026-10-21"])
        #expect(p.performanceDate == "2026-08-19")
        #expect(p.naturalKey == key)
        #expect(DroppedNight.all(on: p).isEmpty)
    }

    @Test("dropping the same night twice drops it once")
    func droppingTwiceDropsOnce() throws {
        let ctx = ModelContext(try container())
        let p = sandler(ctx)
        _ = p.dropNight("2026-08-19", reason: .dateConflict, now: now)

        let second = p.dropNight("2026-08-19", reason: .dateConflict, now: now.addingTimeInterval(60))

        #expect(second == .alreadyDropped)
        #expect(p.runNights == ["2026-09-30", "2026-10-21"])
        #expect(DroppedNight.all(on: p).count == 1)
    }
}
