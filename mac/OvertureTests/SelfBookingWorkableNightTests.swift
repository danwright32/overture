import Testing
import Foundation

// #1699 part 3. Two committed shows on one night stop being a double-booking warning ONLY when the
// published curtain times prove Dan can work both: he set the workable gap at 5 hours (2026-08-03).
//
// The rule can only ever quiet a warning it can PROVE is safe. Both sides must have published a time for
// that night, every stated time must parse, and every pairing across the two must clear the gap. A show
// nobody published a time for, a time that does not read, and a double bill where either performance
// collides all stay a clash, because "nobody said" and "they are far apart" are different facts and only
// one of them is about the night.
@Suite("Workable same night (#1699)")
struct SelfBookingWorkableNightTests {
    private func show(_ key: String, at times: [String], commitment: Bool = true,
                      name: String = "Show", date: String? = "2026-08-06") -> SelfBookingConflict.Show {
        SelfBookingConflict.Show(key: key, date: date, isCommitment: commitment,
                                 engagementKey: nil, name: name, startTimes: times)
    }

    @Test func curtainsFurtherApartThanTheGapAreNotAClash() {
        let target = show("b", at: ["20:00"], commitment: false)
        let other = show("a", at: ["14:00"], name: "Orchestra A")
        #expect(SelfBookingConflict.conflicts(for: target, among: [other, target]).isEmpty)
        #expect(SelfBookingConflict.workable(for: target, among: [other, target]).map(\.name)
                == ["Orchestra A"])
    }

    // The gap Dan named is inclusive: exactly 5 hours is a night he can work twice.
    @Test func exactlyTheGapIsWorkable() {
        let target = show("b", at: ["19:00"], commitment: false)
        let other = show("a", at: ["14:00"])
        #expect(SelfBookingConflict.conflicts(for: target, among: [other, target]).isEmpty)
    }

    @Test func oneMinuteInsideTheGapStaysAClash() {
        let target = show("b", at: ["18:59"], commitment: false)
        let other = show("a", at: ["14:00"], name: "Orchestra A")
        #expect(SelfBookingConflict.conflicts(for: target, among: [other, target]).map(\.name)
                == ["Orchestra A"])
        #expect(SelfBookingConflict.workable(for: target, among: [other, target]).isEmpty)
    }

    // The MAJORITY state: most sources publish only a day. An unknown time can never clear the night.
    @Test func aShowNobodyPublishedATimeForStaysAClash() {
        let target = show("b", at: [], commitment: false)
        let other = show("a", at: ["14:00"], name: "Orchestra A")
        #expect(SelfBookingConflict.conflicts(for: target, among: [other, target]).map(\.name)
                == ["Orchestra A"])

        // ...and the other way round: the target's own time alone proves nothing about the other show.
        let timed = show("b", at: ["20:00"], commitment: false)
        let untimed = show("a", at: [], name: "Orchestra A")
        #expect(SelfBookingConflict.conflicts(for: timed, among: [untimed, timed]).map(\.name)
                == ["Orchestra A"])
    }

    // A time that does not read is not a measurement, so it lands on the fail-safe side (L50) rather
    // than being dropped, which would leave the surviving time looking like the whole schedule.
    @Test func anUnreadableTimeStaysAClash() {
        let target = show("b", at: ["20:00"], commitment: false)
        let other = show("a", at: ["2pm"], name: "Orchestra A")
        #expect(SelfBookingConflict.conflicts(for: target, among: [other, target]).map(\.name)
                == ["Orchestra A"])
    }

    // #1984: a production really can play twice on one day. The night is workable only if EVERY
    // performance clears the gap; the far one must not excuse the near one.
    @Test func aDoubleBillCollidingOnEitherPerformanceStaysAClash() {
        let target = show("b", at: ["20:00"], commitment: false)
        let other = show("a", at: ["11:00", "19:00"], name: "Orchestra A")
        #expect(SelfBookingConflict.conflicts(for: target, among: [other, target]).map(\.name)
                == ["Orchestra A"])
    }

    @Test func aDoubleBillThatClearsTheGapTwiceIsWorkable() {
        let target = show("b", at: ["20:00"], commitment: false)
        let other = show("a", at: ["09:00", "11:00"], name: "Orchestra A")
        #expect(SelfBookingConflict.conflicts(for: target, among: [other, target]).isEmpty)
        #expect(SelfBookingConflict.workable(for: target, among: [other, target]).map(\.name)
                == ["Orchestra A"])
    }

    // Three shows on one night split correctly: the tight one still warns, the far one does not, and
    // both lists come off the same same-night predicate so they can never disagree about the set.
    @Test func aNightHoldingBothSortsThemApart() {
        let target = show("c", at: ["20:00"], commitment: false)
        let tight = show("a", at: ["18:00"], name: "Choir B")
        let far = show("b", at: ["13:00"], name: "Orchestra A")
        let all = [tight, far, target]
        #expect(SelfBookingConflict.conflicts(for: target, among: all).map(\.name) == ["Choir B"])
        #expect(SelfBookingConflict.workable(for: target, among: all).map(\.name) == ["Orchestra A"])
    }

    // The time never widens the net: a non-commitment, a different date and the same linked production
    // are excluded before curtain times are looked at, exactly as they were.
    @Test func theTimeOnlyEverNarrowsTheExistingRule() {
        let target = show("b", at: ["20:00"], commitment: false)
        let notCommitted = show("a", at: ["14:00"], commitment: false)
        #expect(SelfBookingConflict.workable(for: target, among: [notCommitted, target]).isEmpty)

        let otherNight = show("a", at: ["14:00"], date: "2026-08-07")
        #expect(SelfBookingConflict.workable(for: target, among: [otherNight, target]).isEmpty)
    }

    // The gap Dan chose, stated once so the tests and the rule cannot drift.
    @Test func theWorkableGapIsFiveHours() {
        #expect(SelfBookingConflict.workableGapMinutes == 300)
    }
}

