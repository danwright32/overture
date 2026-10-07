import Testing
import Foundation

// #4569: a test's show nights are Eastern days stepped in the Eastern calendar, never whole days added on
// the HOST's calendar.
//
// THE DEFECT. Thirty suites built a night as
// `EasternDate.dayString(from: Calendar(identifier: .gregorian).date(byAdding: .day, value: n, to: Date()))`.
// A gregorian calendar with no zone set is the host's zone: Eastern on Dan's Mac, where every night was
// distinct, and UTC on GitHub's runners. Adding whole UTC days keeps the UTC clock time, so once a span of
// nights crosses a clock change, an instant between 04:00 and 05:00 UTC lands at 00:xx EDT before it and at
// 23:xx EST after it, and two consecutive nights become ONE Eastern day for an hour every night. Measured
// 2026-10-07 at about 04:30 UTC: `AScoutRunDerivesTheQueueOnceTests.widgetsReadInTheHtmlLoopLandTogether
// WithTheFeeds` stored 38 shows, not 40, on PRs #4559, #4564 and #4566, three unrelated branches, because
// the TicketTailor widget keys its dates in a JSON object and the folded night dropped a show per widget.
//
// THE FIX. `ScoutTestClock.day(_:after:)`, one function both test targets compile, which reduces the instant
// to its Eastern day and steps from noon there in `EasternDate.calendar`. The first half of this suite
// proves it inside the hour that failed, against a calendar whose zone is set to UTC EXPLICITLY, so the
// proof says the same thing on this Mac as on a runner (L504). The second half refuses the chained host
// calendar step anywhere in the test tree, so a thirty first copy of that shape cannot arrive (L30); its
// one blind spot is written beside the detector.
@Suite("A test's nights are Eastern days, whatever zone the host is in (#4569)")
struct TestNightsAreEasternDaysTests {

    // MARK: - The helper, inside the window that failed

    // 04:30 UTC on 2026-10-07, which is 00:30 EDT the same day: the hour the three pull requests went red.
    private static func failingHour() throws -> Date {
        try #require(ISO8601DateFormatter().date(from: "2026-10-07T04:30:00Z"))
    }

    // Ten nights from 20 days out, which crosses the clock change on 2026-11-01. Written out rather than
    // computed, so the expected side does not come from the arithmetic under test (L70).
    private static let tenNightsAcrossTheClockChange = [
        "2026-10-27", "2026-10-28", "2026-10-29", "2026-10-30", "2026-10-31",
        "2026-11-01", "2026-11-02", "2026-11-03", "2026-11-04", "2026-11-05",
    ]

    @Test func tenNightsAcrossTheClockChangeAreTenEasternDaysInTheHourThatFailed() throws {
        let start = try Self.failingHour()
        let nights = (0..<10).map { ScoutTestClock.day(20 + $0, after: start) }
        #expect(Set(nights).count == 10, "two nights folded onto one Eastern day: \(nights)")
        #expect(nights == Self.tenNightsAcrossTheClockChange)
    }

    // The construction this replaced, with its zone set to UTC by hand rather than read from the host, so
    // this shows what a runner did without depending on what zone this Mac is in. If this ever stops
    // folding, the proof above has stopped being made inside the window that matters.
    @Test func theOldConstructionOnAUTCHostFoldsTwoOfTheSameNights() throws {
        let start = try Self.failingHour()
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(identifier: "UTC"))
        let nights = try (0..<10).map { n in
            EasternDate.dayString(from: try #require(utc.date(byAdding: .day, value: 20 + n, to: start)))
        }
        #expect(Set(nights).count == 9, "the UTC construction no longer folds a night: \(nights)")
        #expect(nights.filter { $0 == "2026-11-01" }.count == 2)
        #expect(!nights.contains("2026-11-05"))
    }

    // Every hour of that Eastern day gives the same ten nights, which is the property the old construction
    // lacked: its answer depended on the hour the suite happened to run.
    @Test func everyHourOfTheEasternDayGivesTheSameNights() throws {
        let start = try Self.failingHour()
        for hour in 0..<24 {
            let instant = start.addingTimeInterval(TimeInterval(hour) * 3_600)
            let nights = (0..<10).map { ScoutTestClock.day(20 + $0, after: instant) }
            #expect(nights == Self.tenNightsAcrossTheClockChange, "at \(instant)")
        }
    }

    // MARK: - The detector, as a pure function

