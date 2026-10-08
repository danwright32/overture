import Testing
import Foundation

// #4315: the load average is read in ONE place, `Phase0` in Phase0Corpus.swift, and waited on through one
// bounded wait beside it. It used to be three copies (`Phase0cRows.oneMinuteLoad` and its wait,
// `Phase0cLinks.oneMinuteLoad`, `loadReading` and `waitForLoad`, and `Phase0.load()`), and they disagreed
// on a failed read: the links copy read it as 0, a quiet Mac, which could let a replay on an unmeasured Mac
// score a PASS (#4314). The next probe copies whichever it finds first (L263, L370), so the last test here
// fails on a second call to the system reader anywhere in the test targets (L613).
//
// Out of scope, deliberately: the production `MainThreadWatchdog` reads the load too, in the APP, with its
// own baseline and elevated classification and its own tests. It is not a test helper and is not scanned.
@Suite("The Phase 0 probes read the load average through one reader (#4315)")
struct Phase0LoadReaderTests {

    // MARK: - The reader

    @Test func aReadingTheSystemDidNotFillIsInfiniteNeverZero() {
        #expect(Phase0.loadReadings(samplesTaken: -1, averages: [0, 0, 0]) == [.infinity, .infinity, .infinity])
        #expect(Phase0.loadReadings(samplesTaken: 0, averages: [0, 0, 0]) == [.infinity, .infinity, .infinity])
        #expect(Phase0.loadReadings(samplesTaken: 1, averages: [2.5, 0, 0]) == [2.5, .infinity, .infinity])
        #expect(Phase0.loadReadings(samplesTaken: 3, averages: [2.5, 3, 4]) == [2.5, 3, 4])
    }

    // The line every probe prints beside a timed block reads exactly as it did before the move.
    @Test func theLoadLineReadsAsItAlwaysDid() {
        #expect(Phase0.loadText([2.5, 3, 4.25]) == "load 2.50 3.00 4.25")
        #expect(Phase0.loadText(Phase0.loadReadings(samplesTaken: -1, averages: [0, 0, 0])) == "load inf inf inf")
        #expect(Phase0.load().hasPrefix("load "))
    }

    // MARK: - The wait

    /// A fake clock the injected sleep advances, so a ten minute wait costs nothing.
    final class FakeClock {
        var now = 1_000.0
        var sleeps: [Double] = []
        func sleep(_ seconds: Double) { sleeps.append(seconds); now += seconds }
    }

    @Test func aLoadThatCannotBeReadNeverEndsTheWaitAsQuiet() {
        let clock = FakeClock()
        let wait = Phase0.waitForLoad(below: 8, deadline: 600, poll: 10, read: { .infinity },
                                      sleep: clock.sleep, clock: { clock.now })
        #expect(wait.load == .infinity)
        #expect(wait.waited == 600)
        #expect(clock.sleeps.count == 60, "the wait ran \(clock.sleeps.count) polls, not the 60 its deadline allows")
        #expect(wait.text == "one minute load inf (under 8: NO, waited 600 s)")
    }

    @Test func aBusyMacThatQuietensEndsTheWaitEarly() {
        let clock = FakeClock()
        var readings = [9.0, 8.0, 3.0]
        let wait = Phase0.waitForLoad(below: 8, deadline: 600, poll: 10, read: { readings.removeFirst() },
                                      sleep: clock.sleep, clock: { clock.now })
        #expect(wait.load == 3)
        #expect(clock.sleeps == [10, 10])
        #expect(wait.text == "one minute load 3.00 (under 8: yes, waited 20 s)")
    }

    @Test func aQuietMacIsNotWaitedOn() {
        let clock = FakeClock()
        let wait = Phase0.waitForLoad(below: 8, deadline: 300, poll: 5, read: { 2 },
                                      sleep: clock.sleep, clock: { clock.now })
        #expect(wait.load == 2)
        #expect(clock.sleeps.isEmpty)
        #expect(wait.waited == 0)
    }

    // MARK: - One reader, and the guard on the next copy

