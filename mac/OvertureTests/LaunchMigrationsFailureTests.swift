import Testing
import Foundation
import SwiftData
import UserNotifications

// #1601 (the scoped production-readiness check on tonight's work): LaunchMigrations caught a failed
// save, returned false, and AppDelegate threw that boolean away. The error was never logged either, so a
// failed launch save was invisible TWICE and every migration silently did nothing.
//
// LIVE-STORE-CLAIM verified=2026-07-27 measure="duplicate title-variant rows the #1590 pass deleted on its first run"
// That was survivable while the launch pass only backfilled fields. It stopped being survivable in
// #1590, which added a pass that DELETES rows: on the live store its first run removes 17 duplicate
// cards. If that save fails, the deletes evaporate, the duplicates come back, and the only symptom is a
// feature that looks like it was never built. "A caught error that never reaches monitoring is invisible
// twice" is the exact shape of LESSONS L13, and the standing rule is fail loud, not silent.
@Suite("A failed launch save is reported, not swallowed (#1601)")
struct LaunchMigrationsFailureTests {
    private struct SaveFailed: Error {}

    // The seam. The save itself belongs to SwiftData and cannot be made to fail on demand from a test,
    // so the decision ABOUT the outcome is extracted and tested directly, rather than skipping the error
    // path because it is awkward to reach.
    @Test func aFailedSaveIsReportedAndAnswersFalse() {
        var reported: [Error] = []
        let ok = LaunchMigrations.persist({ throw SaveFailed() }, report: { reported.append($0) })

        #expect(!ok)
        #expect(reported.count == 1, "the failure has to reach somebody")
    }

    @Test func aSuccessfulSaveReportsNothing() {
        var reported: [Error] = []
        let ok = LaunchMigrations.persist({}, report: { reported.append($0) })

        #expect(ok)
        #expect(reported.isEmpty, "a working launch must never cry wolf")
    }

    // The sentence Dan actually gets. It has to say what did not happen, what he might therefore see,
    // and what to do, without overclaiming that data was lost (nothing is lost: the pass is idempotent
    // and simply runs again next launch).
    @Test func theNoticeSaysWhatHappenedAndWhatToDo() {
        #expect(LaunchMigrationsCopy.saveFailedTitle == "Overture couldn't finish starting up")
        let body = LaunchMigrationsCopy.saveFailedBody
        #expect(body.contains("didn't save"))
        #expect(body.contains("reopen"), "it must tell him the one thing that retries it")
    }

    // The notice goes through the same first-party channel the OmniFocus failures use, so a launch
    // failure is audible rather than a masthead key that needs the window open to see.
    @Test func theNoticeIsPostedThroughTheFirstPartyChannel() {
        var delivered: [UNNotificationRequest] = []
        LaunchMigrations.reportSaveFailure(SaveFailed(), deliver: { delivered.append($0) })

        #expect(delivered.count == 1)
        #expect(delivered.first?.content.title == LaunchMigrationsCopy.saveFailedTitle)
        #expect(delivered.first?.content.body == LaunchMigrationsCopy.saveFailedBody)
    }

    // The pieces working and the pieces being CONNECTED are two claims. The save cannot be made to fail
    // from a test, so nothing else can prove that the real launch path routes its failure into the
    // reporter; this pins that composition at the source, the way #1598's wiring guard does.
    //
    // The reporting deliberately lives inside `run` rather than at the call site: AppDelegate discarded
    // the returned false for as long as it existed, which is exactly how this stayed invisible, and a
    // failure that every caller has to remember to check is a failure that some caller will not.
    @Test func runRoutesAFailedSaveIntoTheReporter() throws {
        let source = try String(contentsOf: RepoRoot.mac
            .appendingPathComponent("Overture/Domain/LaunchMigrations.swift"), encoding: .utf8)
        #expect(source.contains("persist(context.save, report: { reportSaveFailure($0) })"),
                "the launch save's failure path must reach the reporter")
        // #2543: matched as CODE, not as one exact rendering. Pinned to its twelve spaces of
        // indentation, this negative assertion failed in the dangerous direction: reformat the swallowing
        // catch, or write it at any other depth, and the guard passes with the defect present (L103).
        #expect(!SourceGuardHelper.containsCode("catch { return false }", in: source),
                "the swallowing catch this issue removed must not come back")
    }
}
