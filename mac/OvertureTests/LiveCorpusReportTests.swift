import Testing
import Foundation

// #3276: the corpus measurement reaches the runner by a channel a worker process actually has.
//
// These drive the writer with an INJECTED environment, so none of them depends on how the run was
// invoked and none writes anywhere the runner did not name.
@Suite("The live store corpus line survives a parallel run (#3276)")
struct LiveCorpusReportTests {

    private func scratchFile() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("corpus-report-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("corpus.txt")
    }

    // One sentence, built in one place. The runner parses the file and the log with the SAME rule, so a
    // second spelling of this line is how the two sources would come to report different numbers (L263).
    @Test func thelineNamesEveryCountTheReadoutParses() {
        let line = LiveCorpusReport.line(shows: 1018, replied: 5, open: 0, writerHeld: 4, inPlay: 8)
        #expect(line.hasPrefix("LIVE STORE CORPUS:"),
                "the runner finds the line by this prefix: \(line)")
        #expect(line.contains("4 whose writer a contact holds"),
                "the writer-held count is the one the readout is measured by since #3165: \(line)")
        #expect(line.contains("8 reached-out rows in play"), "\(line)")
        #expect(line.contains("1018 shows"), "\(line)")
    }

    @Test func itwritesWhereTheRunnerAsked() throws {
        let file = try scratchFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let line = LiveCorpusReport.line(shows: 1018, replied: 5, open: 0, writerHeld: 4, inPlay: 8)

        let wrote = LiveCorpusReport.record(line, environment: [LiveCorpusReport.pathVariable: file.path])

        #expect(wrote == .wrote, "the writer reported \(wrote), having been given a usable path")
        let written = try String(contentsOf: file, encoding: .utf8)
        #expect(written.contains(line), "the file does not carry the line: \(written)")
    }

    // The ordinary case outside the runner: a run from Xcode, or a raw `xcodebuild`. Such a run has no
    // business leaving a record behind it, and a writer that picked its own path would be a test writing
    // into the tree (L2).
    @Test func itwritesNothingWhenNobodyAskedForIt() {
        #expect(LiveCorpusReport.recordPath(environment: [:]) == nil,
                "a run with no path set must not choose one")
        #expect(LiveCorpusReport.record("LIVE STORE CORPUS: anything", environment: [:]) == .nobodyAsked,
                "the writer claimed to have written with no path to write to")
    }

    // An EMPTY value is what a shell produces when the thing the path was built from was missing, so it
    // must mean "nobody asked" rather than the current directory (L138).
    @Test func anemptyPathIsNobodyAskingRatherThanAPath() {
        #expect(LiveCorpusReport.recordPath(environment: [LiveCorpusReport.pathVariable: ""]) == nil,
                "an empty path was read as a real one")
        #expect(LiveCorpusReport.record("LIVE STORE CORPUS: anything",
                                        environment: [LiveCorpusReport.pathVariable: ""]) == .nobodyAsked)
    }

    // A path that cannot be written is NOT a test failure: the measurement is a readout, and the runner's
    // own reading is what reports it missing. Turning a green suite red over a scratch file would be the
    // readout deciding the verdict.
    //
    // But it must not look like NOBODY ASKING either. Those are different facts, and a single boolean
    // would leave the readout downstream unable to tell "the suite did not run" from "it ran and could
    // not record what it measured" (L11).
    @Test func anunwritablePathIsToldApartFromNobodyAsking() {
        let outcome = LiveCorpusReport.record("LIVE STORE CORPUS: anything",
                                              environment: [LiveCorpusReport.pathVariable:
                                                              "/no-such-directory-3276/corpus.txt"])
        #expect(outcome != .wrote, "the writer claimed to have written to a path that cannot exist")
        #expect(outcome != .nobodyAsked,
                "a failed write reported itself as nobody having asked, which is a different fact")
        if case .failed = outcome {} else {
            Issue.record("a failed write must say so: \(outcome)")
        }
    }
}
