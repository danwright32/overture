import Testing
@testable import Overture

// #15: an at-a-glance status per pipeline stage so Dan can see where he's needed without
// hunting. The stages that can wait on him are Prep, Review, Send, and Follow-ups (the
// scout is automatic and never blocks on him). This is the pure state computation.
@Suite("Agent roster status")
struct AgentRosterTests {
    private let calm = AgentInputs(toTriage: 0, keptToPrep: 0, prepRunning: false, toReview: 0,
                                   readyToSend: 0, gmailConnected: true, sendErrors: 0, followUpsDue: 0)

    private func status(_ name: String, _ inputs: AgentInputs) -> AgentStatus {
        AgentRoster.statuses(inputs).first { $0.name == name }!
    }

    @Test func everythingIdleWhenNothingPending() {
        let s = AgentRoster.statuses(calm)
        #expect(s.allSatisfy { $0.state == .idle })
        #expect(AgentRoster.needsYouCount(s) == 0)
    }

    // #370: freshly scouted, undecided prospects (status .new) get their own pill, before Prep,
    // distinct from the kept-undrafted prospects Prep counts.
    @Test func scoutNeedsAttentionWithNewProspects() {
        var i = calm; i.toTriage = 3
        #expect(status("Scout", i).state == .needsAttention)
        #expect(status("Scout", i).detail == "3 to triage")
        #expect(status("Scout", calm).state == .idle)
    }

    @Test func statusesListsScoutFirst() {
        #expect(AgentRoster.statuses(calm).first?.name == "Scout")
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
        #expect(status("Send", ready).needsGmailConnect == false)

        var failed = calm; failed.readyToSend = 1; failed.sendErrors = 1
        #expect(status("Send", failed).state == .error)
        #expect(status("Send", failed).needsGmailConnect == false)

        var disconnected = calm; disconnected.readyToSend = 1; disconnected.gmailConnected = false
        #expect(status("Send", disconnected).state == .needsAttention)
        #expect(status("Send", disconnected).detail.contains("connect Gmail"))
        // #565: a structured flag, not a text match on `detail`, so the chip can route a tap to
        // the actual Gmail-connect flow (#488) instead of just filtering the queue, which read as
        // an instruction ("connect Gmail to send") with nothing behind it to act on.
        #expect(status("Send", disconnected).needsGmailConnect == true)
    }

    // #475/#476: an interrupted send (crash, or a save that never landed) must outrank even a
    // confirmed failure: Dan doesn't yet know whether it actually went out, so it needs his eyes
    // on Gmail, not just a retry.
    // #863: counted in SHOWS, and worded in shows, because the number is a promise about how many rows
    // tapping the pill lands Dan on. Counting the recipients underneath (two unconfirmed sends on one
    // show) promised him two rows and delivered one.
    @Test func sendFlagsAStuckSendAheadOfAConfirmedFailure() {
        var i = calm; i.stuckSends = 1
        #expect(status("Send", i).state == .error)
        #expect(status("Send", i).detail == "1 show with an unconfirmed send: check Gmail")
        #expect(status("Send", i).focus == .sendStuck)

        i.stuckSends = 2
        #expect(status("Send", i).detail == "2 shows with an unconfirmed send: check Gmail")

        i.sendErrors = 1   // a stuck send still wins even alongside a confirmed failure
        #expect(status("Send", i).detail == "2 shows with an unconfirmed send: check Gmail")
        #expect(status("Send", i).focus == .sendStuck)
    }

