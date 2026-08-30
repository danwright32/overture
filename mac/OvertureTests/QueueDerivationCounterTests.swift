import Testing
import Foundation

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
@Suite("The queue counts its own whole-store derivations (#1774)", .sharesTheRenderCounter)
struct QueueDerivationCounterTests {
    private var queueView: String { SourceGuardHelper.source("Overture/UI/QueueView.swift") }
    // #1913: the derivation moved here, so the guards on its shape moved with it.
    private var renderPass: String { SourceGuardHelper.source("Overture/UI/QueueRenderPass.swift") }

    // #1933: the log is bounded, by the same rotation every other log in this app uses.
    //
    // It appends one line per whole-store derivation and nothing trimmed it, so an afternoon of
    // scrolling, sending and re-prepping wrote thousands of lines and every later run appended to the
    // same file. The diagnostic got harder to read the more it was used, which is backwards, and it
    // was unbounded disk in the directory that also holds the store.
    //
    // Written past the cap deliberately rather than asserting the call is present: the claim is that
    // the file stops growing, and only writing enough to exceed it can show that.
    @Test func theDerivationLogStopsGrowingOnceItPassesTheCap() throws {
        QueueRenderCounter.reset()
        let log = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("derivations-cap-\(UUID().uuidString).log")
        defer {
            try? FileManager.default.removeItem(at: log)
            try? FileManager.default.removeItem(at: log.appendingPathExtension("1"))
        }

        // A file already over the ceiling, which is the state a long-lived install reaches.
        try String(repeating: "x", count: 4_096).write(to: log, atomically: true, encoding: .utf8)

        // underTests: false deliberately. That seam exists to keep the suite out of this Mac's own
        // Debug data directory, and the injected temp path above already does that, so opting in
        // here is what makes the write path the thing under test rather than the seam.
        QueueRenderCounter.recordDerivation(inputs: ["a": "1"], to: log,
                                            underTests: false, maxLogBytes: 1_024)

        let size = try #require((try FileManager.default.attributesOfItem(atPath: log.path))[.size] as? Int)
        #expect(size < 4_096, "the log kept growing past its cap; it is \(size) bytes")

        // And the rotation KEEPS what it trimmed, rather than discarding it. A diagnostic that silently
        // drops the lines just before the interesting moment is worse than one that grows.
        let backup = log.appendingPathExtension("1")
        #expect(FileManager.default.fileExists(atPath: backup.path))
    }

    // The other half, so the cap is known not to be firing constantly: an ordinary small log is left
    // alone, and the line that was just written is still in it.
    @Test func anOrdinaryDerivationLogIsLeftAlone() throws {
        QueueRenderCounter.reset()
        let log = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("derivations-small-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: log) }

        // underTests: false deliberately. That seam exists to keep the suite out of this Mac's own
        // Debug data directory, and the injected temp path above already does that, so opting in
        // here is what makes the write path the thing under test rather than the seam.
        QueueRenderCounter.recordDerivation(inputs: ["a": "1"], to: log,
                                            underTests: false, maxLogBytes: 1_024)

        let text = try String(contentsOf: log, encoding: .utf8)
        #expect(text.contains("#1"))
        #expect(!FileManager.default.fileExists(atPath: log.appendingPathExtension("1").path))
    }

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
        guard let body = SourceGuardHelper.bodyOfFunction(named: "make", in: renderPass) else {
            Issue.record("expected to find the render pass")
            return
        }
        #expect(body.contains("QueueRenderCounter.recordDerivation("))
        // Once per derivation, not once per field of the snapshot.
        #expect(body.components(separatedBy: "QueueRenderCounter.recordDerivation(").count - 1 == 1)
    }

    // Gated out of Release, at both ends: the counter itself and the call that feeds it.
    @Test func theCounterIsDebugOnly() {
        #expect(renderPass.contains("#if DEBUG"))
        guard let body = SourceGuardHelper.bodyOfFunction(named: "make", in: renderPass) else {
            Issue.record("expected to find the render pass")
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
