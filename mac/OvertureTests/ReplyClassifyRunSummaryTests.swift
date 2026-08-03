import Testing
import Foundation

// #1018: the sentence a finished reply-classify run says to Dan about a reply it never came back with.
//
// Mirrors PrepRunSummary (#876): the copy lives in a pure type a test can read, not inside RootView's
// SwiftUI body where #863 warns a rule will drift unseen. The retry sentence itself is the shared
// HandoffShortfall.retryNote, so Prep and reply-classify cannot word the same promise two ways.
@Suite("What a finished reply-classify run tells Dan (#1018)")
struct ReplyClassifyRunSummaryTests {

    private func outcome(matched: Int = 0, missing: [ReplyClassifyKey] = []) -> ReplyClassifyImporter.Outcome {
        var o = ReplyClassifyImporter.Outcome()
        o.matched = matched
        o.missingKeys = missing
        return o
    }

    // THE issue. The run was queued two replies and answered neither, so the shortfall speaks and
    // promises the retry (an un-drafted reply is re-queued by ReplyClassifyService next run).
    @Test func aRunThatCameBackShortSaysSoAndPromisesTheRetry() {
        let notes = ReplyClassifyRunSummary.notes(for: outcome(
            missing: [.init(naturalKey: "a", recipientId: "r1"), .init(naturalKey: "b", recipientId: "r2")]))
        #expect(notes == ["2 didn't come back, they'll be retried"])
    }

    // A run that answered everything must say nothing about a shortfall. The whole value of the warning
    // is that it means something when it appears.
    @Test func aRunThatAnsweredEverythingSaysNothingAboutAShortfall() {
        let notes = ReplyClassifyRunSummary.notes(for: outcome(matched: 3))
        #expect(notes.isEmpty)
        #expect(ReplyClassifyRunSummary.statusMessage(for: outcome(matched: 3)) == nil)
    }

    @Test func theStatusLineIsPrefixedForDan() {
        let message = ReplyClassifyRunSummary.statusMessage(for: outcome(
            missing: [.init(naturalKey: "a", recipientId: "r1")]))
        #expect(message == "Replies: 1 didn't come back, they'll be retried")
    }
}
