import Testing
import Foundation
@testable import Overture

// #1114: the per-source movement log #913 tunes against. The line format is pure (testable, #863); the
// file write is best-effort and, for the default log, suppressed under tests so a test run never injects
// fake movement into Dan's real evidence file.
@Suite("Feed movement log (#1114)")
struct FeedMovementLogTests {
    private let when = Date(timeIntervalSince1970: 1_784_000_000)

    // One parseable record: the source, its current and previous scout counts, the delta, and the baseline.
    @Test func lineRecordsCountsDeltaAndBaseline() {
        let line = FeedMovementLog.line(sourceId: "carnegie", org: "Carnegie Hall",
                                        current: 28, previous: 30, baseline: 30, now: when)
        #expect(line.contains("source=carnegie org=\"Carnegie Hall\" current=28 previous=30 delta=-2 baseline=30"))
        #expect(line.hasPrefix(ISO8601DateFormatter().string(from: when)))
    }

    // Delta is current minus previous: positive when the calendar grew.
    @Test func deltaIsCurrentMinusPrevious() {
        let line = FeedMovementLog.line(sourceId: "s", org: "O", current: 40, previous: 30, baseline: 30, now: when)
        #expect(line.contains("current=40 previous=30 delta=10"))
    }

    // Read straight off a source, it uses the PREVIOUS scout's stored count and baseline, so it must be
    // emitted before recordSuccessfulRead overwrites them.
    @Test func lineForSourceReadsStoredPreviousAndBaseline() {
        let s = WatchedSource(sourceId: "org1", orgName: "Org One", kind: .html)
        s.lastReadableCount = 30
        s.baselineFeedCount = 30
        #expect(FeedMovementLog.line(for: s, current: 28, now: when)
            .contains("source=org1 org=\"Org One\" current=28 previous=30 delta=-2 baseline=30"))
    }

    // record(to:) appends a parseable line, creating the file if missing.
    @Test func recordAppendsALineCreatingTheFile() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("feed-movement-test-\(UUID().uuidString).log")
        try? FileManager.default.removeItem(at: tmp)
        FeedMovementLog.record(sourceId: "s", org: "O", current: 5, previous: 4, baseline: 4, now: when, to: tmp)
        FeedMovementLog.record(sourceId: "s", org: "O", current: 6, previous: 5, baseline: 5, now: when, to: tmp)
        let contents = try String(contentsOf: tmp, encoding: .utf8)
        #expect(contents.split(separator: "\n").count == 2)
        #expect(contents.contains("current=6 previous=5 delta=1 baseline=5"))
        try? FileManager.default.removeItem(at: tmp)
    }
}
