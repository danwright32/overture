import Testing
import Foundation

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

    // #1765: a week of one-offs RUNS, and it reaches the confirm through the same seam the bar uses, so
    // what Dan approves can never be a different total from the one shown beside the button. This used to
    // assert the refusal; the ceiling is gone, and the claim that replaces it is that the big case is
    // runnable rather than that it is stopped.
    @Test func aWeekOfOneOffsIsRunnableThroughTheSameSeam() throws {
        let many = (0..<45).map {
            item("k\($0)", date: "2026-09-1\($0 % 5)", presenter: "Solo \($0)", venue: "Room \($0)")
        }
        let dates = Set(many.compactMap(\.performanceDate))
        let (summary, _) = try #require(
            QueueModel.probeSelection(dates: dates, in: many, among: many, today: today, stage: .scout))
        #expect(summary.researchCount == 45)
        guard case .confirm(_, let message) = ProbeSelection.outcome(for: summary) else {
            Issue.record("a 45-lookup week must be runnable, not refused")
            return
        }
        #expect(message.contains("45 lookups"))
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

    // #1597 follow-up (Dan, walking the Debug build): ticking the first date made the whole page jump
    // under his cursor. The bar was a SIBLING above the scroll view, so the moment it appeared it took
    // its own height out of the scroll area and shoved every row down mid-click.
    //
    // A source guard, deliberately, and the weakest kind of test in this file. Scroll geometry is not
    // something any test here can observe: nothing can assert "the rows did not move". What it CAN pin is
    // the one structural fact that caused it, so a future edit cannot quietly put the bar back in a stack
    // above the scroll. Whether it actually looks right is still only answerable by opening the app.
    @Test func theSelectionBarFloatsOverTheScrollRatherThanPushingItDown() {
        let queue = SourceGuardHelper.source("Overture/UI/QueueView.swift")
        #expect(!queue.isEmpty)
        #expect(queue.contains(".overlay(alignment: .top) { probeSelectionBar(data) }"),
                "the bar must be an overlay: as a sibling above the scroll it changes the scroll's height and the page jumps when it appears")
        // And the thing it replaced must be gone, or both could coexist and the jump would return.
        // #2543: as CODE. Pinned to its indentation, this negative assertion passed the moment the
        // sibling pair was re-indented, which is the direction that ships the defect.
        #expect(!SourceGuardHelper.containsCode("probeSelectionBar(data) queueScroll(data)", in: queue))
    }
}
