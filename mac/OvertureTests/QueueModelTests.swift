import Testing
import Foundation
@testable import Overture

private func item(
    discipline: String = "music",
    venue: String? = "Weill Recital Hall",
    performanceDate: String? = "2026-07-01",
    priorRelationship: String = "none",
    production: String = "unknown",
    coverage: String = "unknown",
    fitScore: Int = 3,
    tier: String = "longshot",
    matchedClientName: String? = nil,
    possibleMatchSource: String? = nil,
    possibleMatchName: String? = nil,
    partOfRelatedRun: Bool = false,
    status: ReviewStatus = .new,
    key: String = "k"
) -> QueueItem {
    var q = QueueItem(
        id: key, groupName: "Test Group", discipline: discipline, venue: venue,
        performanceDate: performanceDate, sourceListingURL: nil, websiteURL: nil,
        priorRelationship: priorRelationship, production: production, profile: "neutral",
        coverage: coverage, fitScore: fitScore, tier: tier, fitReason: "reason",
        matchedClientName: matchedClientName, possibleMatchSource: possibleMatchSource,
        possibleMatchName: possibleMatchName, status: status
    )
    q.partOfRelatedRun = partOfRelatedRun
    return q
}

@Suite("Queue item lifecycle")
struct QueueItemLifecycleTests {
    // #200: a contacted (sent) prospect stays "kept" so it remains visible in the queue,
    // just like the approved-and-sent rows did before the explicit state existed.
    // #217: the to-send queue drops anyone already in the reached-out pipeline, so the two
    // never show the same prospect.
    @Test func toSendQueueExcludesReachedOutProspects() {
        let a = item(performanceDate: nil, key: "a")
        let b = item(performanceDate: nil, key: "b")
        let result = QueueModel.toSendQueue([a, b], reachedOutKeys: ["b"], today: "2026-06-01")
        #expect(result.map(\.id) == ["a"])
    }

    // #219: an auto-detected Gmail reply is flagged so Dan can dismiss it; a hand-set reply is not.
    @MainActor
    @Test func isAutoRepliedOnlyForAutoDetectedReplies() {
        let p = Prospect(naturalKey: "k", groupName: "G", discipline: "music", venue: "V",
                         performanceDate: nil, sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "neutral",
                         coverage: "unknown", fitScore: 3, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        p.outcome = .replied
        p.outcomeSourceRaw = OutcomeSource.auto.rawValue
        #expect(QueueItem(p).isAutoReplied)
        p.outcomeSourceRaw = OutcomeSource.manual.rawValue
        #expect(QueueItem(p).isAutoReplied == false)   // Dan set it by hand: not dismissable as auto
        p.outcome = .booked
        p.outcomeSourceRaw = OutcomeSource.auto.rawValue
        #expect(QueueItem(p).isAutoReplied == false)   // auto, but a booking, not a reply
    }

    @Test func keptCoversPursuedStatesThroughContacted() {
        #expect(item(status: .queued).isKept)
        #expect(item(status: .drafted).isKept)
        #expect(item(status: .approved).isKept)
        #expect(item(status: .contacted).isKept)
        #expect(item(status: .new).isKept == false)
        #expect(item(status: .dismissed).isKept == false)
    }
}

@Suite("Queue label helpers")
struct QueueLabelTests {
    @Test func disciplineFallsBackToPerformance() {
        #expect(QueueModel.disciplineLabel("dance") == "Dance")
        #expect(QueueModel.disciplineLabel("other") == "Performance")
        #expect(QueueModel.disciplineLabel("nonsense") == "Performance")
    }

    @Test func productionBadgeOnlyWithSignal() {
        #expect(QueueModel.productionLabel("self") == "Self-produced")
        #expect(QueueModel.productionLabel("agency") == "Agency-routed")
        #expect(QueueModel.productionLabel("unknown") == nil)
    }