@Suite("Workable same night copy (#1699)")
struct SelfBookingWorkableCopyTests {
    private func show(_ key: String, at times: [String], name: String = "Show")
        -> SelfBookingConflict.Show {
        SelfBookingConflict.Show(key: key, date: "2026-08-06", isCommitment: true,
                                 engagementKey: nil, name: name, startTimes: times)
    }

    // Dan's pick from the rendered options (2026-08-03): the note names the other show's curtain and how
    // much room the night leaves, so he can see the gap without doing the arithmetic between two times.
    @Test func theNoteNamesTheCurtainAndTheGap() {
        let target = show("b", at: ["20:00"])
        let other = show("a", at: ["14:00"], name: "Orchestra A")
        #expect(SelfBookingCopy.workableRowMarker(target: target, others: [other])
                == "Also pitching Orchestra A at 2:00 PM, 6 hours before this one")
    }

    @Test func aLaterShowReadsAsAfterThisOne() {
        let target = show("b", at: ["14:00"])
        let other = show("a", at: ["20:00"], name: "Orchestra A")
        #expect(SelfBookingCopy.workableRowMarker(target: target, others: [other])
                == "Also pitching Orchestra A at 8:00 PM, 6 hours after this one")
    }

    // The gap is floored, never rounded up: the sentence may only claim room it actually measured.
    @Test func thePartHourIsDroppedRatherThanRoundedUp() {
        let target = show("b", at: ["20:45"])
        let other = show("a", at: ["14:00"], name: "Orchestra A")
        #expect(SelfBookingCopy.workableRowMarker(target: target, others: [other])
                == "Also pitching Orchestra A at 2:00 PM, 6 hours before this one")
    }

    // A double bill names both curtains, for the same reason the card does: stating one would read as
    // the day's only performance.
    @Test func aDoubleBillNamesBothCurtains() {
        let target = show("b", at: ["20:00"])
        let other = show("a", at: ["09:00", "11:00"], name: "Orchestra A")
        #expect(SelfBookingCopy.workableRowMarker(target: target, others: [other])
                == "Also pitching Orchestra A at 9:00 AM and 11:00 AM, 9 hours before this one")
    }

    // Several workable shows on one night cannot share one gap, so the sentence drops the clause rather
    // than stating a number true of only the first. Same "X and N others" shape the warning already uses.
    @Test func severalShowsCountRatherThanClaimOneGap() {
        let target = show("c", at: ["20:00"])
        let a = show("a", at: ["09:00"], name: "Orchestra A")
        let b = show("b", at: ["11:00"], name: "Choir B")
        #expect(SelfBookingCopy.workableRowMarker(target: target, others: [a, b])
                == "Also pitching Orchestra A at 9:00 AM and 1 other")
    }

    @Test func nothingWorkableSaysNothing() {
        #expect(SelfBookingCopy.workableRowMarker(target: show("b", at: ["20:00"]), others: []) == nil)
    }

    // A blank name never leaves a hole, matching the warning marker's own handling.
    @Test func aBlankNameReadsAsAnotherShow() {
        let target = show("b", at: ["20:00"])
        let other = show("a", at: ["14:00"], name: "  ")
        #expect(SelfBookingCopy.workableRowMarker(target: target, others: [other])
                == "Also pitching another show at 2:00 PM, 6 hours before this one")
    }
}

