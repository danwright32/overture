import Testing
import Foundation
@testable import Overture

// #1597 Phase 4.4: what ticking dates on Scout actually selects.
//
// The seam exists because this logic used to sit inside the SwiftUI body, where nothing could reach it.
// It decides how much money a click spends, so it is the last place that should be untestable.
@Suite("Selecting several dates for one reachability check (#1597)")
struct ProbeMultiDateSelectionTests {

    private let today = "2026-09-01"

    private func item(_ key: String, date: String, presenter: String?, venue: String,
                      status: ReviewStatus = .new, probed: Bool = false) -> QueueItem {
        var i = QueueItem(id: key, groupName: key, discipline: "theater", venue: venue,
                          performanceDate: date, sourceListingURL: nil, websiteURL: nil,
                          priorRelationship: "none", production: "self", profile: "strong",
                          coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                          matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                          status: status)
        i.presenter = presenter
        if probed { i.reachabilityProbedAt = Date() }
        return i
    }

    // Two nights, one producer across both, plus a one-off. Ticking both nights checks all three shows
    // but pays for two lookups.
    private var rows: [QueueItem] {
        [item("a", date: "2026-09-12", presenter: "FRIGID New York", venue: "Under St Marks"),
         item("b", date: "2026-09-12", presenter: "Solo Co", venue: "The Tank"),
         item("c", date: "2026-09-13", presenter: "FRIGID New York", venue: "The Kraine Theater")]
    }

    @Test func nothingSelectedMeansNoBarAtAll() {
        #expect(QueueModel.probeSelection(dates: [], in: rows, among: rows, today: today, stage: .scout) == nil)
    }

