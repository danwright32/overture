import Testing
import Foundation

// #3749: parsing a day string without a `DateFormatter`, and proving it is the same parse.
//
// WHY. `EasternDate.date(from:)` was a `DateFormatter` parse at about 11 microseconds a call, and the
// queue pass makes roughly 1,090 of them per render: two per show for the lead-time window, one of which
// is `today`, the same string every time. #3748 measured the window at 31.3 ms and a single parse over
// the same rows at 13.5 ms, so most of that term was parsing. It is on many other paths besides.
//
// WHAT MAKES THIS RISKY, and what this suite is for. The parse is used as a VALIDATOR as well as a
// converter: `QueueModel.nightTimes` decides whether a stored entry is readable by whether it parses at
// all. So its REJECTIONS are part of its contract, and the trap is that `Calendar.date(from:)` ROLLS OVER
// out-of-range components. A naive replacement turns 2026-02-30 into 2 March instead of nil, and every
// caller using nil to mean invalid silently starts accepting garbage.
//
// THE ORACLE IS A DATEFORMATTER CONFIGURED EXACTLY AS THE OLD ONE WAS. That is deliberate and it is not
// a second production definition: it is the reference implementation this change must reproduce, held in
// the test rather than in the app. If the app's spec ever changes (a different calendar, locale, zone or
// format), this oracle has to change with it or the suite is comparing against a rule the app no longer
// has (L58).
@Suite("A day string parses the same without a DateFormatter (#3749)")
struct DayStringParseEquivalenceTests {

    /// The old implementation, verbatim, as the thing to match.
    private let oracle: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = EasternDate.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Every shape worth asking about, weighted towards REJECTIONS, because the acceptances are the easy
    /// half and the rejections are the contract a caller leans on (L104: a filter must be tested against
    /// what it has to preserve, not only what it has to catch).
    private func corpus() -> [String] {
        var out: [String] = []

        // Every day of four years, including a leap year and the century-adjacent ones.
        for year in [2024, 2025, 2026, 2027] {
            for month in 1...12 {
                for day in 1...31 {
                    out.append(String(format: "%04d-%02d-%02d", year, month, day))
                }
            }
        }
        // Leap day, both ways, and the 1900 rule.
        out += ["2024-02-29", "2023-02-29", "2000-02-29", "1900-02-29", "2100-02-29"]
        // Out of range fields.
        out += ["2026-00-01", "2026-13-01", "2026-01-00", "2026-01-32", "2026-04-31", "2026-06-31"]
        // Digit counts other than the format's.
        out += ["2026-1-5", "2026-01-5", "2026-1-05", "226-01-05", "20026-01-05", "2026-001-05"]
        // Separators and surrounding text.
        out += ["2026/01/05", "20260105", "2026-01-05T00:00:00", "2026 01 05", "2026-01-05Z",
                " 2026-01-05", "2026-01-05 ", "2026-01-05x", "x2026-01-05", "2026-01-05\n"]
        // Nothing, and nearly nothing.
        out += ["", " ", "   ", "-", "--", "----------", "abcd-ef-gh",
                "2026_01_05", "2026:01:05", "2026-01-05!", "!2026-01-05", "2026-01-05/", "hello"]
        // Extremes and signs.
        out += ["0000-01-01", "0001-01-01", "9999-12-31", "-001-01-01", "+026-01-05", "2026--1-05"]
        // Non-ASCII digits, which look like a date and are not one.
        out += ["٢٠٢٦-٠١-٠٥", "2026-01-0５"]
        return out
    }

    @Test("the new parse agrees with the formatter on every shape")
    func theyAgreeEverywhere() {
        let inputs = corpus()
        #expect(inputs.count > 1_400,
                Comment(rawValue: "the corpus is only \(inputs.count) strings, which is too few to have "
                        + "swept the shapes this parse has to get right"))

