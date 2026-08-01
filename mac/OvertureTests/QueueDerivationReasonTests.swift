import Testing
import Foundation
@testable import Overture

// #1930: the diagnostic that turns "the idle queue re-derived twice" into "and this is what moved".
//
// The count added in #1774 proves an idle window is doing work, and says nothing about why. Reading the
// code to eliminate candidates is what produced #1930's own list, and two of its three entries were wrong
// on this Mac (the reconcile timer sits at its 30 minute default and the Downbeat export had not been
// written that day), so the third cannot be trusted either. This reports, per derivation, which of the
// inputs the queue derives from actually moved.
//
// The rule it reports by is pure and tested here, because a diagnostic used to judge everything else is
// the last thing that should be taken on trust.
@Suite("Each derivation says which of its inputs moved (#1930)")
struct QueueDerivationReasonTests {
    @Test func theFirstRenderHasNothingToCompareAgainst() {
        #expect(QueueRenderCounter.reason(for: ["prospects": "724"], since: [:])
                == QueueRenderCounter.firstRender)
    }

    // The answer that matters most: every input identical means the invalidation came from outside this
    // view entirely, which is a different investigation from any of the candidates named so far.
    @Test func identicalInputsSaySoExplicitly() {
        let inputs = ["prospects": "724", "gmail": "true"]
        #expect(QueueRenderCounter.reason(for: inputs, since: inputs) == QueueRenderCounter.nothingVisible)
    }

    @Test func everyInputThatMovedIsNamed() {
        let before = ["prospects": "724", "gmail": "true", "stage": "scout"]
        let after = ["prospects": "725", "gmail": "true", "stage": "review"]
        #expect(QueueRenderCounter.reason(for: after, since: before) == "prospects, stage")
    }

    // An input that stops being reported changed too. Dropping it silently would report an unchanged
    // render for one that was not the same shape at all.
    @Test func anInputThatDisappearedCountsAsMoved() {
        #expect(QueueRenderCounter.reason(for: ["prospects": "724"],
                                          since: ["prospects": "724", "departing": "1"]) == "departing")
    }

    @Test func recordingCountsAndRemembersWhatItSaw() throws {
        let log = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("derivations-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: log) }
        QueueRenderCounter.reset()

        QueueRenderCounter.recordDerivation(inputs: ["prospects": "724"], to: log)
        #expect(QueueRenderCounter.derivations == 1)
        #expect(QueueRenderCounter.lastReason == QueueRenderCounter.firstRender)

        QueueRenderCounter.recordDerivation(inputs: ["prospects": "724"], to: log)
        #expect(QueueRenderCounter.derivations == 2)
        #expect(QueueRenderCounter.lastReason == QueueRenderCounter.nothingVisible)

        QueueRenderCounter.recordDerivation(inputs: ["prospects": "725"], to: log)
        #expect(QueueRenderCounter.lastReason == "prospects")

        QueueRenderCounter.reset()
        #expect(QueueRenderCounter.derivations == 0)
        #expect(QueueRenderCounter.lastReason == QueueRenderCounter.firstRender)
    }

    // Catching an idle trigger means leaving the app alone and reading what happened afterwards, so the
    // line has to actually reach the file, and a second one must not overwrite the first.
    @Test func everyDerivationAppendsALineToTheLog() throws {
        let log = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("derivations-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: log) }
        QueueRenderCounter.reset()

        QueueRenderCounter.recordDerivation(inputs: ["prospects": "724"], to: log)
        QueueRenderCounter.recordDerivation(inputs: ["prospects": "725"], to: log)

        let written = try String(contentsOf: log, encoding: .utf8)
        let lines = written.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].contains("#1 \(QueueRenderCounter.firstRender)"))
        #expect(lines[1].contains("#2 prospects"))
    }

    // A write that cannot land says so where the count is read, rather than leaving an empty log to be
    // mistaken for an idle queue that never re-derived at all.
    @Test func aFailedLogWriteIsReportedNotSwallowed() {
        QueueRenderCounter.reset()
        let unwritable = URL(fileURLWithPath: "/System/Overture-should-never-be-writable/derivations.log")

        QueueRenderCounter.recordDerivation(inputs: ["prospects": "724"], to: unwritable)

        #expect(QueueRenderCounter.lastReason.contains("failed"))
        #expect(QueueRenderCounter.derivations == 1)
    }
}
