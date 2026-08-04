import Testing
import Foundation

// #1134: with stage-only navigation, the queue opens on Scout and each stage can be empty on its own.
// An empty Scout on launch must STAY on Scout (never auto-jump) and point Dan to the next stage that
// actually has work, so he is not left staring at an empty screen wondering where his shows went. This
// pointer logic is a pure helper (not decided inside the SwiftUI view, per the #863 lesson) so it can
// be tested at all.
@Suite("Stage empty state points to the next stage with work (#1134)")
struct StageEmptyStateTests {
    // The queue opens on Scout, always, regardless of whether Scout has anything (#1134 decision 2/3).
    @Test func theQueueOpensOnScout() {
        #expect(StageNavigation.openingStage == .scout)
    }

    // An empty Scout points to the next stage that has items, by workflow order (Scout, Prep, Review,
    // Reached out), so Dan is told where to go instead of guessing.
    @Test func anEmptyScoutPointsToPrepWhenPrepHasWork() {
        let msg = StageEmptyState.message(for: .scout,
                                          counts: [.scout: 0, .prep: 3, .review: 0], reachedOut: 0)
        #expect(msg.title == "Nothing new to triage")
        #expect(msg.detail == "You have 3 shows to prep next.")
    }

    // The pointer follows workflow order: with both Prep and Review holding work, Prep (earlier) wins.
    @Test func thePointerFollowsWorkflowOrder() {
        let msg = StageEmptyState.message(for: .scout,
                                          counts: [.prep: 2, .review: 5], reachedOut: 0)
        #expect(msg.detail == "You have 2 shows to prep next.")
    }

    // #2050: a review count reads as SHOWS, not drafts, because Review now holds an approved show
    // waiting to send as well as one Dan has not read. A reached-out count reads as pitched shows.
    @Test func thePointerNamesReviewAndReachedOutCorrectly() {
        let review = StageEmptyState.message(for: .scout, counts: [.review: 1], reachedOut: 0)
        #expect(review.detail == "You have 1 show to review next.")

        let reached = StageEmptyState.message(for: .prep, counts: [:], reachedOut: 4)
        #expect(reached.detail == "You have 4 shows you've pitched next.")
    }

    // With nothing anywhere, there is no pointer: the empty state just explains what the stage is for.
    @Test func withNoWorkAnywhereItExplainsTheStageInsteadOfPointing() {
        let msg = StageEmptyState.message(for: .scout, counts: [:], reachedOut: 0)
        #expect(msg.title == "Nothing new to triage")
        #expect(!msg.detail.contains("next"))
        #expect(msg.detail.contains("keep") || msg.detail.contains("dismiss"))
    }

    // Each primary stage has its own empty title, so the screen never says the wrong stage is empty.
    @Test func eachStageHasItsOwnTitle() {
        #expect(StageEmptyState.message(for: .prep, counts: [:], reachedOut: 0).title == "Nothing to prep yet")
        #expect(StageEmptyState.message(for: .review, counts: [:], reachedOut: 0).title == "Nothing to review yet")
    }

    // #1195/#843: the Send-issues stages (the default arm) have no stage-specific resting line, so when
    // nothing is waiting anywhere their empty state shows only the title ("Nothing here right now") and
    // never a second sentence that just restates it ("Nothing waiting on you here.").
    @Test func aSendIssuesStageDoesNotRestateItsTitleWhenIdle() {
        let msg = StageEmptyState.message(for: .sendApproved, counts: [:], reachedOut: 0)
        #expect(msg.title == "Nothing here right now")
        #expect(msg.detail.isEmpty)
    }

    // The trim only drops the resting line: an idle Send-issues stage still points Dan to work elsewhere.
    @Test func aSendIssuesStageStillPointsToWorkElsewhere() {
        let msg = StageEmptyState.message(for: .sendApproved, counts: [.prep: 2], reachedOut: 0)
        #expect(msg.detail == "You have 2 shows to prep next.")
    }
}