// The rule above is only real if the queue actually hands it the times. A pure-rule test alone would
// pass forever with the field defaulted and never written, which is the shape of defect where a guard
// looks wired and reads nothing (the #1699 field itself is the thing that could sit unread).
@Suite("Workable same night reaches the queue (#1699)")
struct SelfBookingWorkableWiringTests {
    private func row(_ key: String, name: String, times: [String] = [],
                     nightTimes: [String] = [], vary: Bool = false, sent: Bool = false) -> QueueItem {
        var q = QueueItem(
            id: key, groupName: name, discipline: "music", venue: "Weill Recital Hall",
            performanceDate: "2026-08-06", sourceListingURL: nil,
            priorRelationship: "none", production: "unknown", profile: "neutral",
            coverage: "unknown", fitScore: 3, tier: "longshot", fitReason: "reason",
            matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil, status: .new
        )
        q.performanceStartTimes = times
        q.nightStartTimes = nightTimes
        q.startTimesVary = vary
        if sent { q.sentAt = Date() }
        return q
    }

    @Test func aPairApartOnTheClockGoesQuietAndKeepsAPlainNote() {
        let target = row("b", name: "Brooklyn Chamber Players", times: ["20:00"])
        let other = row("a", name: "Orchestra A", times: ["14:00"], sent: true)
        let all = [other, target]
        #expect(QueueModel.selfBookingConflicts(for: target, among: all).isEmpty)
        #expect(QueueModel.selfBookingWorkableNote(for: target, among: all)
                == "Also pitching Orchestra A at 2:00 PM, 6 hours before this one")
    }

    @Test func aTightPairStillWarnsAndShowsNoPlainNote() {
        let target = row("b", name: "Brooklyn Chamber Players", times: ["20:00"])
        let other = row("a", name: "Orchestra A", times: ["18:00"], sent: true)
        let all = [other, target]
        #expect(QueueModel.selfBookingConflictNames(for: target, among: all) == ["Orchestra A"])
        #expect(QueueModel.selfBookingWorkableNote(for: target, among: all) == nil)
    }

    // A run whose nights differ states no single time on its card, but the night being compared has its
    // own published schedule, already stored for the hover. That night is what the clash check reads.
    @Test func aVaryingRunReadsTheComparedNightsOwnTimes() {
        let target = row("b", name: "Brooklyn Chamber Players",
                         nightTimes: ["2026-08-06 14:00", "2026-08-07 19:00"], vary: true)
        let other = row("a", name: "Orchestra A", times: ["20:00"], sent: true)
        #expect(QueueModel.selfBookingConflicts(for: target, among: [other, target]).isEmpty)
    }

    @Test func aVaryingRunSilentAboutThisNightStaysAClash() {
        let target = row("b", name: "Brooklyn Chamber Players",
                         nightTimes: ["2026-08-07 19:00"], vary: true)
        let other = row("a", name: "Orchestra A", times: ["20:00"], sent: true)
        #expect(QueueModel.selfBookingConflictNames(for: target, among: [other, target])
                == ["Orchestra A"])
    }

    // A night holding one tight show and one workable one is a night that needs the warning, so the
    // actionable line wins and the plain note stands down rather than stacking a second line beside it.
    @Test func theWarningWinsWhenTheNightHoldsBoth() {
        let target = row("c", name: "Brooklyn Chamber Players", times: ["20:00"])
        let tight = row("a", name: "Choir B", times: ["18:00"], sent: true)
        let far = row("b", name: "Orchestra A", times: ["13:00"], sent: true)
        let all = [tight, far, target]
        #expect(QueueModel.selfBookingConflictNames(for: target, among: all) == ["Choir B"])
        #expect(QueueModel.selfBookingWorkableNote(for: target, among: all) == nil)
    }
}
