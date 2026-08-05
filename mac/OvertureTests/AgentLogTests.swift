import Testing
import Foundation

// #1689: the menu bar said "Agent logged an error" and there was no error. The log it was reading held
// 20 lines, every one of them a migration reporting that it had correctly left Dan's rows alone, and
// the nudge fired because the FILE had grown, not because anything in it was a failure.
//
// Reading the text back would not have saved it. The one line in that log Dan genuinely needed
// ("reachability probe settled with 1 of 5 shows answered; 4 were never reached and stay unchecked")
// contains no word like error, failed or crash, so a classifier scanning for those would have gone on
// ignoring the only line that mattered while still flagging the chatter (L11: a message may claim only
// what its check actually measured).
//
// So the line says what it is when it is written, because only the code writing it knows. A problem is
// recorded in a ledger; a note is not, however many of them there are.
@Suite("Every logged line says whether it is a problem (#1689)")
struct AgentLogTests {
    private func tempLedger() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("agentlog-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("problems.log")
    }

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func aProblemIsRecordedInTheLedger() throws {
        let ledger = tempLedger()
        defer { try? FileManager.default.removeItem(at: ledger.deletingLastPathComponent()) }

        AgentLog.write(.problem, "could not stamp 3 probed shows", ledger: ledger, now: now)

        let written = try String(contentsOf: ledger, encoding: .utf8)
        #expect(written.contains("could not stamp 3 probed shows"))
    }

    // The whole defect, as a test: routine reports are the bulk of what the app writes, and no number of
    // them may ever add up to "something is wrong".
    @Test func noVolumeOfNotesEverReachesTheLedger() throws {
        let ledger = tempLedger()
        defer { try? FileManager.default.removeItem(at: ledger.deletingLastPathComponent()) }

        for i in 0..<50 {
            AgentLog.write(.note, "#1590 SameNightTitleVariantMerge: \(i) rows carry outreach history",
                           ledger: ledger, now: now)
        }

        #expect(!FileManager.default.fileExists(atPath: ledger.path))
    }

    @Test func problemsAppendRatherThanReplaceEachOther() throws {
        let ledger = tempLedger()
        defer { try? FileManager.default.removeItem(at: ledger.deletingLastPathComponent()) }

        AgentLog.write(.problem, "the launch save failed", ledger: ledger, now: now)
        AgentLog.write(.problem, "Gmail signature fetch failed", ledger: ledger, now: now)

        let written = try String(contentsOf: ledger, encoding: .utf8)
        #expect(written.contains("the launch save failed"))
        #expect(written.contains("Gmail signature fetch failed"))
        #expect(written.split(separator: "\n").count == 2)
    }

    // A ledger of problems with no times in it cannot answer "when did this start", which is the first
    // question anyone asks of it.
    @Test func eachRecordedProblemCarriesWhenItHappened() throws {
        let ledger = tempLedger()
        defer { try? FileManager.default.removeItem(at: ledger.deletingLastPathComponent()) }

        AgentLog.write(.problem, "could not record 4 organisation answers", ledger: ledger, now: now)

        let written = try String(contentsOf: ledger, encoding: .utf8)
        #expect(written.contains("2023-11-14"))
    }

    // The ledger's own directory may not exist yet (a fresh install writes its first problem before
    // anything else has been there), and a problem that cannot be recorded is a problem Dan never hears
    // about at all.
    @Test func aProblemIsRecordedEvenWhenTheDirectoryIsNotThereYet() throws {
        let ledger = tempLedger()
        defer { try? FileManager.default.removeItem(at: ledger.deletingLastPathComponent()) }
        #expect(!FileManager.default.fileExists(atPath: ledger.deletingLastPathComponent().path))

        AgentLog.write(.problem, "the launch save failed", ledger: ledger, now: now)

        #expect(try String(contentsOf: ledger, encoding: .utf8).contains("the launch save failed"))
    }

    // #2003: THE guard. Every test above hands AgentLog a throwaway file, so none of them can see the
    // defect: app code exercised BY a test calls AgentLog.problem with no ledger argument at all, takes
    // the live default, and writes into the file the menu bar reads. Measured on 2026-08-04, that file
    // held 443 KB of which 112 lines came from the test target's own stub error.
    //
    // This calls it the way production code does, with no ledger argument, from inside a test run.
    // Asserting on the CONTENT rather than the file's size, so an unrelated write by a real Overture
    // running alongside can never turn this red for the wrong reason.
    @Test func aProblemRaisedDuringATestRunNeverReachesTheLedgerTheMenuBarReads() throws {
        let sentinel = "2003 guard sentinel \(UUID().uuidString)"

        AgentLog.problem(sentinel)

        let live = (try? String(contentsOf: AgentLogLocation.problemsURL, encoding: .utf8)) ?? ""
        #expect(!live.contains(sentinel))
    }

    // And the other half of the same claim: it is redirected, not dropped. A problem the app raises
    // while a test is exercising it is still worth being able to read, and a guard that silently
    // stopped all of it would look identical from the live file alone (L11).
    @Test func aProblemRaisedDuringATestRunIsStillRecordedSomewhereReadable() throws {
        let sentinel = "2003 redirect sentinel \(UUID().uuidString)"

        AgentLog.problem(sentinel)

        let redirected = try String(contentsOf: AgentLogLocation.testRunLedgerURL, encoding: .utf8)
        #expect(redirected.contains(sentinel))
    }
}