    // Day arithmetic on a calendar whose zone is the HOST's. Matched with whitespace removed, so a chain
    // broken across lines is still one chain, and over CODE only (comments and string contents gone), so
    // prose quoting the construction, this file's included, is never an offender (L103).
    //
    // WHAT IT CANNOT SEE, stated so nobody reads more into a green run (L400): a calendar held in a
    // variable and stepped later (`var cal = Calendar(identifier: .gregorian)` then `cal.date(byAdding:`).
    // Whether that is a defect turns on whether a `timeZone` was set in between, which text matching cannot
    // follow. Measured 2026-10-07: every such variable in the three test roots sets its zone (Eastern, UTC or
    // FeedDates.defaultZone), so the gap holds no offender today.
    static let hostCalendarSteps = [
        "Calendar(identifier:.gregorian).date(byAdding:",
        "Calendar.current.date(byAdding:",
        "Calendar.autoupdatingCurrent.date(byAdding:",
    ]

    // The line each host calendar step starts on.
    static func hostCalendarDaySteps(in source: String) -> [Int] {
        let code = SwiftSource.tokenize(source).codeLines
        var chars: [Character] = []
        var lines: [Int] = []
        for line in code.keys.sorted() {
            for character in code[line] ?? "" where !character.isWhitespace {
                chars.append(character)
                lines.append(line)
            }
        }
        var found: [Int] = []
        for pattern in hostCalendarSteps.map(Array.init) where pattern.count <= chars.count {
            for start in 0...(chars.count - pattern.count)
            where chars[start] == pattern[0] && Array(chars[start..<(start + pattern.count)]) == pattern {
                found.append(lines[start])
            }
        }
        return found.sorted()
    }

    @Test func theDetectorFindsEveryShapeOfTheHostCalendarStep() {
        let found = Self.hostCalendarDaySteps(in: """
        enum Fixture {
            static func one(_ n: Int) -> String {
                EasternDate.dayString(from: Calendar(identifier: .gregorian).date(byAdding: .day, value: n, to: Date())!)
            }
            static func two(_ n: Int) -> Date {
                Calendar(identifier: .gregorian)
                    .date(byAdding: .day, value: n, to: Date())!
            }
            static func three(_ n: Int) -> Date { Calendar.current.date(byAdding: .day, value: n, to: Date())! }
        }
        """)
        #expect(found == [3, 6, 9])
    }

    @Test func theDetectorPassesTheEasternCalendarAndProseAboutTheHostOne() {
        let found = Self.hostCalendarDaySteps(in: """
        enum Fixture {
            // Calendar(identifier: .gregorian).date(byAdding: .day, value: 1, to: now) is what this replaced.
            static let quoted = "Calendar.current.date(byAdding: .day"
            static func night(_ n: Int, _ now: Date) -> Date {
                EasternDate.calendar.date(byAdding: .day, value: n, to: now)!
            }
        }
        """)
        #expect(found.isEmpty, "flagged lines \(found)")
    }

    // MARK: - The live claim

    // Every root this repo's own test Swift lives in, named rather than walked from `mac/`, which would
    // collect the SwiftPM checkouts under mac/build (L234). Through AppSourceWalk, which refuses an empty
    // walk, so a wrong path cannot make this pass over nothing (#2311, L98).
    //
    // The WHOLE test tree, not only files that name `EasternDate.dayString`, which is where the incident
    // was. The reason for refusing is that a host calendar's day step depends on which zone the machine is
    // in while every day this app reckons is Eastern, and that is true of a step feeding any reader, not
    // only the one the failing suites happened to use (L615).
    private static let roots = ["OvertureTests", "OvertureHostedTests", "TestSupport"]

    @Test func noTestStepsDaysOnTheHostCalendar() {
        let files = AppSourceWalk.files(underAll: Self.roots.map(RepoRoot.mac.appendingPathComponent),
                                        floor: 100)
        var offenders: [String] = []
        for file in files {
            for line in Self.hostCalendarDaySteps(in: file.text) { offenders.append("\(file.name):\(line)") }
        }
        #expect(offenders.isEmpty, Comment(rawValue: """
            These test lines step days on the HOST's calendar, which is UTC on GitHub's runners and Eastern \
            on Dan's Mac, so across a clock change two nights fold onto one Eastern day for an hour every \
            night (#4569). Use ScoutTestClock.day(_:after:) for a night dated from a clock, \
            ScoutTestClock.day(_:plus:) for one dated from an Eastern day string, or \
            EasternDate.calendar for any other step.
            \(offenders.joined(separator: "\n"))
            """))
    }
}
