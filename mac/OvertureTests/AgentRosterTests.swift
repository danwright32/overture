import Testing

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

    @Test func sendIssuesSurfacesProblemsAndTheCantConnectBlocker() {
        // #1146: a connected, ready-to-send show is NOT an issue (Approve and Send are the same card, so
        // it's transient), so with only that the Send-issues pill is absent from the strip entirely.
        var ready = calm; ready.readyToSend = 1
        #expect(AgentRoster.statuses(ready).contains { $0.name == "Send issues" } == false)

        // A failed send is a real problem: the pill appears as an error.
        var failed = calm; failed.sendErrors = 1
        #expect(status("Send issues", failed).state == .error)
        #expect(status("Send issues", failed).needsGmailConnect == false)

        // Approved emails he can't send because Gmail isn't connected: a real blocker worth surfacing.
        var disconnected = calm; disconnected.readyToSend = 1; disconnected.gmailConnected = false
        #expect(status("Send issues", disconnected).state == .needsAttention)
        #expect(status("Send issues", disconnected).detail.contains("connect Gmail"))
        // #565: a structured flag, not a text match on `detail`, so the chip can route a tap to
        // the actual Gmail-connect flow (#488) instead of just filtering the queue.
        #expect(status("Send issues", disconnected).needsGmailConnect == true)
    }

    // #475/#476: an interrupted send (crash, or a save that never landed) must outrank even a
    // confirmed failure: Dan doesn't yet know whether it actually went out, so it needs his eyes
    // on Gmail, not just a retry.
    // #863: counted in SHOWS, and worded in shows, because the number is a promise about how many rows
    // tapping the pill lands Dan on. Counting the recipients underneath (two unconfirmed sends on one
    // show) promised him two rows and delivered one.
    @Test func sendFlagsAStuckSendAheadOfAConfirmedFailure() {
        var i = calm; i.stuckSends = 1
        #expect(status("Send issues", i).state == .error)
        #expect(status("Send issues", i).detail == "1 show with an unconfirmed send: check Gmail")
        #expect(status("Send issues", i).focus == .sendStuck)

        i.stuckSends = 2
        #expect(status("Send issues", i).detail == "2 shows with an unconfirmed send: check Gmail")

        i.sendErrors = 1   // a stuck send still wins even alongside a confirmed failure
        #expect(status("Send issues", i).detail == "2 shows with an unconfirmed send: check Gmail")
        #expect(status("Send issues", i).focus == .sendStuck)
    }

    // #483: a send that went out but came back with no usable threadId can never be watched
    // for a reply automatically. That must surface, never sit silent, but it is not itself a
    // failed send, so it needs attention rather than reading as an error.
    @Test func sendFlagsDegradedReplyTrackingWhenAThreadIdCouldNotBeRecovered() {
        var i = calm; i.degradedReplyTracking = 1
        #expect(status("Send issues", i).state == .needsAttention)
        #expect(status("Send issues", i).detail == "1 show sent, but replies can't be tracked: check Gmail")
        // #863: these shows are already SENT, so they are neither approved nor holding a blocked
        // contact. Keyed by the pill's name, the tap resolved the approved queue, which contains none
        // of them: the pill stated a number and took him nowhere.
        #expect(status("Send issues", i).focus == .sendDegraded)

        i.degradedReplyTracking = 2
        #expect(status("Send issues", i).detail == "2 shows sent, but replies can't be tracked: check Gmail")
    }

    @Test func stuckSendsAndSendErrorsOutrankDegradedReplyTracking() {
        var stuck = calm; stuck.degradedReplyTracking = 1; stuck.stuckSends = 1
        #expect(status("Send issues", stuck).detail.contains("unconfirmed"))

        var failed = calm; failed.degradedReplyTracking = 1; failed.sendErrors = 1
        #expect(status("Send issues", failed).detail == "1 failed to send")
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
        #expect(AgentRoster.conceptSummary(for: "Review").contains("read"))
        #expect(AgentRoster.conceptSummary(for: "Review").contains("send"))
        #expect(AgentRoster.conceptSummary(for: "Send issues").contains("sent") || AgentRoster.conceptSummary(for: "Send issues").contains("send"))
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

    // #1146: a connected, ready-to-send show no longer surfaces a pill at all (it's transient, sent from
    // the card), so there is no "N ready" detail to check any more.
    @Test func aConnectedReadyToSendShowShowsNoPill() {
        var i = calm; i.readyToSend = 3
        #expect(AgentRoster.statuses(i).contains { $0.name == "Send issues" } == false)
        #expect(AgentRoster.needsYouCount(AgentRoster.statuses(i)) == 0)
    }

    // The not-connected line is untouched: it carries a real instruction the concept does not.
    @Test func disconnectedSendStillTellsHimToConnectGmail() {
        var i = calm; i.readyToSend = 2; i.gmailConnected = false
        #expect(status("Send issues", i).detail == "2 approved, connect Gmail to send")
    }

    @Test func dueFollowUpsShowOnlyTheCount() {
        var i = calm; i.followUpsDue = 4
        let detail = status("Follow-ups", i).detail
        #expect(detail == "4 due")
        // "Nudges" is the concept's word ("Nudges due on shows you've already reached out to."); the
        // detail no longer repeats it, so the tooltip stops saying "nudges due" twice.
        #expect(!detail.lowercased().contains("nudge"))
    }

    // #1133: the Unsure pill is gone. Dan (2026-07-18): discipline is a small slice of the fit score and
    // reviewing it gates nothing, so a 209-show "unsure" queue is not worth its own top-level pill. He
    // corrects a wrong classification organically from the row when he sees it (the row-level badge stays).
    @Test func statusesNoLongerIncludeUnsure() {
        #expect(AgentRoster.statuses(calm).contains { $0.name == "Unsure" } == false)
    }

    // Dan (2026-07-18): OmniFocus sync health used to have its own pill here (#357), redundant with the toolbar's
    // own OmniFocus button (its live "Syncing…" state, and the separate "sync failing" warning it
    // already shows). Dan's call: the toolbar button is the only access point now.
    @Test func statusesNoLongerIncludeOmniFocus() {
        #expect(AgentRoster.statuses(calm).contains { $0.name == "OmniFocus" } == false)
    }

    // #1134: Reached out is its own stage now, always present in the strip so Dan can navigate to it. It
    // is informational (never "needs you"): the people actually due for a nudge surface under Follow-ups.
    @Test func reachedOutIsAlwaysPresentAndNeverNeedsYou() {
        var i = calm; i.reachedOut = 5
        let s = status("Reached out", i)
        #expect(s.focus == .reachedOut)
        #expect(s.state == .idle)                 // never gold/rust: it is not attention
        #expect(s.detail == "5")                  // the count Dan sees, which the reached-out view matches
        #expect(AgentRoster.needsYouCount(AgentRoster.statuses(i)) == 0)
    }

    // With no one reached out yet, the pill still appears (a navigation stop) but carries no bare "0".
    @Test func reachedOutWithNoOneShowsNoCount() {
        let s = status("Reached out", calm)
        #expect(s.state == .idle)
        #expect(s.detail == "")
    }

    // Tapping Reached out navigates the queue (to its per-recipient list), like every non-action pill.
    @Test func reachedOutChipNavigates() {
        var i = calm; i.reachedOut = 2
        #expect(AgentRoster.chipAction(for: status("Reached out", i)) == .focusOnStage)
    }

    // Its concept sentence is distinct from Follow-ups (waiting to hear back, vs a nudge that is due).
    @Test func reachedOutConceptIsDistinctFromFollowUps() {
        let reached = AgentRoster.conceptSummary(for: "Reached out")
        #expect(reached.contains("hear back"))
        #expect(reached != AgentRoster.conceptSummary(for: "Follow-ups"))
    }

    // #357: what a chip tap actually DOES, pulled out of QueueView's Button closure (the #863 lesson:
    // logic inside a SwiftUI view is untestable) so this dispatch has a seam a test can reach.
    @Test func chipActionRoutesGmailConnectAheadOfEverythingElse() {
        var i = calm; i.readyToSend = 1; i.gmailConnected = false
        #expect(AgentRoster.chipAction(for: status("Send issues", i)) == .connectGmail)
    }

    @Test func chipActionOpensFollowUpsInsteadOfNavigating() {
        var i = calm; i.followUpsDue = 1
        #expect(AgentRoster.chipAction(for: status("Follow-ups", i)) == .showFollowUps)
    }

    @Test func chipActionFocusesTheQueueForEveryOtherPill() {
        var i = calm; i.toTriage = 1
        #expect(AgentRoster.chipAction(for: status("Scout", i)) == .focusOnStage)
        i = calm; i.toReview = 1
        #expect(AgentRoster.chipAction(for: status("Review", i)) == .focusOnStage)
    }
}
