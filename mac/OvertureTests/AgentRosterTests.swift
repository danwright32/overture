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
        #expect(status("Send", disconnected).detail.contains("Connect Gmail"))
    }

    @Test func followUpsNeedAttentionWhenDue() {
        var i = calm; i.followUpsDue = 4
        #expect(status("Follow-ups", i).state == .needsAttention)
    }

    @Test func rollUpCountsAttentionAndError() {
        var i = calm; i.keptToPrep = 1; i.toReview = 1; i.sendErrors = 1; i.readyToSend = 1
        #expect(AgentRoster.needsYouCount(AgentRoster.statuses(i)) == 3)  // Prep, Review, Send
    }
}
