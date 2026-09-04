import Testing
import Foundation

// #3422: the due token written into an OmniFocus task's note and read back out of it.
//
// It used to be a bare Eastern day, `Due: 2026-08-31`, and the client rebuilt that day at a
// hardcoded 6:00 PM to compare against what Overture wanted. That worked only while every due WAS
// 6:00 PM. With a due that varies by the hour the reply arrived, the written value and the rebuilt
// value could never be equal again, so `reconcile` would read every task as a stale due on every
// pass, complete it, and recreate it, for ever, and nothing would say so: OmniFocus would just
// churn. That is #2899's failure mode wearing a different cause.
//
// One type, read by the writer and by the reader, so the two cannot drift into different spellings
// of the same instant (L26).
@Suite("OmniFocus due token (#3422)")
struct OmniFocusDueTokenTests {
    private func eastern(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi; c.second = 0
        return EasternDate.calendar.date(from: c)!
    }

    @Test func aDueSurvivesTheRoundTripToTheMinute() {
        for (h, m) in [(9, 0), (11, 0), (18, 0), (23, 0), (0, 30)] {
            let due = eastern(2026, 8, 31, h, m)
            #expect(OmniFocusDueToken.date(from: OmniFocusDueToken.string(from: due)) == due,
                    "\(h):\(m) did not survive the round trip")
        }
    }

    // The half that stops the churn: two dues that differ only by the HOUR must produce different
    // tokens. A token that kept only the day would read both as the same task and the comparison
    // `reconcile` makes would be answered by the wrong one.
    @Test func twoDuesOnOneDayAtDifferentHoursAreDifferentTokens() {
        let morning = OmniFocusDueToken.string(from: eastern(2026, 8, 31, 9, 0))
        let evening = OmniFocusDueToken.string(from: eastern(2026, 8, 31, 18, 0))
        #expect(morning != evening)
    }

    // Dan's OmniFocus holds tasks written in the OLD day-only shape right now. They must still parse,
    // at the hour they were actually written with, or the first sync after this ships reads every one
    // of them as unrecognised and silently leaves them behind (L214: absent and unparseable are not
    // the same thing as present in an older shape).
    @Test func aLegacyDayOnlyTokenStillReadsBackAtSixPm() {
        #expect(OmniFocusDueToken.date(from: "2026-08-31") == eastern(2026, 8, 31, 18, 0))
    }

    // And it compares as STALE against its new time, which is what makes the transition happen once
    // rather than never: each legacy task is completed and recreated at its new due on the first sync.
    @Test func aLegacyTokenIsStaleAgainstAReplysNewDeadline() {
        let legacy = OmniFocusDueToken.date(from: "2026-08-31")
        let now = ReplyTriageDue.due(replyArrivedAt: eastern(2026, 8, 31, 22, 12))
        #expect(legacy != now)
    }

    // Nonsense is refused rather than guessed at. A token that parsed anything would turn a corrupted
    // note into a confident date and the task would be completed and recreated against it (L257).
    @Test func anUnreadableTokenIsRefusedRatherThanGuessed() {
        for junk in ["", "not a date", "2026-13-99 25:00", "2026-08", "31-08-2026"] {
            #expect(OmniFocusDueToken.date(from: junk) == nil, "\(junk) was read as a date")
        }
    }
}