    @Test func tickingTwoNightsChecksEveryShowOnThem() throws {
        let (summary, keys) = try #require(
            QueueModel.probeSelection(dates: ["2026-09-12", "2026-09-13"], in: rows, among: rows, today: today, stage: .scout))
        #expect(summary.dateCount == 2)
        #expect(summary.showCount == 3)
        // Dan's rule: every show on a selected date, no exceptions.
        #expect(keys.sorted() == ["a", "b", "c"])
        // But paid for twice, not three times: the producer answers for both its shows.
        #expect(summary.researchCount == 2)
        #expect(summary.organisationCount == 1)
        #expect(summary.performerHuntCount == 1)
    }

    @Test func tickingOneNightLeavesTheOtherAlone() throws {
        let (summary, keys) = try #require(
            QueueModel.probeSelection(dates: ["2026-09-12"], in: rows, among: rows, today: today, stage: .scout))
        #expect(summary.dateCount == 1)
        #expect(keys.sorted() == ["a", "b"])
        #expect(summary.showCount == 2)
    }

    // A show already answered is not researched again and costs nothing, but it must be COUNTED, or the
    // confirm quietly describes fewer shows than the dates actually hold.
    @Test func anAlreadyAnsweredShowIsFreeButStillCounted() throws {
        var withAnswered = rows
        withAnswered.append(item("d", date: "2026-09-12", presenter: "Someone Else",
                                 venue: "Joe's Pub", probed: true))
        let (summary, keys) = try #require(
            QueueModel.probeSelection(dates: ["2026-09-12"], in: withAnswered, among: withAnswered, today: today, stage: .scout))
        #expect(!keys.contains("d"))
        #expect(summary.alreadyAnsweredCount == 1)
        #expect(summary.researchCount == 2)
        #expect(ProbeSelectionCopy.multiDateMessage(summary).contains("1 more show was checked recently"))
    }

    // A date whose shows are all settled contributes nothing, so a stale tick cannot inflate the total.
    @Test func aDateWithNothingLeftToCheckAddsNothing() throws {
        let settled = [item("x", date: "2026-09-20", presenter: "Done Co", venue: "A Room", status: .dismissed)]
        let result = QueueModel.probeSelection(dates: ["2026-09-20"], in: settled, among: settled, today: today, stage: .scout)
        let summary = try #require(result?.0)
        #expect(summary.showCount == 0)
        #expect(summary.isEmpty)
    }

    // A tick on a date that is no longer on screen (Dan kept everything on it, so the group is gone)
    // must not resurrect it or crash the bar.
    @Test func aTickedDateThatNoLongerExistsIsIgnored() {
        #expect(QueueModel.probeSelection(dates: ["2026-12-25"], in: rows, among: rows, today: today, stage: .scout) == nil)
    }

    // The producer gate is judged against the WHOLE queue, not the ticked dates. Ticking only the night
    // where FRIGID plays one room must still recognise it as a producer, or nothing ever amortises.
    @Test func theGateStillSeesTheWholeQueueWhenOneNightIsTicked() throws {
        let (summary, _) = try #require(
            QueueModel.probeSelection(dates: ["2026-09-13"], in: rows, among: rows, today: today, stage: .scout))
        #expect(summary.organisationCount == 1)
        #expect(summary.researchCount == 1)
    }

    // And the brake, reached through the same seam the bar uses, so the refusal is not a separate
    // calculation that could disagree with the total shown beside it.
    @Test func aWeekOfOneOffsIsRefusedThroughTheSameSeam() throws {
        let many = (0..<45).map {
            item("k\($0)", date: "2026-09-1\($0 % 5)", presenter: "Solo \($0)", venue: "Room \($0)")
        }
        let dates = Set(many.compactMap(\.performanceDate))
        let (summary, _) = try #require(
            QueueModel.probeSelection(dates: dates, in: many, among: many, today: today, stage: .scout))
        #expect(summary.researchCount == 45)
        #expect(summary.overCeiling)
    }

    // #1597 follow-up (Dan, walking the Debug build): the bar must not outlive the stage that produced
    // it. Ticking dates on Scout and switching to Review left a bar reading "2 dates, 4 shows" pinned at
    // the top while the checkboxes that made it were nowhere on screen, offering to start a run against a
    // selection he could neither see nor change.
    //
    // The selection itself SURVIVES the trip: hiding is not discarding, and losing his ticks because he
    // glanced at another stage would be worse than the bug.
    @Test func theBarBelongsToScoutAndDoesNotFollowHimToOtherStages() {
        let dates: Set<String> = ["2026-09-12"]
        #expect(QueueModel.probeSelection(dates: dates, in: rows, among: rows,
                                          today: today, stage: .scout) != nil)
        for elsewhere: StageFocus in [.prep, .review, .reachedOut, .followUps] {
            #expect(QueueModel.probeSelection(dates: dates, in: rows, among: rows,
                                              today: today, stage: elsewhere) == nil,
                    "the bar should not appear on \(elsewhere)")
        }
        // The #308 away-leads list has no stage at all, and no checkboxes either.
        #expect(QueueModel.probeSelection(dates: dates, in: rows, among: rows,
                                          today: today, stage: nil) == nil)
    }

    // #1597 follow-up: the bar promises a wait computed from ten lookups at a time. The runner is what
    // decides how many actually run at a time. Nothing connected those two numbers, so a future edit to
    // either one would leave the bar quoting a wait the run cannot keep, silently and only on real runs.
    @Test func theAppsConcurrencyAssumptionMatchesWhatTheRunnerActuallyDoes() {
        let runner = SourceGuardHelper.source("scripts/prep-run.sh")
        #expect(!runner.isEmpty)
        // Stated as a Comment literal, because #expect's second argument is a Comment and a built-up
        // String will not convert.
        #expect(runner.contains("OVERTURE_PREP_MAX_PARALLEL:-\(ProbeSelection.maxConcurrentLookups)}"),
                "prep-run.sh's default parallelism must match ProbeSelection.maxConcurrentLookups, or the estimated wait is a promise the run cannot keep")
    }
}
