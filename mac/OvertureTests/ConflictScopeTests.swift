import Testing
import Foundation

// #1501: the conflict line was TRUE and READ FALSE.
//
// Dan saw, under a `FRI Jul 24 2026` header, a Shifters card (Cherry Lane, Jul 24 to 31) carrying
// `Unavailable` and "You're already shooting The One-Man Odyssey on Jul 31.", while the two Jul 24 to 25
// shows beside it said nothing. He read that as a missing flag on the other cards.
//
// Nothing was missing. Jul 31 is a night INSIDE Shifters' eight-night run, and it is the only blocked day
// in July 2026, so the two shows that close on Jul 25 never reach it and are correctly quiet. But the
// sentence sits under a Jul 24 header with nothing saying the clash is on a later night, so the eye binds
// it to Jul 24 and the neighbours look broken. `Unavailable` overstated it too: Dan is free on Jul 24, and
// a run bookable on seven of its eight nights is not unavailable.
//
// The literal ask (copy the line onto every card in the group) would have put a Jul 31 warning on shows
// that close on Jul 25, which is a false statement about his calendar.
@Suite("Whether a conflict is tonight or a later night of the run (#1501)")
struct ConflictScopeTests {

    private func booked(_ date: String, _ name: String?) -> BlockedCalendar.Day {
        BlockedCalendar.Day(date: date, kind: .bookedShoot, name: name)
    }

    // MARK: which case is it

    // A one-night show, or a run whose OPENING night is the blocked one: the clash is on the date the card
    // is filed under, and the sentence Dan has always read is correct as it stands.
    @Test func aClashOnTheShowsOwnNightIsThisNight() {
        #expect(ConflictScope.of(blockedDate: "2026-07-24", performanceDate: "2026-07-24") == .thisNight)
    }

    // THE case. The blocked night is inside the run, later than the date the card groups under.
    @Test func aClashLaterInTheRunIsNotThisNight() {
        #expect(ConflictScope.of(blockedDate: "2026-07-31", performanceDate: "2026-07-24") == .laterInTheRun)
    }

    // No conflict, nothing to scope. Nil rather than a made-up case, so a caller cannot render a pill for
    // a show with nothing wrong.
    @Test func nothingBlockedHasNoScope() {
        #expect(ConflictScope.of(blockedDate: nil, performanceDate: "2026-07-24") == nil)
        #expect(ConflictScope.of(blockedDate: "2026-07-31", performanceDate: nil) == nil)
    }

    // MARK: the sentence

    // Unchanged for the case it was written for, which is most shows. The existing wording is not touched.
    @Test func aClashTonightReadsExactlyAsItAlwaysHas() {
        let day = booked("2026-07-24", "The One-Man Odyssey")

        #expect(day.reason(scope: .thisNight) == "You're already shooting The One-Man Odyssey on Jul 24.")
        #expect(day.reason(scope: .thisNight) == day.reason)      // and the plain property still agrees
    }

