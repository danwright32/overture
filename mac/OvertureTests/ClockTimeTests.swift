import Testing
import Foundation

// #1699 part 3: one parser for the "HH:mm" a source publishes, so the card that RENDERS a curtain time
// and the clash check that REASONS about it can never disagree about whether a string is a real time.
// Two separate validators drifting apart is exactly the failure L50 describes: a value that fails to
// parse must land on the fail-safe side at every call site, and it cannot if each site decides for itself.
@Suite("Clock time parsing (#1699)")
struct ClockTimeTests {
    @Test func aRealTimeReadsAsMinutesSinceMidnight() {
        #expect(ClockTime.minutesOfDay("00:00") == 0)
        #expect(ClockTime.minutesOfDay("14:00") == 840)
        #expect(ClockTime.minutesOfDay("19:30") == 1170)
        #expect(ClockTime.minutesOfDay("23:59") == 1439)
    }

    // Anything that is not exactly two-digit 24-hour "HH:mm" yields nothing at all, rather than a guess
    // that would be compared against a threshold as if it were measured.
    @Test func anythingElseYieldsNothing() {
        for raw in ["", "7pm", "7:00 PM", "19:00:00", "9:00", "19:0", "1900", "24:00", "19:60", "ab:cd"] {
            #expect(ClockTime.minutesOfDay(raw) == nil, "\(raw) must not parse")
        }
    }

    // The 12-hour label the card shows comes off the SAME parser, so a time the clash check can reason
    // about always renders, and one it cannot never appears on screen as if it were understood.
    @Test func theLabelRendersFromTheSameParse() {
        #expect(ClockTime.label("14:00") == "2:00 PM")
        #expect(ClockTime.label("00:00") == "12:00 AM")
        #expect(ClockTime.label("12:00") == "12:00 PM")
        #expect(ClockTime.label("09:05") == "9:05 AM")
        #expect(ClockTime.label("7pm") == nil)
    }
}
