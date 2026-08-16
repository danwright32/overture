import Testing
import Foundation

// #1023 / #1038: the progress and cancel wiring for the Prep and reply-classify runs spans several files
// whose behavior is unit-tested elsewhere (the sentinel API in PrepReplyCancelServiceTests, the shell
// predicates in lib/scout-cancel.test.sh, the derive in lib/progress-watcher.test.sh). What no behavioral
// test can see is whether those pieces are actually CONNECTED in the runner scripts and the UI: that
// prep-run.sh really derives its count from the results file and no longer asks the model to self-report
// one, that both runners honour the cancel sentinel on a short poll, and that the app's Cancel controls
// actually write the sentinel. A guard and its wiring are two separate claims (#887); this pins the wiring
// so a silent disconnect (a Cancel that does nothing, a count that sits stuck) cannot slip through.
@MainActor
@Suite("Prep and reply-classify progress + cancel wiring (#1023, #1038)")
struct PrepReplyRunnerWiringGuardTests {
    private func source(_ relativeFromMac: String, file: StaticString = #filePath) -> String {
        SourceGuardHelper.source(relativeFromMac, file: file)
    }

    private var prep: String { source("scripts/prep-run.sh") }
    private var reply: String { source("scripts/reply-classify-run.sh") }
    private var rootView: String { source("Overture/App/RootView.swift") }
    private var factory: String { source("Overture/UI/ProspectRowFactory.swift") }
    private var draftReview: String { source("Overture/UI/DraftReviewView.swift") }
    // #2127: the reply surface moved OUT of DraftReviewView into a standalone view shared with the
    // reached-out queue, so the assertions about the per-recipient drafting label follow it here. Pinned
    // by path for the same reason the others are: a source guard is only as good as the file it reads.
    private var replyConversation: String { source("Overture/UI/ReplyConversationView.swift") }
    private var queueView: String { source("Overture/UI/QueueView.swift") }
    private var replyRunLine: String { source("Overture/UI/ReplyRunLine.swift") }

    // Matches a real sourcing LINE, not merely a mention: every runner also names its lib files in header
    // comments, so a bare `contains("scout-cancel.sh")` would stay green even if the actual `.` line were
    // deleted (the same reasoning as RunProgressWiringGuardTests).
    private func sources(_ libName: String, in body: String) -> Bool {
        body.split(separator: "\n").contains { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix("#"), t.contains(libName) else { return false }
            return t.hasPrefix(". ") || t.hasPrefix("source ")
        }
    }

    // --- #1023: prep derives its own progress, the model never self-reports it ----------------------

    @Test func prepSourcesTheProgressWatcher() {
        #expect(!prep.isEmpty)
        #expect(sources("progress-watcher.sh", in: prep))
    }

    // The heartbeat loop (the only thing ticking while claude is alive) actually CALLS the deriving
    // function, not just sources the file that defines it. The derive sits behind marker_due deeper in the
    // loop body (#1053's short-poll structure), so the window is generous.
    @Test func prepHeartbeatDerivesProgressEachTick() throws {
        // #2106: scoped to the heartbeat loop's own body rather than a fixed character
        // count after its header. The count was a proxy for the loop, and it expired the
        // way a proxy does: it had 34 characters of headroom, so an edit INSIDE the loop
        // pushed the guarded call past it while the wiring was untouched (L63).
        guard let nearby = SourceGuardHelper.between("while :; do", and: "done )", in: prep) else {
            Issue.record("heartbeat loop not found in prep-run.sh")
            return
        }
        #expect(nearby.contains("update_progress_from_results"))
    }

    // A final derive after claude exits, so the last stretch of work between the previous tick and process
    // exit is not left showing a stale count once the run is over.
    @Test func prepDerivesOnceMoreAfterClaudeExits() throws {
        guard let claudeRange = prep.range(of: "\"$CLAUDE\" -p") else {
            Issue.record("claude invocation not found in prep-run.sh")
            return
        }
        let after = prep[claudeRange.upperBound...]
        #expect(after.contains("update_progress_from_results"))
    }