    /// The system call, spelled so this file holds no call of it.
    static let systemReader = "getload" + "avg("

    static let sharedReader = "mac/OvertureTests/Phase0Corpus.swift"

    /// Every `path:line` in `files` that calls the system reader in code rather than a comment.
    static func callSites(in files: [(path: String, source: String)]) -> [String] {
        files.flatMap { file in
            file.source.components(separatedBy: "\n").enumerated().compactMap { index, line -> String? in
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//"), code.contains(systemReader) else { return nil }
                return "\(file.path):\(index + 1)"
            }
        }
    }

    /// Every Swift file in the three places test code lives, repo relative. Walked through
    /// `AppSourceWalk`, which refuses when the three roots together come back under its floor, so a
    /// broken path cannot read as a tree with no stray reader in it (#2311).
    static func testSources() -> [(path: String, source: String)] {
        let root = RepoRoot.url.standardizedFileURL
        let roots = ["mac/OvertureTests", "mac/OvertureHostedTests", "mac/TestSupport"]
            .map { root.appendingPathComponent($0) }
        return AppSourceWalk.files(underAll: roots, floor: AppSourceWalk.appFloor).map { file in
            (String(file.url.standardizedFileURL.path.dropFirst(root.path.count + 1)), file.text)
        }
    }

    @Test func theCallSiteScanFindsACallAndIgnoresAComment() {
        let found = Self.callSites(in: [
            ("A.swift", "let x = 1\n    let taken = " + Self.systemReader + "&l, 3)"),
            ("B.swift", "    // a failed " + Self.systemReader + "&l, 3) reads as infinity"),
        ])
        #expect(found == ["A.swift:2"])
    }