        var disagreements: [String] = []
        for input in inputs {
            let expected = oracle.date(from: input)
            let actual = EasternDate.date(from: input)
            if expected != actual {
                disagreements.append("\"\(input)\": formatter \(describe(expected)), new \(describe(actual))")
            }
        }
        // Reported as a COUNT with a sample, never as the whole list: a failing assertion renders its
        // operands, and 1,400 strings over the message explaining what went wrong is the shape that makes
        // a failure unreadable (L445).
        #expect(disagreements.isEmpty,
                Comment(rawValue: "\(disagreements.count) of \(inputs.count) inputs parse differently. "
                        + "First few: \(disagreements.prefix(6).joined(separator: "; "))"))
    }

    private func describe(_ date: Date?) -> String {
        guard let date else { return "nil" }
        return EasternDate.dayString(from: date)
    }

    // NON-VACUOUS: the corpus really does contain both answers, or the comparison above could be nil
    // against nil throughout and would pass with the parse deleted (L98).
    @Test("the corpus holds both acceptances and rejections in quantity")
    func theCorpusExercisesBothAnswers() {
        let inputs = corpus()
        let accepted = inputs.filter { oracle.date(from: $0) != nil }.count
        let rejected = inputs.count - accepted

        #expect(accepted > 1_000,
                Comment(rawValue: "only \(accepted) inputs parse at all, so this mostly compared nils"))
        #expect(rejected >= 20,
                Comment(rawValue: "only \(rejected) inputs are rejected, so the half of the contract that "
                        + "callers lean on is barely exercised"))
    }

    // The round trip, because `dayString(from:)` and `date(from:)` must stay inverse: every caller that
    // stores a day and reads it back depends on it.
    @Test("every day of a long span survives a round trip")
    func theRoundTripHolds() {
        var checked = 0
        for year in 2020...2030 {
            for month in 1...12 {
                for day in 1...28 {
                    let text = String(format: "%04d-%02d-%02d", year, month, day)
                    guard let parsed = EasternDate.date(from: text) else {
                        Issue.record(Comment(rawValue: "\(text) did not parse at all"))
                        continue
                    }
                    #expect(EasternDate.dayString(from: parsed) == text)
                    checked += 1
                }
            }
        }
        #expect(checked > 3_000, Comment(rawValue: "only \(checked) days round tripped"))
    }

    // EASTERN MIDNIGHT, not the machine's. The test SETS the thing that would make a wrong parse look
    // right rather than inheriting it (L504): it asserts the parsed instant against a component reading
    // taken in the Eastern calendar, which is false for a parse that used the local zone unless the Mac
    // happens to be in New York.
    @Test("a parsed day is that day's Eastern midnight")
    func theZoneIsEastern() {
        let parsed = try! #require(EasternDate.date(from: "2026-07-04"))
        let parts = EasternDate.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: parsed)
        #expect(parts.year == 2026)
        #expect(parts.month == 7)
        #expect(parts.day == 4)
        #expect(parts.hour == 0, "a parsed day must be that day's Eastern midnight")
        #expect(parts.minute == 0)

        // And a day inside standard time as well as summer time, since the offset differs and a parse
        // that hard coded one would pass on the other.
        let winter = try! #require(EasternDate.date(from: "2026-01-15"))
        let winterParts = EasternDate.calendar.dateComponents([.hour, .day], from: winter)
        #expect(winterParts.hour == 0)
        #expect(winterParts.day == 15)
    }

    // The day arithmetic that sits directly on top of the parse, since that is what the queue's hot path
    // actually calls and a parse that is right in isolation could still be handed to it wrongly.
    @Test("day arithmetic is unchanged across a leap year and a daylight saving boundary")
    func theArithmeticHolds() {
        #expect(EasternDate.daysUntil(from: "2026-01-01", to: "2026-01-01") == 0)
        #expect(EasternDate.daysUntil(from: "2026-01-01", to: "2026-01-02") == 1)
        #expect(EasternDate.daysUntil(from: "2026-01-02", to: "2026-01-01") == -1)
        // Across the spring forward, which is a 23 hour day and must still be one calendar day.
        #expect(EasternDate.daysUntil(from: "2026-03-07", to: "2026-03-09") == 2)
        // Across the autumn back, a 25 hour day.
        #expect(EasternDate.daysUntil(from: "2026-10-31", to: "2026-11-02") == 2)
        // Across a leap day.
        #expect(EasternDate.daysUntil(from: "2024-02-28", to: "2024-03-01") == 2)
        #expect(EasternDate.daysUntil(from: "2023-02-28", to: "2023-03-01") == 1)
        // And an unparseable end is still nil, which is what every caller reads as "no answer".
        #expect(EasternDate.daysUntil(from: "2026-01-01", to: "not a day") == nil)
        #expect(EasternDate.daysUntil(from: "not a day", to: "2026-01-01") == nil)
    }
}