    @Test func coverageBadgeOnlyWithSignal() {
        #expect(QueueModel.coverageLabel("likely_uncovered") == "Likely uncovered")
        #expect(QueueModel.coverageLabel("likely_covered") == "Likely covered")
        #expect(QueueModel.coverageLabel("unknown") == nil)
    }
}

@Suite("History flag")
struct HistoryFlagTests {
    @Test func bookedStatedPlainlyWithName() {
        let flag = QueueModel.historyFlag(item(priorRelationship: "booked", matchedClientName: "DCINY"))
        #expect(flag == "Worked together before (DCINY)")
    }

    @Test func contactedNoted() {
        #expect(QueueModel.historyFlag(item(priorRelationship: "contacted")) == "Cold-contacted before, no booking")
    }

    @Test func declinedByYouNoted() {
        #expect(QueueModel.historyFlag(item(priorRelationship: "declined_by_you")) == "You declined before (usually a date conflict)")
    }

    @Test func warmNoted() {
        #expect(QueueModel.historyFlag(item(priorRelationship: "warm")) == "Warm lead from a prior relationship")
    }

    @Test func lostSoftNoted() {
        #expect(QueueModel.historyFlag(item(priorRelationship: "lost_soft")) == "Lost before, open to the future")
    }

    @Test func lostHardNoted() {
        #expect(QueueModel.historyFlag(item(priorRelationship: "lost_hard")) == "Lost before, not interested")
    }

    @Test func possibleMatchPhrasedAsQuestion() {
        let flag = QueueModel.historyFlag(item(possibleMatchSource: "downbeat_client", possibleMatchName: "Alaria Ensemble"))
        #expect(flag == "Possible match to a past client: Alaria Ensemble?")
    }

    @Test func nilWhenNoSignal() {
        #expect(QueueModel.historyFlag(item()) == nil)
    }
}

@Suite("Lost outcome")
struct LostOutcomeTests {
    @Test func isLostOnlyForLostOutcomes() {
        var soft = item(); soft.outcome = .lostSoft
        var hard = item(); hard.outcome = .lostHard
        var booked = item(); booked.outcome = .booked
        let none = item()
        #expect(soft.isLost)
        #expect(hard.isLost)
        #expect(booked.isLost == false)
        #expect(none.isLost == false)
    }

    @Test func blankLostReasonClearsToNil() {
        #expect(QueueModel.normalizedLostReason("") == nil)
        #expect(QueueModel.normalizedLostReason("   \n ") == nil)
        #expect(QueueModel.normalizedLostReason("  went with staff photographer ") == "went with staff photographer")
    }
}

@Suite("Timing")
struct TimingTests {
    @Test func countsLocalCalendarDays() {
        #expect(QueueModel.daysUntil(performanceDate: "2026-06-25", today: "2026-06-22") == 3)
        #expect(QueueModel.daysUntil(performanceDate: nil, today: "2026-06-22") == nil)
    }

    @Test func flagsPassedPerformance() {
        #expect(QueueModel.outreachTiming(performanceDate: "2026-06-20", today: "2026-06-22").urgency == .past)
    }

    // Within 5 days (72-hours-and-then-some) reads as too close to realistically book.
    @Test func flagsNearTermAsTooClose() {
        let today = QueueModel.outreachTiming(performanceDate: "2026-06-22", today: "2026-06-22")
        #expect(today.urgency == .tooSoon)
        #expect(today.label.contains("today"))
        let threeDays = QueueModel.outreachTiming(performanceDate: "2026-06-25", today: "2026-06-22")
        #expect(threeDays.urgency == .tooSoon)
        #expect(threeDays.label.contains("3 days"))
        let fiveDays = QueueModel.outreachTiming(performanceDate: "2026-06-27", today: "2026-06-22")
        #expect(fiveDays.urgency == .tooSoon)
    }

    @Test func urgesOutreachJustPastTheTooCloseWindow() {
        let t = QueueModel.outreachTiming(performanceDate: "2026-06-28", today: "2026-06-22")
        #expect(t.urgency == .imminent)
        #expect(t.label.contains("6 days"))
    }

