import Testing
import Foundation

// #1805: a check that came home short says so and offers nothing to finish it.
//
// Dan, 2026-07-30, meeting the shipped report for the first time: "add a retry offer, dialog or not." The
// sentence names the shortfall and stops, so to finish those shows he has to work out which dates they
// sit on, find them in Scout, tick them, and start another check. The app is holding the exact list while
// he reconstructs it by hand (L44, L49: the fact is on screen and the action is not).
//
// It needs no new bookkeeping. A show a run never reached is already stamped by the settle, and it was
// deliberately never given a probe date (#1594), so it is already a candidate. The only thing missing was
// gathering them.
@MainActor
@Suite("Finishing the shows a check missed (#1805)")
struct FinishTheShowsACheckMissedTests {

    private let ranAt = Date(timeIntervalSince1970: 1_780_000_000)
    private var justAfter: Date { ranAt.addingTimeInterval(100) }

    private func item(_ key: String, missed: Bool = false, answered: Bool = false,
                      status: ReviewStatus = .new, booked: Bool = false) -> QueueItem {
        var i = QueueItem(id: key, groupName: key, discipline: "music", venue: "Weill Recital Hall",
                          performanceDate: "2026-09-12", sourceListingURL: nil, websiteURL: nil,
                          priorRelationship: "none", production: "self", profile: "strong",
                          coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                          matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                          status: status)
        if booked { i.performanceStatus = .booked }
        if missed { i.reachabilityUnansweredAt = ranAt }
        if answered { i.reachabilityProbedAt = ranAt }
        return i
    }

    // The core: exactly the shows the run never reached.
    @Test func theSetIsTheShowsTheRunNeverReached() {
        let keys = QueueModel.keysMissedByACheck([item("missed", missed: true),
                                                  item("answered", answered: true),
                                                  item("untouched")],
                                                 now: justAfter, today: "2026-09-01")
        #expect(Set(keys) == ["missed"])
    }

    // The failure path the issue names: a check that answered everything must offer NOTHING, rather than a
    // control that would start a run over an empty set and spend a slot on nobody.
    @Test func aCheckThatAnsweredEverythingOffersNothing() {
        let keys = QueueModel.keysMissedByACheck([item("a", answered: true), item("b", answered: true)],
                                                 now: justAfter, today: "2026-09-01")
        #expect(keys.isEmpty)
    }

    // A show whose answer DID come back is never included, so a second check can never be paid for a
    // lookup that already succeeded. Belt and braces: a row can carry both marks if an earlier run missed
    // it and a later one answered it, and the answer is what counts.
    @Test func aShowThatWasAnsweredLaterIsNeverPaidForAgain() {
        let keys = QueueModel.keysMissedByACheck([item("both", missed: true, answered: true)],
                                                 now: justAfter, today: "2026-09-01")
        #expect(keys.isEmpty)
    }

    // The candidacy rule still holds: a show past the keep-or-dismiss moment is not worth paying for,
    // whatever a run did or did not do to it.
    @Test func aShowPastDecidingIsNotOffered() {
        let keys = QueueModel.keysMissedByACheck([item("booked", missed: true, booked: true),
                                                  item("kept", missed: true, status: .queued)],
                                                 now: justAfter, today: "2026-09-01")
        #expect(keys.isEmpty)
    }

    // The mark ages on the same clock as every other reachability fact, so a shortfall from months ago
    // does not keep offering to spend money on a run nobody remembers.
    @Test func anOldShortfallStopsOffering() {
        let longAfter = ranAt.addingTimeInterval(Reachability.probeFreshness + 1)
        let keys = QueueModel.keysMissedByACheck([item("missed", missed: true)],
                                                 now: longAfter, today: "2026-09-01")
        #expect(keys.isEmpty)
    }
}

// The other half: the report that names the shortfall now carries the control to finish it. The rule
// above says WHICH shows; this says the offer reaches the surface Dan reads.
@Suite("The shortfall report offers to finish it (#1805)")
struct ShortfallReportCarriesItsActionTests {

    private func status(_ text: String, priority: StatusPriority = .warning,
                        action: AppNoticeAction? = nil) -> StatusLine {
        var s = StatusLine()
        s.set(text, priority: priority, action: action)
        return s
    }

    @Test func aShortfallReportCarriesTheOfferToFinishIt() {
        let notices = AppNotices.current(
            omniFocusFailing: false,
            status: status("Reachability: 8 of 77 shows never got an answer and are still unchecked",
                           action: .finishShowsACheckMissed))
        #expect(notices.first?.action == .finishShowsACheckMissed)
    }