    // The model is never asked to overwrite the progress file itself anymore: an instruction it can simply
    // forget (as scout's did on 2026-07-16) is worth nothing once the script derives the truth on its own.
    @Test func prepNeverAsksTheModelToWriteTheProgressFile() {
        #expect(!prep.contains("overwrite $PROGRESS"))
        #expect(!prep.contains("overwrite \\$PROGRESS"))
    }

    // --- #1081: reply-classify derives its own progress, the model never self-reports it ------------

    @Test func replySourcesTheProgressWatcher() {
        #expect(!reply.isEmpty)
        #expect(sources("progress-watcher.sh", in: reply))
    }

    // The heartbeat loop (the only thing ticking while claude is alive) actually CALLS the deriving
    // function, not just sources the file that defines it. The derive sits behind marker_due deeper in
    // the loop body (#1053's short-poll structure), so the window is generous.
    @Test func replyHeartbeatDerivesProgressEachTick() throws {
        // #2106: scoped to the heartbeat loop's own body rather than a fixed character
        // count after its header. The count was a proxy for the loop, and it expired the
        // way a proxy does: it had 34 characters of headroom, so an edit INSIDE the loop
        // pushed the guarded call past it while the wiring was untouched (L63).
        guard let nearby = SourceGuardHelper.between("while :; do", and: "done )", in: reply) else {
            Issue.record("heartbeat loop not found in reply-classify-run.sh")
            return
        }
        #expect(nearby.contains("update_progress_from_results"))
    }

    // A final derive after claude exits, so the last stretch of work between the previous tick and
    // process exit is not left showing a stale count once the run is over.
    @Test func replyDerivesOnceMoreAfterClaudeExits() throws {
        guard let claudeRange = reply.range(of: "\"$CLAUDE\" -p") else {
            Issue.record("claude invocation not found in reply-classify-run.sh")
            return
        }
        let after = reply[claudeRange.upperBound...]
        #expect(after.contains("update_progress_from_results"))
    }

    // The model is never asked to overwrite the progress file itself: an instruction it can simply
    // forget (as scout's did on 2026-07-16) is worth nothing once the script derives the truth on its own.
    @Test func replyNeverAsksTheModelToWriteTheProgressFile() {
        #expect(!reply.contains("overwrite $PROGRESS"))
        #expect(!reply.contains("overwrite \\$PROGRESS"))
    }

    // #1085: the run's "N of M" is a single run-wide fact, so it moved OUT of the per-recipient
    // "Drafting a reply" label (where it repeated on every drafting row) and into ONE run-level line at
    // the top of the queue. This pins the move both ways so neither half can silently regress: the
    // per-recipient label no longer carries the count, and the run-level line reads the derived
    // progress through the pure, tested runningLabel. It reads through loadCurrent() inside the run's
    // freshness check so the whole line re-reads each tick (#1003), never a value the enclosing view
    // captured at its last render. The behavior of what the line SAYS is covered in
    // ReplyClassifyProgressContractTests.runningLabel*.
    // #1923: the line is its own view now (ReplyRunLine), so that is where the reading lives.
    @Test func theRunLevelLineReadsTheProgressFileAndThePerRecipientLabelNoLongerDoes() {
        #expect(!replyConversation.isEmpty)
        #expect(!replyRunLine.isEmpty)
        // The per-recipient label dropped the run-wide count...
        // #2143: anchored on the shared constant, since the reply panel says this too and the two
        // surfaces now read the words from one place instead of spelling them separately.
        guard let labelRange = replyConversation.range(of: "LiveRunLabel(base: ReplyPanelCopy.drafting") else {
            Issue.record("reply drafter LiveRunLabel not found")
            return
        }
        // Generous window (the label spans several argument lines plus an explanatory comment), so an
        // added note near the label can't push the assertion out of view.
        let nearby = replyConversation[labelRange.lowerBound...].prefix(900)
        #expect(!nearby.contains("progressDetail:"))
        // ...and the run-level line now reads the derived count, gated on a live run and re-read each tick.
        #expect(replyRunLine.contains("ReplyClassifyProgressDecoder.runningLabel("))
        #expect(replyRunLine.contains("ReplyClassifyProgressDecoder.loadCurrent()"))
        #expect(replyRunLine.contains("running: activity.isRunning"))
    }

