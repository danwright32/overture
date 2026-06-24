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
    possibleMatchName: String? = nil
) -> QueueItem {
    QueueItem(
        id: "k", groupName: "Test Group", discipline: discipline, venue: venue,
        performanceDate: performanceDate, sourceListingURL: nil, websiteURL: nil,
        priorRelationship: priorRelationship, production: production, profile: "neutral",
        coverage: coverage, fitScore: fitScore, tier: tier, fitReason: "reason",
        matchedClientName: matchedClientName, possibleMatchSource: possibleMatchSource,
        possibleMatchName: possibleMatchName, status: .new
    )
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

    @Test func urgesOutreachWithinAWeek() {
        let t = QueueModel.outreachTiming(performanceDate: "2026-06-25", today: "2026-06-22")
        #expect(t.urgency == .imminent)
        #expect(t.label.contains("3 days"))
    }

    @Test func suggestsThreeWeeksOutForDistant() {
        #expect(QueueModel.outreachTiming(performanceDate: "2026-08-01", today: "2026-06-22").urgency == .ahead)
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
