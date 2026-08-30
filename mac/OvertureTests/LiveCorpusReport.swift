import Foundation

/// Where the live store corpus line goes, and how it gets to the runner.
///
/// #3276. The line was a `print()` read out of xcodebuild's own output by
/// `mac/scripts/lib/suite-stats.sh`. A parallel worker's stdout does not reach xcodebuild's, so under
/// `-parallel-testing-enabled YES` the suite RAN, passed, and the line appeared zero times in 10,059
/// lines of log. Measured 2026-08-30, against a serial run of the same tree the same day which reported
/// `measuring, over 4 rows the writer-resolution rule can judge and 8 reached-out rows in play`.
///
/// That matters more than a missing line. #2991 built the readout because both invariants had sat at
/// zero for months while passing, and the only thing separating that from a clean bill of health was a
/// printed line thousands of lines up a log nobody reads (L182). Turning parallel testing on would make
/// the readout permanently NOT REPORTED and put the thing #2991 exists to notice back out of sight.
///
/// So the measurement travels by FILE, which a worker process has and stdout is not. Three properties
/// are deliberate:
///
/// * The PATH comes from the runner, never from here. A test must be structurally unable to write into
///   the live tree (L2), and a path only the runner can name is what makes that structural rather than
///   remembered. It is a fresh scratch file per run, so a previous run's numbers can never be read as
///   this one's, which is the failure a fixed path would have.
/// * With no path set, NOTHING is written. That is the ordinary case for a run from Xcode or a raw
///   `xcodebuild`, and such a run has no business leaving a record behind it.
/// * A run that did not MEASURE leaves no line, so an absent file and a measured zero stay different
///   facts. The whole mechanism of #2991 is that a dormant run must not stamp over the last real
///   measurement (L98, L11).
enum LiveCorpusReport {

    /// The environment variable the runner sets. xcodebuild forwards only `TEST_RUNNER_`-prefixed
    /// variables to the test process and strips the prefix, so the runner sets
    /// `TEST_RUNNER_OVERTURE_CORPUS_FILE` and this reads what arrives.
    static let pathVariable = "OVERTURE_CORPUS_FILE"

    /// The sentence, built here so the file and the log carry the SAME text and one parser can read
    /// either. Two spellings of one line is how the file and the fallback would drift apart (L263).
    static func line(shows: Int, replied: Int, open: Int, writerHeld: Int, inPlay: Int) -> String {
        "LIVE STORE CORPUS: \(shows) shows, \(replied) replied rows, "
            + "\(open) with a reply still open, "
            + "\(writerHeld) whose writer a contact holds, "
            + "\(inPlay) reached-out rows in play. "
            + "A zero here means the invariants in this suite ran over nothing."
    }

    /// The path the runner asked for, or nil when it asked for none.
    ///
    /// An EMPTY value is treated as none rather than as the current directory, because a variable set to
    /// nothing is what a shell produces when the thing it was built from was missing.
    static func recordPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard let path = environment[pathVariable], !path.isEmpty else { return nil }
        return path
    }

    /// Writes `line` where the runner asked, and returns whether it wrote. `false` for "nobody asked",
    /// which is not a failure and is the common case outside the runner.
    @discardableResult
    static func record(_ line: String,
                       environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard let path = recordPath(environment: environment) else { return false }
        do {
            try (line + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            return true
        } catch {
            // Deliberately not a test failure. The measurement is a readout, and a run that could not
            // write it should report NOT REPORTED rather than turn a green suite red over a scratch
            // file. The runner's own reading is what says the line is missing.
            return false
        }
    }
}