    // #1923: the tick exists only INSIDE a live run. The line used to run its one-second TimelineView for
    // as long as the window was open, stat'ing the run marker on every tick of an app doing nothing, and
    // the shape that fixed it is a structural one no behavioral test can see: the timer sits inside the
    // `if`, so an idle queue builds no timer at all rather than building one that decides to render
    // nothing. DetachedRunActivityTests covers what the activity itself costs.
    @Test func theRunLineRunsNoTimerUntilARunIsLive() {
        guard let body = SourceGuardHelper.propertyBody("struct ReplyRunLine: View {", in: replyRunLine) else {
            Issue.record("expected to find ReplyRunLine")
            return
        }
        guard let gate = body.range(of: "if activity.isRunning {"),
              let timer = body.range(of: "TimelineView(") else {
            Issue.record("expected the timer to sit behind the live-run gate")
            return
        }
        #expect(gate.upperBound < timer.lowerBound)
        // And nothing here asks the filesystem whether a run is alive: that is the poll this removed.
        #expect(!replyRunLine.contains("ReplyClassifyService.isRunning"))
    }

    // The other half of the same removal: the completion watcher (what ingests a finished run's drafts)
    // used to stat the same marker every three seconds forever. It waits to be told now, and the ingest
    // runs only when a run was genuinely followed to its end.
    @Test func theCompletionWatcherWaitsForARunInsteadOfPollingForOne() {
        #expect(!rootView.isEmpty)
        guard let body = SourceGuardHelper.propertyBody("private func watchReplyClassifyRuns() async {",
                                                        in: rootView) else {
            Issue.record("expected to find watchReplyClassifyRuns")
            return
        }
        #expect(body.contains("for await _ in activity.runStarts()"))
        #expect(body.contains("if await activity.followUntilFinished()"))
        #expect(!body.contains("ReplyClassifyService.isRunning"))
        #expect(!body.contains("Task.sleep"))
    }

    // --- #1038: both runners honour the cancel sentinel on a short poll -----------------------------

    @Test func prepHonoursTheCancelSentinelOnItsHeartbeat() {
        #expect(!prep.isEmpty)
        #expect(sources("scout-cancel.sh", in: prep))   // it sources the predicates
        #expect(prep.contains("cancel_requested"))       // and checks the sentinel in the heartbeat
        #expect(prep.contains("clear_cancel"))           // and clears it so a stopped run cannot kill the next
        #expect(prep.contains("sleep \"$CANCEL_POLL\"")) // read on a short poll, not the 60s marker cadence
        #expect(prep.contains("marker_due"))             // the 60s work is gated behind it
    }

    @Test func replyClassifyHonoursTheCancelSentinelOnItsHeartbeat() {
        #expect(!reply.isEmpty)
        #expect(sources("scout-cancel.sh", in: reply))
        #expect(reply.contains("cancel_requested"))
        #expect(reply.contains("clear_cancel"))
        #expect(reply.contains("sleep \"$CANCEL_POLL\""))
        #expect(reply.contains("marker_due"))
    }

    // --- #1038: the UI Cancel controls actually request the stop ------------------------------------

    @Test func rootViewPrepCancelWritesTheSentinel() {
        #expect(!rootView.isEmpty)
        // #2614: the label is the RUN's own name now, so the control is found by the value that names
        // it rather than by a literal that only ever matched the Prep spelling and would have to be
        // rewritten for every kind of run (L103).
        #expect(rootView.contains("kind.cancelLabel"))                  // the control exists
        #expect(RunKind.prep.cancelLabel == "Cancel prep")              // and still says this for a prep
        #expect(rootView.contains("PrepQueueService.requestCancel(slot: slot)"))  // and it asks the run to stop
    }

    @Test func theReplyDrafterCancelWritesTheSentinel() {
        #expect(!factory.isEmpty)
        #expect(!replyConversation.isEmpty)
        // The reply-drafter flow shows a Cancel beside its "Drafting a reply" label...
        #expect(replyConversation.contains("onCancelReplyDraft"))
        // ...and that closure asks the reply-classify run to stop.
        #expect(factory.contains("ReplyClassifyService.requestCancel()"))
    }
}
