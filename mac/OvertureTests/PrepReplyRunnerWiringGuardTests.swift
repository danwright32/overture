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

    // Matches a real sourcing LINE, not merely a mention: every runner also names its lib files in header
    // comments, so a bare `contains("scout-cancel.sh")` would stay green even if the actual `.` line were
    // deleted (the same reasoning as ScoutProgressWiringGuardTests).
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
        guard let heartbeatRange = prep.range(of: "while :; do") else {
            Issue.record("heartbeat loop not found in prep-run.sh")
            return
        }
        let nearby = prep[heartbeatRange.lowerBound...].prefix(800)
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
        #expect(rootView.contains("Cancel prep"))                       // the control exists
        #expect(rootView.contains("PrepQueueService.requestCancel()"))  // and it asks the run to stop
    }

    @Test func theReplyDrafterCancelWritesTheSentinel() {
        #expect(!factory.isEmpty)
        #expect(!draftReview.isEmpty)
        // The reply-drafter flow shows a Cancel beside its "Drafting a reply" label...
        #expect(draftReview.contains("onCancelReplyDraft"))
        // ...and that closure asks the reply-classify run to stop.
        #expect(factory.contains("ReplyClassifyService.requestCancel()"))
    }
}
