import Testing
import Foundation
import SwiftUI
import ViewInspector
@testable import Overture

// #1081: the Swift reader half of the reply-classify progress contract. The WRITER is
// mac/scripts/reply-classify-run.sh (seeds total/completed:0, then derives completed from the results
// file's own entry count via lib/progress-watcher.sh), which is not Swift, so there is no second
// programmatic side to assert. This fixture pins the Swift decode and is the canonical example the
// runbook points the run at. Mirrors PrepProgressContractTests (#354).
@MainActor
@Suite("Reply-classify progress contract fixtures (#1081)")
struct ReplyClassifyProgressContractTests {
    private func fixtureDirectory() -> URL {
        RepoRoot.url
            .appendingPathComponent("fixtures/reply-classify-progress")
    }

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: fixtureDirectory().appendingPathComponent(name))
    }

    private func fixtureFileNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: fixtureDirectory().path)
            .filter { $0.hasSuffix(".json") }
    }

    // #491/#744: enumerates whatever is actually committed, so a new fixture file with no matching
    // decode case fails here instead of silently shipping with zero coverage on this side.
    @Test func decodesEveryCommittedFixtureWithoutThrowing() throws {
        let names = try fixtureFileNames()
        #expect(!names.isEmpty)
        for name in names {
            let data = try fixture(name)
            #expect(throws: Never.self) {
                try ReplyClassifyProgressDecoder.decode(data)
            }
        }
    }

    @Test func decodesTheV1Fixture() throws {
        let progress = try ReplyClassifyProgressDecoder.decode(try fixture("v1.json"))
        #expect(progress.version == 1)
        #expect(progress.total == 5)
        #expect(progress.completed == 2)
    }

    @Test func labelFormatsAsNOfM() throws {
        let progress = try ReplyClassifyProgressDecoder.decode(try fixture("v1.json"))
        #expect(ReplyClassifyProgressDecoder.label(for: progress) == "2 of 5")
    }

    @Test func labelClampsAStrayExtraEntryToTotal() {
        let progress = ReplyClassifyProgress(version: 1, total: 5, completed: 7)
        #expect(ReplyClassifyProgressDecoder.label(for: progress) == "5 of 5")
    }

    @Test func labelIsNilWhenTotalIsZero() {
        let progress = ReplyClassifyProgress(version: 1, total: 0, completed: 0)
        #expect(ReplyClassifyProgressDecoder.label(for: progress) == nil)
    }

    @Test func labelIsNilForNoProgress() {
        #expect(ReplyClassifyProgressDecoder.label(for: nil) == nil)
    }

    // MARK: - #1085: one run-level line, not the count repeated on every drafting recipient row.

    @Test func runningLabelReadsAsARunLevelSentence() {
        let progress = ReplyClassifyProgress(version: 1, total: 5, completed: 2)
        #expect(ReplyClassifyProgressDecoder.runningLabel(running: true, progress: progress)
            == "Drafting replies 2 of 5")
    }

    // A stale count from a finished run must not linger at the top of the queue: no live run, no line.
    @Test func runningLabelIsNilWhenNoRunIsAlive() {
        let progress = ReplyClassifyProgress(version: 1, total: 5, completed: 2)
        #expect(ReplyClassifyProgressDecoder.runningLabel(running: false, progress: progress) == nil)
    }

    // A run alive with no meaningful count yet (total 0, or the file not written) shows no run-level
    // line; the per-recipient rows still carry the alive spinner, so aliveness is not lost.
    @Test func runningLabelIsNilWhenThereIsNoCountYet() {
        #expect(ReplyClassifyProgressDecoder.runningLabel(
            running: true, progress: ReplyClassifyProgress(version: 1, total: 0, completed: 0)) == nil)
        #expect(ReplyClassifyProgressDecoder.runningLabel(running: true, progress: nil) == nil)
    }

    // The run-level line clamps the same way the per-recipient one does: a stray extra results entry
    // can never read as more drafted than were ever queued.
    @Test func runningLabelClampsAStrayExtraEntryToTotal() {
        let progress = ReplyClassifyProgress(version: 1, total: 5, completed: 7)
        #expect(ReplyClassifyProgressDecoder.runningLabel(running: true, progress: progress)
            == "Drafting replies 5 of 5")
    }

    // Best-effort: a missing or malformed file reads as "nothing to show", never a crash or thrown
    // error surfaced to the label (the run may be mid-write when the label polls).
    @Test func loadCurrentReturnsNilForAMissingFile() {
        let missing = URL(fileURLWithPath: "/tmp/overture-reply-classify-progress-missing-\(UUID()).json")
        #expect(ReplyClassifyProgressDecoder.loadCurrent(from: missing) == nil)
    }

    @Test func loadCurrentReturnsNilForMalformedJSON() throws {
        let url = URL(fileURLWithPath: "/tmp/overture-reply-classify-progress-malformed-\(UUID()).json")
        try Data("{not valid json".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(ReplyClassifyProgressDecoder.loadCurrent(from: url) == nil)
    }

    // MARK: - Negative paths (#747): a guard that cannot fail is not a guard.

    private func decoding(_ json: String) throws -> ReplyClassifyProgress {
        try ReplyClassifyProgressDecoder.decode(Data(json.utf8))
    }

    @Test func aProgressFileMissingARequiredCountIsRejected() {
        #expect(throws: (any Error).self) { try decoding(#"{"version":1,"total":10}"#) }
        #expect(throws: (any Error).self) { try decoding(#"{"version":1,"completed":3}"#) }
        #expect(throws: (any Error).self) { try decoding(#"{"total":10,"completed":3}"#) }
    }

    @Test func aCountOfTheWrongTypeIsRejectedRatherThanCoercedToZero() {
        #expect(throws: (any Error).self) {
            try decoding(#"{"version":1,"total":"10","completed":"3"}"#)
        }
    }

    // The strict layer throws; the best-effort layer stays silent. Both, on the same bad bytes.
    @Test func theLabelDegradesToNothingToShowOnTheSameBytesTheContractRejects() throws {
        let torn = #"{"version":1,"total":10,"comple"#   // a half-written file, mid-flush

        #expect(throws: (any Error).self) { try decoding(torn) }

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("reply-classify-progress-torn-\(UUID().uuidString).json")
        try Data(torn.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(ReplyClassifyProgressDecoder.loadCurrent(from: url) == nil)
    }

    // The count the reply drafter's LiveRunLabel actually BINDS to. #1003 made progressDetail a closure
    // so the label re-reads the run's progress each tick; here that closure reads the decoder against a
    // real file, and the label's caption must carry the derived "N of M". Proves the value the view
    // shows is the one the decoder produced, not a hard-coded string, exercising the real binding rather
    // than only the pure decoder.
    @Test func theReplyDrafterLabelShowsTheDerivedCount() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("reply-classify-progress-bind-\(UUID().uuidString).json")
        try Data(#"{"version":1,"total":5,"completed":2}"#.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let since = Date(timeIntervalSince1970: 1000)
        let now = Date(timeIntervalSince1970: 1010)
        let label = LiveRunLabel(
            base: "Drafting a reply", since: since, timeout: 60,
            progressDetail: { ReplyClassifyProgressDecoder.label(for: ReplyClassifyProgressDecoder.loadCurrent(from: url)) })

        let caption = try label.content(now: now).inspect()
            .find(ViewType.Text.self).string()
        #expect(caption.contains("2 of 5"))
        #expect(caption == RunProgress.spinnerLabel("Drafting a reply", since: since, now: now, detail: "2 of 5"))
    }
}