    @Test func suggestsThreeWeeksOutForDistant() {
        #expect(QueueModel.outreachTiming(performanceDate: "2026-08-01", today: "2026-06-22").urgency == .ahead)
    }
}

@Suite("Eastern today")
struct EasternTodayTests {
    // 03:00 UTC on the 25th is still 23:00 on the 24th in New York, so "today" is the 24th.
    @Test func usesNewYorkCalendarDayNotUTC() {
        let lateNightEastern = Date(timeIntervalSince1970: 1782356400) // 2026-06-25T03:00:00Z
        #expect(QueueModel.easternToday(lateNightEastern) == "2026-06-24")
    }
}

@Suite("Queue date window")
struct QueueWindowTests {
    private func dated(_ date: String?) -> QueueItem { item(performanceDate: date) }

    @Test func hidesPastPerformances() {
        let result = QueueModel.queueOrder([dated("2026-06-22"), dated("2026-07-10")], today: "2026-06-25")
        #expect(result.map(\.performanceDate) == ["2026-07-10"])
    }

    @Test func hidesEventsBeyondNinetyDays() {
        let result = QueueModel.queueOrder([dated("2026-07-10"), dated("2026-12-01")], today: "2026-06-25")
        #expect(result.map(\.performanceDate) == ["2026-07-10"])
    }

    @Test func keepsEventExactlyNinetyDaysOut() {
        let result = QueueModel.queueOrder([dated("2026-09-23")], today: "2026-06-25")
        #expect(result.count == 1)
    }

    // 0-5 days out stay visible but sink below everything bookable, closest-to-today lowest.
    @Test func demotesNearTermToBottomGradedByCloseness() {
        let result = QueueModel.queueOrder(
            [dated("2026-06-25"), dated("2026-06-27"), dated("2026-07-10")],
            today: "2026-06-25"
        )
        #expect(result.map(\.performanceDate) == ["2026-07-10", "2026-06-27", "2026-06-25"])
    }

    @Test func keepsUndatedAmongBookable() {
        let result = QueueModel.queueOrder([dated(nil), dated("2026-07-10")], today: "2026-06-25")
        #expect(result.contains { $0.performanceDate == nil })
        #expect(result.count == 2)
    }

    // A detected-but-unconfirmed booking is a separate workflow from pitching, so it must
    // stay visible even once its performance date has passed.
    @Test func keepsPendingBookingEvenWhenPast() {
        var pending = dated("2026-06-22"); pending.bookingSuggested = true
        let result = QueueModel.queueOrder([pending, dated("2026-07-10")], today: "2026-06-25")
        #expect(result.contains { $0.bookingSuggested })
        #expect(result.count == 2)
    }
}

@Suite("Grouping and summary")
struct GroupingTests {
    @Test func groupsByDateWithWeekday() {
        let groups = QueueModel.groupByDate([
            item(performanceDate: "2026-06-22"),
            item(performanceDate: "2026-06-22"),
            item(performanceDate: "2026-06-23"),
        ])
        #expect(groups.count == 2)
        #expect(groups[0].weekday == "Mon")
        #expect(groups[0].monthDay == "Jun 22")
        #expect(groups[0].items.count == 2)
    }

    @Test func undatedCollectIntoTBD() {
        let groups = QueueModel.groupByDate([item(performanceDate: nil)])
        #expect(groups[0].monthDay == "Date to be confirmed")
    }

