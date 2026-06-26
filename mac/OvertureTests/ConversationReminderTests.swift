import Testing
import Foundation
@testable import Overture

// The pure conversation-reminder calculator (#111), mirroring FollowUp: decides who is due and why,
// with event-aware timing (the show is the real deadline) and a post-event closing note. Pure, no
// SwiftData. "now" and "setAt" are instants; the event date is an Eastern day string via EasternDate.
@Suite("Conversation reminder")
struct ConversationReminderTests {
    // A fixed "now": 2026-06-15 16:00 UTC = 12:00 EDT, so EasternDate.today(now) == "2026-06-15".
    private var now: Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 16))!
    }
    private func daysAgo(_ d: Double) -> Date { now.addingTimeInterval(-d * 86_400) }

    private func reminder(state: ConversationState?, setAt: Date?, remindedAt: Date? = nil,
                          event: String? = nil, outcome: Outcome = .replied) -> ConversationReminder.DueReminder? {
        ConversationReminder.reminder(state: state, setAt: setAt, remindedAt: remindedAt,
                                      performanceDate: event, outcome: outcome, now: now)
    }

    @Test func terminalOutcomesClearTheReminder() {
        for terminal in [Outcome.booked, .lostSoft, .lostHard] {
            #expect(reminder(state: .wantsToBook, setAt: daysAgo(100), outcome: terminal) == nil)
        }
    }

    @Test func declinedIsNeverDue() {
        #expect(reminder(state: .declined, setAt: daysAgo(100)) == nil)
    }

    @Test func wantsToBookIsDueAtTheIntervalBoundary() {
        #expect(reminder(state: .wantsToBook, setAt: daysAgo(7))?.kind == .active(.wantsToBook))
    }

    @Test func wantsToBookIsNotDueJustBeforeTheInterval() {
        // 6 days 23 hours: under the 7-day interval.
        #expect(reminder(state: .wantsToBook, setAt: now.addingTimeInterval(-(7 * 86_400 - 3_600))) == nil)
    }

    @Test func remindedAtReanchorsTheInterval() {
        // Set 20 days ago but acted on 1 day ago: not due again until the interval from remindedAt.
        #expect(reminder(state: .wantsToBook, setAt: daysAgo(20), remindedAt: daysAgo(1)) == nil)
    }

    @Test func aNearEventPullsTheReminderForwardOfItsInterval() {
        // interested = 10 days; not yet elapsed, but the event is exactly at the 3-day buffer.
        #expect(reminder(state: .interested, setAt: now, event: "2026-06-18")?.kind == .active(.interested))
    }

    @Test func aFarEventDoesNotForceTheIntervalEarly() {
        #expect(reminder(state: .interested, setAt: now, event: "2026-06-25") == nil)
    }

    @Test func anEventInsideTheBufferIsDueImmediately() {
        #expect(reminder(state: .interested, setAt: now, event: "2026-06-16")?.kind == .active(.interested))
    }

    @Test func withNoEventThePlainIntervalGoverns() {
        #expect(reminder(state: .interested, setAt: now, event: nil) == nil)
        #expect(reminder(state: .interested, setAt: daysAgo(10), event: nil)?.kind == .active(.interested))
    }

    @Test func onTheDayOfShowTheActiveReminderStillShows() {
        // daysUntil == 0 (today): not passed, still the active reminder, never the closing note.
        #expect(reminder(state: .wantsToBook, setAt: daysAgo(100), event: "2026-06-15")?.kind == .active(.wantsToBook))
    }

    @Test func theDayAfterTheShowBecomesTheClosingNote() {
        #expect(reminder(state: .wantsToBook, setAt: daysAgo(100), event: "2026-06-14")?.kind == .closing)
    }

    @Test func aRepliedLeadWithNoStateNeedsCategorizing() {
        #expect(reminder(state: nil, setAt: nil, outcome: .replied)?.kind == .needsState)
    }

    @Test func aNoResponseLeadWithNoStateIsNotAConversationReminder() {
        #expect(reminder(state: nil, setAt: nil, outcome: .noResponse) == nil)
    }

    @Test func everyDueReminderCarriesANonEmptyReason() {
        let kinds = [
            reminder(state: .wantsToBook, setAt: daysAgo(7)),
            reminder(state: .wantsToBook, setAt: daysAgo(100), event: "2026-06-14"),
            reminder(state: nil, setAt: nil, outcome: .replied),
        ]
        for r in kinds { #expect(r != nil && !(r!.reason.isEmpty)) }
        // Distinct reasons across the three kinds so the queue can tag them apart.
        #expect(Set(kinds.compactMap { $0?.reason }).count == 3)
    }
}