    // An ordinary receipt still carries nothing, so the queue never grows a control beside a run that
    // finished cleanly.
    @Test func aCleanRunsReceiptOffersNothing() {
        let notices = AppNotices.current(omniFocusFailing: false,
                                         status: status("Prep finished", priority: .info))
        #expect(notices.first?.action == nil)
    }

    // The control says what it does. It must not read as "retry" in the sense Prep uses, where a run
    // genuinely re-queues itself: this starts a paid run over a set of shows, and it goes through the same
    // confirmation as every other check.
    @Test func theControlNamesTheShowsRatherThanPromisingARetry() {
        let title = AppNoticeAction.finishShowsACheckMissed.title
        #expect(!title.lowercased().contains("retry"))
        #expect(title.isEmpty == false)
    }
}

// Whether the offer is SERVABLE is a separate question from whether the report makes it, and it is
// answered where the rows are. A shortfall sentence whose shows have since been answered, or which are
// past deciding, must not put a control on screen that would start a run over nobody (L44: a control that
// cannot do its job is worse than none).
@Suite("An offer nothing can serve is not shown (#1805)")
struct UnservableOfferIsStrippedTests {

    private func notice(_ action: AppNoticeAction?) -> AppNotice {
        AppNotice(text: "Reachability: 8 of 77 shows never got an answer", tone: .warning, action: action)
    }

    @Test func theOfferStandsWhileThereAreShowsToFinish() {
        let out = AppNotices.servable([notice(.finishShowsACheckMissed)], canFinishMissedShows: true)
        #expect(out.first?.action == .finishShowsACheckMissed)
    }

    @Test func theOfferIsStrippedWhenNothingIsLeftToFinish() {
        let out = AppNotices.servable([notice(.finishShowsACheckMissed)], canFinishMissedShows: false)
        #expect(out.first?.action == nil)
        // The sentence itself stays: what the run did is still true and still worth reading.
        #expect(out.first?.text.contains("never got an answer") == true)
    }

    // Every other action is untouched, so this rule can never quietly disarm an unrelated control.
    @Test func anotherActionIsNeverStripped() {
        let out = AppNotices.servable([AppNotice(text: "OmniFocus sync failing", tone: .warning,
                                                 action: .retryOmniFocusSync)],
                                      canFinishMissedShows: false)
        #expect(out.first?.action == .retryOmniFocusSync)
    }
}

// What the confirmation says before finishing a short run spends anything. It is the last screen between
// the offer and a real set of lookups, so what it claims has to be true and has to agree with every other
// check's account of what one costs.
@Suite("The confirmation for finishing a short run (#1805)")
struct FinishMissedShowsConfirmTests {

    @Test func itIsPricedAsOneLookupPerShow() {
        let s = ProbeSelection.summarizeShowsACheckMissed(count: 8)
        #expect(s.showCount == 8)
        #expect(s.researchCount == 8)
        #expect(s.alreadyAnsweredCount == 0)
    }

    // Every one of these shows was already inside a run that was paid for, so all of them count as being
    // paid for a second time. Saying fewer would understate what he is committing to.
    @Test func everyShowCountsAsPaidForASecondTime() {
        #expect(ProbeSelection.summarizeShowsACheckMissed(count: 8).previouslyMissedCount == 8)
    }

    @Test func itCarriesTheSameCostSentenceAsEveryOtherCheck() {
        let s = ProbeSelection.summarizeShowsACheckMissed(count: 8)
        #expect(ProbeSelectionCopy.finishMissedShowsMessage(s).contains(ProbeSelectionCopy.costLine(s)))
    }

    @Test func itNamesHowManyShowsAreBeingFinished() {
        let s = ProbeSelection.summarizeShowsACheckMissed(count: 8)
        #expect(ProbeSelectionCopy.finishMissedShowsMessage(s).contains("8 shows"))
    }

    // A run long enough to span more than one round says what it blocks, exactly as the date confirm does,
    // because at that length losing the single run slot is a real cost.
    @Test func aLongRunSaysWhatItBlocks() {
        let long = ProbeSelection.summarizeShowsACheckMissed(count: 40)
        let short = ProbeSelection.summarizeShowsACheckMissed(count: 3)
        #expect(ProbeSelectionCopy.finishMissedShowsMessage(long).contains(ProbeSelectionCopy.blocksOtherRuns))
        #expect(ProbeSelectionCopy.finishMissedShowsMessage(short).contains(ProbeSelectionCopy.blocksOtherRuns) == false)
    }
}