    // #483: a send that went out but came back with no usable threadId can never be watched
    // for a reply automatically. That must surface, never sit silent, but it is not itself a
    // failed send, so it needs attention rather than reading as an error.
    @Test func sendFlagsDegradedReplyTrackingWhenAThreadIdCouldNotBeRecovered() {
        var i = calm; i.degradedReplyTracking = 1
        #expect(status("Send", i).state == .needsAttention)
        #expect(status("Send", i).detail == "1 show sent, but replies can't be tracked: check Gmail")
        // #863: these shows are already SENT, so they are neither approved nor holding a blocked
        // contact. Keyed by the pill's name, the tap resolved the approved queue, which contains none
        // of them: the pill stated a number and took him nowhere.
        #expect(status("Send", i).focus == .sendDegraded)

        i.degradedReplyTracking = 2
        #expect(status("Send", i).detail == "2 shows sent, but replies can't be tracked: check Gmail")
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

    // #332: first-time user can't tell what each pill means, only its live count. A short,
    // stable concept sentence per pill (independent of live state) fixes that without touching
    // the existing per-state `detail` strings above, which stay pinned by the tests above.
    @Test func conceptSummaryExplainsEachPillAsAWorkQueue() {
        #expect(AgentRoster.conceptSummary(for: "Scout").contains("keep") || AgentRoster.conceptSummary(for: "Scout").contains("dismiss"))
        #expect(AgentRoster.conceptSummary(for: "Prep").contains("draft"))
        #expect(AgentRoster.conceptSummary(for: "Review").contains("approve"))
        #expect(AgentRoster.conceptSummary(for: "Send").contains("sent") || AgentRoster.conceptSummary(for: "Send").contains("send"))
        #expect(AgentRoster.conceptSummary(for: "Follow-ups").contains("reached out"))
    }

    @Test func conceptSummaryIsEmptyForAnUnknownName() {
        #expect(AgentRoster.conceptSummary(for: "Nonsense").isEmpty)
    }

    // #843: the tooltip is concept + live detail, shown together. In the common state of three pills the
    // detail used to restate the concept, so the hover said the same thing twice. The detail now carries
    // only what the concept does not: that it is running (Prep), or the count (Send, Follow-ups).
    @Test func aRunningPrepDoesNotRestateWhatPrepDoes() {
        var i = calm; i.prepRunning = true
        #expect(status("Prep", i).detail == "Running now…")
        // The old detail repeated the concept's own verbs; the new one does not.
        let help = AgentRoster.chipHelp(name: "Prep", detail: status("Prep", i).detail)
        #expect(!help.contains("drafts") || !help.contains("drafting"))
        #expect(!help.contains("Finding contacts and drafting"))
    }

    @Test func approvedSendsShowOnlyTheCountOnceConnected() {
        var i = calm; i.readyToSend = 3
        #expect(status("Send", i).detail == "3 ready")
        // "approved" and "to send" both live in the concept already; the detail no longer repeats them.
        let help = AgentRoster.chipHelp(name: "Send", detail: status("Send", i).detail)
        #expect(!help.contains("approved, ready to send"))
    }

    // The not-connected line is untouched: it carries a real instruction the concept does not.
    @Test func disconnectedSendStillTellsHimToConnectGmail() {
        var i = calm; i.readyToSend = 2; i.gmailConnected = false
        #expect(status("Send", i).detail == "2 approved, connect Gmail to send")
    }

    @Test func dueFollowUpsShowOnlyTheCount() {
        var i = calm; i.followUpsDue = 4
        let detail = status("Follow-ups", i).detail
        #expect(detail == "4 due")
        // "Nudges" is the concept's word ("Nudges due on shows you've already reached out to."); the
        // detail no longer repeats it, so the tooltip stops saying "nudges due" twice.
        #expect(!detail.lowercased().contains("nudge"))
    }

    // #357: two more categories that quietly waited on Dan with no top-level pill anywhere: an
    // unconfirmed classification, and a failed OmniFocus sync. Both fold into the same roster/count
    // invariant every other pill already follows.
    @Test func unsureNeedsAttentionWithUncertainClassifications() {
        var i = calm; i.uncertainClassifications = 2
        #expect(status("Unsure", i).state == .needsAttention)
        #expect(status("Unsure", i).count == 2)
        #expect(status("Unsure", i).focus == .uncertainClassification)
        #expect(status("Unsure", calm).state == .idle)
    }

    @Test func omniFocusPillReflectsSyncFailure() {
        var i = calm; i.omniFocusSyncFailed = true
        #expect(status("OmniFocus", i).state == .error)
        #expect(status("OmniFocus", i).focus == .omniFocusSync)
        #expect(status("OmniFocus", calm).state == .idle)
        // #863: this pill resolves no queue rows (mirrors Follow-ups), so its count is always 0,
        // never a promise about rows tapping it would land on.
        #expect(status("OmniFocus", i).count == 0)
    }

    @Test func rollUpCountsUnsureAndOmniFocusToo() {
        var i = calm; i.uncertainClassifications = 1; i.omniFocusSyncFailed = true
        #expect(AgentRoster.needsYouCount(AgentRoster.statuses(i)) == 2)
    }

    @Test func conceptSummaryCoversTheTwoNewPills() {
        #expect(AgentRoster.conceptSummary(for: "Unsure").contains("classification"))
        #expect(AgentRoster.conceptSummary(for: "OmniFocus").contains("sync"))
    }

    // #357: what a chip tap actually DOES, pulled out of QueueView's Button closure (the #863 lesson:
    // logic inside a SwiftUI view is untestable) so this dispatch has a seam a test can reach.
    @Test func chipActionRoutesGmailConnectAheadOfEverythingElse() {
        var i = calm; i.readyToSend = 1; i.gmailConnected = false
        #expect(AgentRoster.chipAction(for: status("Send", i)) == .connectGmail)
    }

    @Test func chipActionOpensFollowUpsInsteadOfNavigating() {
        var i = calm; i.followUpsDue = 1
        #expect(AgentRoster.chipAction(for: status("Follow-ups", i)) == .showFollowUps)
    }

    @Test func chipActionRetriesOmniFocusSyncInsteadOfNavigating() {
        var i = calm; i.omniFocusSyncFailed = true
        #expect(AgentRoster.chipAction(for: status("OmniFocus", i)) == .retryOmniFocusSync)
        #expect(AgentRoster.chipAction(for: status("OmniFocus", calm)) == .retryOmniFocusSync)
    }

    @Test func chipActionFocusesTheQueueForEveryOtherPill() {
        var i = calm; i.toTriage = 1
        #expect(AgentRoster.chipAction(for: status("Scout", i)) == .focusOnStage)
        i = calm; i.uncertainClassifications = 1
        #expect(AgentRoster.chipAction(for: status("Unsure", i)) == .focusOnStage)
    }
}
