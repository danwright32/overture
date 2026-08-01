import Testing
import Foundation
@testable import Overture

// #1774: the diagnostic that makes the fix checkable instead of a feeling.
//
// Neither this issue nor its scoping comment contained a single measured number, and the acceptance
// criterion was a person saying the queue felt smooth. That is how a performance change ships and nobody
// can say six months later whether it helped, or whether it has since regressed.
//
// Worse, the walk that was supposed to verify this change could not distinguish success from a no-op: if
// a scroll still re-derived, scrolling would still be smooth-ish on a small stage, the position would
// still hold across a scout, and a deep link would still land. All three steps pass either way. A count
// that does not move while scrolling is the only observation that separates them.
//
// DEBUG only. In Release this is a counter nobody reads, ticking shared mutable state on the main thread
// for no reason, so its absence there is part of the rule rather than an accident of where it was written.
@Suite("The queue counts its own whole-store derivations (#1774)")
struct QueueDerivationCounterTests {
    private var queueView: String { SourceGuardHelper.source("Overture/UI/QueueView.swift") }

    // It counts, and it can be reset, so a walk can zero it and scroll rather than doing arithmetic on
    // whatever number the launch left behind.
    @Test func theCounterCountsAndResets() {
        QueueRenderCounter.reset()
        #expect(QueueRenderCounter.derivations == 0)

        // #1930: the log destination is injected so the suite does not append to this Mac's own Debug
        // data directory on every run.
        let log = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("counter-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: log) }
        QueueRenderCounter.recordDerivation(inputs: ["a": "1"], to: log)
        QueueRenderCounter.recordDerivation(inputs: ["a": "2"], to: log)
        #expect(QueueRenderCounter.derivations == 2)

        QueueRenderCounter.reset()
        #expect(QueueRenderCounter.derivations == 0)
    }

    // The one place that may count is the one place that derives. Counting anywhere else would report a
    // number that is not the thing under test.
    @Test func onlyTheWholeStoreDerivationIsCounted() {
        guard let body = SourceGuardHelper.propertyBody("private func makeRenderData() -> RenderData {",
                                                        in: queueView) else {
            Issue.record("expected to find makeRenderData's body")
            return
        }
        #expect(body.contains("QueueRenderCounter.recordDerivation("))
        // Once per derivation, not once per field of the snapshot.
        #expect(body.components(separatedBy: "QueueRenderCounter.recordDerivation(").count - 1 == 1)
    }

    // Gated out of Release, at both ends: the counter itself and the call that feeds it.
    @Test func theCounterIsDebugOnly() {
        #expect(queueView.contains("#if DEBUG"))
        guard let body = SourceGuardHelper.propertyBody("private func makeRenderData() -> RenderData {",
                                                        in: queueView) else {
            Issue.record("expected to find makeRenderData's body")
            return
        }
        guard let callIndex = body.range(of: "QueueRenderCounter.recordDerivation(")?.lowerBound else {
            Issue.record("expected the recordDerivation call")
            return
        }
        let before = body[body.startIndex..<callIndex]
        // The nearest preceding conditional-compilation directive opens a DEBUG block rather than closing
        // one, so the call cannot be sitting outside it.
        #expect(before.contains("#if DEBUG"))
        #expect(before.range(of: "#if DEBUG", options: .backwards)!.lowerBound
                > (before.range(of: "#endif", options: .backwards)?.lowerBound ?? before.startIndex))
    }
}
