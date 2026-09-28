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

    /// Every Swift file in the three places test code lives, repo relative.
    static func testSources() -> [(path: String, source: String)] {
        let root = RepoRoot.url
        return ["mac/OvertureTests", "mac/OvertureHostedTests", "mac/TestSupport"].flatMap { dir -> [(path: String, source: String)] in
            let base = root.appendingPathComponent(dir)
            let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
            return files.map { url in
                (dir + "/" + String(url.path.dropFirst(base.path.count + 1)),
                 (try? String(contentsOf: url, encoding: .utf8)) ?? "")
            }
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