    @Test func noTestCodeReadsTheLoadAverageOutsideTheSharedReader() {
        let sources = Self.testSources()
        // The scan read the tree, or every verdict below is about nothing (L98).
        #expect(sources.count > 100, "scanned only \(sources.count) Swift files in the test targets")
        let sites = Self.callSites(in: sources)
        let shared = sites.filter { $0.hasPrefix(Self.sharedReader + ":") }
        #expect(shared.count == 1, "expected exactly one call of the system reader in \(Self.sharedReader), found \(shared)")
        let elsewhere = sites.filter { !$0.hasPrefix(Self.sharedReader + ":") }
        #expect(elsewhere.isEmpty, """
            test code reads the load average itself at \(elsewhere). Call Phase0.oneMinuteLoad(), \
            Phase0.load() or Phase0.waitForLoad(below:deadline:poll:) instead, so a failed read is \
            infinite everywhere rather than whatever this copy decides (#4315).
            """)
    }
}

// #4615: a probe's reading as the one line `scripts/compare-before-after.sh` reads, so a before and after
// comparison runs in balanced order and pools per side instead of being two runs read by eye. The Swift writer
// and the shell reader are checked against ONE committed fixture, fixtures/probe-reading/lines.txt, which the
// shell fixture feeds through the script's real log parser (L26): a change to either side's idea of the line
// fails here or there rather than leaving the comparison with no readings.
@Suite("A probe reading prints as the line the before and after comparison reads (#4615)")
struct Phase0ProbeLineTests {
    @Test func theLineIsTheMedianUnderItsMetricAsTheSharedFixtureHasIt() throws {
        let fixture = try String(contentsOf: RepoRoot.url.appendingPathComponent("fixtures/probe-reading/lines.txt"),
                                 encoding: .utf8)
        let lines = fixture.split(separator: "\n").map(String.init)
        #expect(lines.count == 4, "the shared fixture holds \(lines.count) line(s), expected 4")
        guard lines.count == 4 else { return }
        #expect(Phase0.Reading(runs: [3, 1, 2]).probeLine("first-draw-4x") == lines[0]) // probe-reading-exempt: the line builder's own test
        #expect(Phase0.Reading(runs: [314.75]).probeLine("memo-derivation-1x") == lines[1]) // probe-reading-exempt: the line builder's own test
        // #4617: the order lines, which the script reads into the same report.
        #expect(Phase0.orderLine(alternated: true, ["today-1x", "generic-value-1x"]) == lines[2])
        #expect(Phase0.orderLine(alternated: false, ["whole-live clone", "dry-run-live clone"]) == lines[3])
    }

    // #4617: most probes name a reading after a corpus label such as "live clone", and the script drops a line
    // whose metric holds a space, so the metric is made one word rather than trusted to be one.
    @Test func aMetricIsAlwaysOneWordTheScriptCanRead() {
        #expect(Phase0.metricWord("0b1-oracleCold-live clone") == "0b1-oracleCold-live-clone")
        #expect(Phase0.metricWord("p8-(a) fetch/4x") == "p8--a--fetch-4x")
        #expect(Phase0.metricWord("first-draw-4x_v2.1") == "first-draw-4x_v2.1")
        #expect(Phase0.reading("a b", runs: [1], emit: { _ in }).probeLine("a b") == "probe reading: a-b 1.000") // probe-reading-exempt: the line builder's own test
    }

    /// Every line a constructor printed, in order.
    final class Emitted: @unchecked Sendable {
        var lines: [String] = []
        func emit(_ line: String) { lines.append(line) }
    }

    @Test func aTimedReadingPrintsItsLineAsItIsTaken() {
        let out = Emitted()
        var calls = 0
        let r = Phase0.median5("whole-1x", emit: out.emit) { calls += 1 }
        #expect(calls == 5)
        #expect(r.runs.count == 5)
        #expect(out.lines == [r.probeLine("whole-1x")])
    }

    @Test func aReadingOfRunsTheProbeTimedItselfPrintsItsLine() {
        let out = Emitted()
        let r = Phase0.reading("p8-a-fetch-4x", runs: [4, 2, 9], emit: out.emit)
        #expect(r.median == 4)
        #expect(out.lines == ["probe reading: p8-a-fetch-4x 4.000"])
    }

    // An empty sample measured nothing: no line, so the comparison names the metric as missing rather than
    // comparing a zero (L90), while the probe's own text still reads 0 as it always did.
    @Test func anEmptySamplePrintsNoLine() {
        let out = Emitted()
        let r = Phase0.reading("dismiss-1x", runs: [], emit: out.emit)
        #expect(out.lines.isEmpty)
        #expect(r.median == 0)
    }

    // Rival arms timed in ONE run: arm i % n goes first in sample i, so the order effect lands on each alike.
    @Test func rivalArmsAreTimedInAlternatingOrderAndSaySo() {
        let out = Emitted()
        var order: [String] = []
        let readings = Phase0.alternating([("today-1x", { order.append("A") }), ("generic-1x", { order.append("B") })],
                                          emit: out.emit)
        #expect(order == ["A", "B", "B", "A", "A", "B", "B", "A", "A", "B"])
        #expect(readings.map { $0.runs.count } == [5, 5])
        #expect(out.lines.count == 3)
        #expect(out.lines.last == "probe order: alternated today-1x,generic-1x")
        #expect(out.lines.first?.hasPrefix("probe reading: today-1x ") == true)
    }

    @Test func threeRivalArmsEachLeadInTurn() {
        var order: [String] = []
        _ = Phase0.alternating([("a", { order.append("a") }), ("b", { order.append("b") }), ("c", { order.append("c") })],
                               samples: 3, emit: { _ in }) // probe-reading-exempt: the line builder's own test
        #expect(order == ["a", "b", "c", "b", "c", "a", "c", "a", "b"])
    }

    @Test func aFixedOrderIsSaidRatherThanLeftSilent() {
        let out = Emitted()
        Phase0.fixedOrder(["whole-1x", "dry-run-1x"], emit: out.emit)
        #expect(out.lines == ["probe order: fixed whole-1x,dry-run-1x"])
    }

    @Test func aCountsMedianIsTheMiddleValueAndZeroWhenEmpty() {
        #expect(Phase0.medianCount([5, 1, 3]) == 3)
        #expect(Phase0.medianCount([]) == 0)
    }
}
