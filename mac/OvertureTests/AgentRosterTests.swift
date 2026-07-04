import Testing
@testable import Overture

// #15: an at-a-glance status per pipeline stage so Dan can see where he's needed without
// hunting. The stages that can wait on him are Prep, Review, Send, and Follow-ups (the
// scout is automatic and never blocks on him). This is the pure state computation.
@Suite("Agent roster status")
struct AgentRosterTests {
    private let calm = AgentInputs(keptToPrep: 0, prepRunning: false, toReview: 0,
                                   readyToSend: 0, gmailConnected: true, sendErrors: 0, followUpsDue: 0)

    private func status(_ name: String, _ inputs: AgentInputs) -> AgentStatus {
        AgentRoster.statuses(inputs).first { $0.name == name }!
    }

    @Test func everythingIdleWhenNothingPending() {
        let s = AgentRoster.statuses(calm)
        #expect(s.allSatisfy { $0.state == .idle })
        #expect(AgentRoster.needsYouCount(s) == 0)
    }

    @Test func prepWorksThenWaits() {
        var i = calm; i.prepRunning = true
        #expect(status("Prep", i).state == .working)
        i.prepRunning = false; i.keptToPrep = 3
        #expect(status("Prep", i).state == .needsAttention)
        #expect(status("Prep", i).detail == "3 ready to prep")   // #347: natural phrasing
    }

    @Test func reviewNeedsAttentionWithDrafts() {
        var i = calm; i.toReview = 2
        #expect(status("Review", i).state == .needsAttention)
    }

    @Test func sendNeedsAttentionErrorsAndDisconnected() {
        var ready = calm; ready.readyToSend = 1
        #expect(status("Send", ready).state == .needsAttention)

        var failed = calm; failed.readyToSend = 1; failed.sendErrors = 1
        #expect(status("Send", failed).state == .error)

        var disconnected = calm; disconnected.readyToSend = 1; disconnected.gmailConnected = false
        #expect(status("Send", disconnected).state == .needsAttention)
        #expect(status("Send", disconnected).detail.contains("connect Gmail"))
    }

    // #475/#476: an interrupted send (crash, or a save that never landed) must outrank even a
    // confirmed failure: Dan doesn't yet know whether it actually went out, so it needs his eyes
    // on Gmail, not just a retry.
    @Test func sendFlagsAStuckSendAheadOfAConfirmedFailure() {
        var i = calm; i.stuckSends = 1
        #expect(status("Send", i).state == .error)
        #expect(status("Send", i).detail == "1 send unconfirmed: check Gmail")

        i.stuckSends = 2
        #expect(status("Send", i).detail == "2 sends unconfirmed: check Gmail")

        i.sendErrors = 1   // a stuck send still wins even alongside a confirmed failure
        #expect(status("Send", i).detail == "2 sends unconfirmed: check Gmail")
    }

    // #483: a send that went out but came back with no usable threadId can never be watched
    // for a reply automatically. That must surface, never sit silent, but it is not itself a
    // failed send, so it needs attention rather than reading as an error.
    @Test func sendFlagsDegradedReplyTrackingWhenAThreadIdCouldNotBeRecovered() {
        var i = calm; i.degradedReplyTracking = 1
        #expect(status("Send", i).state == .needsAttention)
        #expect(status("Send", i).detail == "1 sent but can't be watched for replies: check Gmail")

        i.degradedReplyTracking = 2
        #expect(status("Send", i).detail == "2 sent but can't be watched for replies: check Gmail")
    }

    @Test func stuckSendsAndSendErrorsOutrankDegradedReplyTracking() {
        var stuck = calm; stuck.degradedReplyTracking = 1; stuck.stuckSends = 1
        #expect(status("Send", stuck).detail.contains("unconfirmed"))

        var failed = calm; failed.degradedReplyTracking = 1; failed.sendErrors = 1
        #expect(status("Send", failed).detail == "1 failed to send")
    }

    @Test func followUpsNeedAttentionWhenDue() {
        var i = calm; i.followUpsDue = 4
        #expect(status("Follow-ups", i).state == .needsAttention)
    }

    @Test func followUpsFlagAStalledReplyDraft() {
        var i = calm; i.stalledReplyDrafts = 1
        #expect(status("Follow-ups", i).state == .needsAttention)
        #expect(status("Follow-ups", i).detail == "1 reply draft stalled")   // #431

        i.stalledReplyDrafts = 2
        #expect(status("Follow-ups", i).detail == "2 reply drafts stalled")
        #expect(AgentRoster.needsYouCount(AgentRoster.statuses(i)) == 1)
    }

    @Test func rollUpCountsAttentionAndError() {
        var i = calm; i.keptToPrep = 1; i.toReview = 1; i.sendErrors = 1; i.readyToSend = 1
        #expect(AgentRoster.needsYouCount(AgentRoster.statuses(i)) == 3)  // Prep, Review, Send
    }
}