    // THE fix. It leads with the fact the card was missing, because that is what stops the eye binding the
    // date to the group header above it.
    @Test func aClashLaterInTheRunSaysSoBeforeNamingTheNight() {
        let day = booked("2026-07-31", "The One-Man Odyssey")

        #expect(day.reason(scope: .laterInTheRun)
                == "A later night of this run is out: you're already shooting The One-Man Odyssey on Jul 31.")
    }

    // Deliberately "a later night" and not "one night". The stored conflict key holds ONE day (the earliest
    // blocked night, BlockedCalendar.conflict uses `.min`), so Overture does not know whether one night of
    // the run is out or three. "One night" would be a false statement about his calendar the first time two
    // nights of a run were booked, which is the same class of error as the literal ask this issue rejected.
    // "A later night" is true either way.
    @Test func theSentenceNeverClaimsHowManyNightsAreOut() {
        let line = booked("2026-07-31", "The One-Man Odyssey").reason(scope: .laterInTheRun)

        #expect(!line.contains("One night"))
        #expect(!line.contains("one night"))
    }

    // A day off reads the same way, and an unnamed block too: all four sentences share one clause, so the
    // two frames can never drift apart.
    @Test func everyKindOfBlockReadsCorrectlyInBothFrames() {
        let dayOff = BlockedCalendar.Day(date: "2026-07-31", kind: .dayOff, name: "Vacation")
        #expect(dayOff.reason(scope: .thisNight) == "You blocked Jul 31 (Vacation).")
        #expect(dayOff.reason(scope: .laterInTheRun)
                == "A later night of this run is out: you blocked Jul 31 (Vacation).")

        let unnamed = booked("2026-07-31", nil)
        #expect(unnamed.reason(scope: .thisNight) == "You're already shooting on Jul 31.")
        #expect(unnamed.reason(scope: .laterInTheRun)
                == "A later night of this run is out: you're already shooting on Jul 31.")

        let unnamedOff = BlockedCalendar.Day(date: "2026-07-31", kind: .dayOff, name: nil)
        #expect(unnamedOff.reason(scope: .thisNight) == "You blocked Jul 31.")
        #expect(unnamedOff.reason(scope: .laterInTheRun)
                == "A later night of this run is out: you blocked Jul 31.")
    }

    // MARK: the colour

    // #1583 retired the pill (Keep is the acceptance now, so the badge had no job left), and the sentence
    // beneath it survives. What survives with it is the two-case decision about how loud a clash looks: a
    // show Dan genuinely cannot make keeps the failure colour, a run he can still book around does not.
    @Test func aRunWithOneBlockedNightIsNotDrawnAsLoudlyAsAShowHeCannotMake() {
        #expect(ConflictScope.thisNight.noteTint != ConflictScope.laterInTheRun.noteTint)
    }

    // MARK: the header and the sentence are ONE decision

    // #929 already ruled that a date-group header only claims "Unavailable" when the blocked night IS that
    // date. That was a second copy of this question, written as a field comparison. It now asks the shared
    // rule, so the three things Dan reads at once cannot describe different cases: the Shifters card shows a
    // partly-booked run with a Jul 31 sentence, under a Jul 24 header that stays plain.
    @Test func theHeaderAndTheSentenceAgreeBecauseTheyAskOneRule() {
        let shifters = item(performance: "2026-07-24", blocked: "2026-07-31")
        let oneNighter = item(performance: "2026-07-24", blocked: "2026-07-24")

        #expect(QueueModel.conflictScope(shifters) == .laterInTheRun)
        #expect(QueueModel.groupIsUnavailable([shifters]) == false)   // Jul 24 itself is free

        #expect(QueueModel.conflictScope(oneNighter) == .thisNight)
        #expect(QueueModel.groupIsUnavailable([oneNighter]))
    }

    // The exact group Dan was looking at: one eight-night run flagged for a later night, beside two shows
    // that close before it. The header stays plain, and only the run carries a pill.
    @Test func dansJul24GroupReadsCorrectlyEndToEnd() {
        let shifters = item(performance: "2026-07-24", blocked: "2026-07-31")   // Jul 24 to 31
        let wisard = item(performance: "2026-07-24", blocked: nil)              // Jul 24 to 25
        let cardboard = item(performance: "2026-07-24", blocked: nil)           // Jul 24 to 25
        let group = [shifters, wisard, cardboard]

        #expect(QueueModel.groupIsUnavailable(group) == false)
        #expect(group.filter { $0.hasUnclearedConflict }.count == 1)
        #expect(QueueModel.conflictScope(wisard) == nil)
        #expect(QueueModel.conflictScope(cardboard) == nil)
    }

    private func item(performance: String, blocked: String?) -> QueueItem {
        var i = QueueItem(id: "k-\(performance)-\(blocked ?? "free")", groupName: "Show",
                          discipline: "theater", venue: "Theatre",
                          performanceDate: performance, sourceListingURL: nil, websiteURL: nil,
                          priorRelationship: "none", production: "self", profile: "neutral",
                          coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                          matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                          status: .new)
        i.conflictBlockedDate = blocked
        i.hasUnclearedConflict = blocked != nil
        return i
    }
}