    @Test func summaryCountsTotalAndHigh() {
        let s = QueueModel.summary([item(tier: "high"), item(tier: "longshot"), item(tier: "high")])
        #expect(s.total == 3)
        #expect(s.high == 2)
    }
}

@Suite("Run display")
struct RunDisplayTests {
    @Test func formatsADateRangeWhenRunSpansNights() {
        #expect(QueueModel.runDateLabel(start: "2026-06-25", end: "2026-06-28") == "Jun 25 to 28")
    }
    @Test func formatsCrossMonthRange() {
        #expect(QueueModel.runDateLabel(start: "2026-06-28", end: "2026-07-02") == "Jun 28 to Jul 2")
    }
    @Test func showsSingleDateWhenNoRange() {
        #expect(QueueModel.runDateLabel(start: "2026-06-25", end: nil) == "Jun 25")
    }
    @Test func showsSingleDateWhenEndEqualsStart() {
        #expect(QueueModel.runDateLabel(start: "2026-06-25", end: "2026-06-25") == "Jun 25")
    }
    @Test func returnsPlaceholderWhenStartIsNil() {
        #expect(QueueModel.runDateLabel(start: nil, end: nil) == "Date to be confirmed")
    }
    @Test func relatedRunNoteOnlyWhenFlagged() {
        var run = item(performanceDate: "2026-06-25"); run.partOfRelatedRun = true
        #expect(QueueModel.relatedRunNote(run) != nil)
        #expect(QueueModel.relatedRunNote(item(performanceDate: "2026-06-25")) == nil)
    }
}

@Suite("Disappeared-from-feed queue filtering (#133)")
struct DisappearedFeedQueueTests {
    private func gone(id: String, status: ReviewStatus) -> QueueItem {
        var q = QueueItem(
            id: id, groupName: id, discipline: "music", venue: "Weill Recital Hall",
            performanceDate: "2026-07-25", sourceListingURL: nil, websiteURL: nil,
            priorRelationship: "none", production: "self", profile: "strong",
            coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
            matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil, status: status)
        q.disappearedFromFeed = true
        return q
    }

    @Test func hidesUntouchedGoneButKeepsPursuedGone() {
        // An untouched (.new) vanished show is noise and drops out; one Dan kept stays so the
        // cancellation is visible (struck-through in the row).
        let order = QueueModel.queueOrder(
            [gone(id: "untouched", status: .new), gone(id: "kept", status: .queued)],
            today: "2026-06-25")
        let ids = order.map(\.id)
        #expect(!ids.contains("untouched"))
        #expect(ids.contains("kept"))
    }
}

// #198: a booked prospect must read as Booked, not as a lead to pitch.
@Suite("Booked display")
struct BookedDisplayTests {
    private func booked() -> QueueItem {
        var q = item(performanceDate: "2026-07-01")
        q.outcome = .booked
        return q
    }

    @Test func bookedOutcomeIsBooked() {
        #expect(booked().isBooked)
        #expect(!item().isBooked)
    }

    @Test func displayTimingReadsBookedRegardlessOfDate() {
        // A booked prospect must never show pitch urgency ("reach out now"); the row reads "Booked".
        let t = QueueModel.displayTiming(performanceDate: "2026-07-01", today: "2026-06-26", isBooked: true)
        #expect(t.label == "Booked")
        #expect(t.urgency == .booked)
    }

    @Test func displayTimingFallsBackToOutreachWhenNotBooked() {
        let today = "2026-06-26"
        #expect(QueueModel.displayTiming(performanceDate: "2026-07-01", today: today, isBooked: false)
                == QueueModel.outreachTiming(performanceDate: "2026-07-01", today: today))
    }
}

// #201: a confirmed booking leaves the reach-out queue; an auto-detected one stays until Dan confirms it.
@Suite("Booked queue placement")
struct BookedQueueTests {
    private func q(_ id: String, outcome: Outcome = .noResponse,
                   source: OutcomeSource? = nil, date: String? = "2026-07-10") -> QueueItem {
        var p = QueueItem(
            id: id, groupName: id, discipline: "music", venue: "V",
            performanceDate: date, sourceListingURL: nil, websiteURL: nil,
            priorRelationship: "none", production: "unknown", profile: "neutral",
            coverage: "unknown", fitScore: 3, tier: "longshot", fitReason: "r",
            matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil, status: .approved)
        p.outcome = outcome
        p.outcomeSourceRaw = source?.rawValue
        return p
    }

    @Test func confirmedBookingLeavesTheQueue() {
        let order = QueueModel.queueOrder(
            [q("lead"), q("confirmed", outcome: .booked, source: .manual)], today: "2026-06-26")
        let ids = order.map(\.id)
        #expect(ids.contains("lead"))
        #expect(!ids.contains("confirmed"))
    }

    @Test func autoDetectedBookingStaysUntilConfirmed() {
        let order = QueueModel.queueOrder(
            [q("auto", outcome: .booked, source: .auto)], today: "2026-06-26")
        #expect(order.map(\.id).contains("auto"))
    }
}
