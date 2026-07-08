import Testing
import Foundation
import SwiftData
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
                          event: String? = nil, outcome: Outcome = .replied,
                          source: OutcomeSource? = .manual) -> ConversationReminder.DueReminder? {
        // Phase F: the timing function now takes the derived booleans; map the legacy outcome onto them.
        let closed = outcome == .booked || outcome == .lostSoft || outcome == .lostHard
        return ConversationReminder.reminder(state: state, setAt: setAt, remindedAt: remindedAt,
                                             performanceDate: event, isClosed: closed,
                                             hasUnhandledReply: outcome == .replied,
                                             source: source, now: now)
    }

    @Test func anAutoSuggestedStateIsDueImmediately() {
        // source=auto means the AI guessed it: surface it RIGHT AWAY (interval not elapsed, event far)
        // as a suggestion, so the lead never silently drops out of Due (red-team blocker).
        #expect(reminder(state: .wantsToBook, setAt: now, event: "2026-12-01", source: .auto)?.kind
                == .suggested(.wantsToBook))
    }

    @Test func aConfirmedManualStateUsesTheTimedTrack() {
        // source=manual (Dan confirmed/set) follows the normal interval timing, not immediate.
        #expect(reminder(state: .wantsToBook, setAt: now, event: "2026-12-01", source: .manual) == nil)
        #expect(reminder(state: .wantsToBook, setAt: daysAgo(7), event: "2026-12-01", source: .manual)?.kind
                == .active(.wantsToBook))
    }

    @Test func aSuggestedReminderCarriesItsOwnReason() {
        let r = reminder(state: .wantsToBook, setAt: now, source: .auto)
        #expect(r?.kind == .suggested(.wantsToBook))
        #expect((r?.reason.isEmpty == false))
        #expect(r?.reason != ConversationReminder.reason(for: .active(.wantsToBook)))
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

    private func prospect(state: ConversationState?, setAt: Date?, event: String?, outcome: Outcome) -> Prospect {
        let p = Prospect(naturalKey: "k-\(event ?? "none")-\(state?.rawValue ?? "nil")-\(outcome.rawValue)",
                         groupName: "G", discipline: "music", venue: "V",
                         performanceDate: event, sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "warm", production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 8, tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil)
        p.outcome = outcome
        p.conversationState = state
        p.conversationStateSetAt = setAt
        // Phase F: the derived reads come from contacts, so seed one whose standing matches `outcome`.
        let r = Recipient(id: "c@e.com", email: "c@e.com", provenance: .act)
        r.sendState = .sent
        if outcome == .replied { r.replied = true }
        p.setRecipients([r])
        return p
    }

    @Test func dueIsSortedByUrgencyThenEvent() {
        let leads = [
            prospect(state: .interested, setAt: daysAgo(30), event: "2020-01-01", outcome: .replied),     // closing
            prospect(state: nil, setAt: nil, event: "2026-12-01", outcome: .replied),                     // needsState
            prospect(state: .interested, setAt: daysAgo(30), event: "2026-12-01", outcome: .replied),     // interested
            prospect(state: .hasQuestion, setAt: daysAgo(30), event: "2026-12-01", outcome: .replied),    // hasQuestion
            prospect(state: .wantsToBook, setAt: daysAgo(30), event: "2026-12-01", outcome: .replied),    // wantsToBook
        ]
        let kinds = ConversationReminder.due(from: leads, now: now).map { $0.1.kind }
        #expect(kinds == [
            .active(.wantsToBook), .active(.hasQuestion), .active(.interested), .needsState, .closing,
        ])
    }

    @Test func dueExcludesDismissedLeads() {
        // #238: a dismissed lead must not surface as a conversation reminder, even with an active state.
        let p = prospect(state: .wantsToBook, setAt: daysAgo(30), event: "2026-12-01", outcome: .replied)
        p.status = .dismissed
        #expect(ConversationReminder.due(from: [p], now: now).isEmpty)
    }

    @Test func dueBreaksTiesBySoonestEvent() {
        let leads = [
            prospect(state: .wantsToBook, setAt: daysAgo(30), event: "2026-08-01", outcome: .replied),
            prospect(state: .wantsToBook, setAt: daysAgo(30), event: "2026-07-01", outcome: .replied),
        ]
        let events = ConversationReminder.due(from: leads, now: now).map { $0.0.performanceDate }
        #expect(events == ["2026-07-01", "2026-08-01"])
    }

    @Test func accentMapsEachKindToASemanticToken() {
        #expect(ConversationReminder.accent(for: .active(.wantsToBook)) == .onTrack)
        #expect(ConversationReminder.accent(for: .active(.hasQuestion)) == .attention)
        #expect(ConversationReminder.accent(for: .active(.interested)) == .warm)
        #expect(ConversationReminder.accent(for: .needsState) == .warm)
        #expect(ConversationReminder.accent(for: .closing) == .neutral)
    }

    @Test func conversationStateAccentMatchesItsActiveReminder() {
        #expect(ConversationState.wantsToBook.accent == .onTrack)
        #expect(ConversationState.hasQuestion.accent == .attention)
        #expect(ConversationState.interested.accent == .warm)
        #expect(ConversationState.declined.accent == .neutral)
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

    // #650 Phase 1: the per-recipient due calculation mirrors FollowUp.dueRecipients' shape exactly,
    // reusing the same pure reminder() calculator with per-recipient inputs.
    @Test func dueRecipientsPicksOnlyThisRecipientsOwnActiveState() throws {
        let ctx = try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                     configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let context = ModelContext(ctx)
        let now = Date(timeIntervalSince1970: 2_000_000)
        let p = Prospect(naturalKey: "k", groupName: "G", discipline: "music", venue: "V",
                         performanceDate: nil, sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        context.insert(p)
        let overdue = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        overdue.sendState = .sent
        overdue.setConversationState(.interested, now: now.addingTimeInterval(-20 * 86_400))
        let notDueYet = Recipient(id: "b@act.example", email: "b@act.example", provenance: .act)
        notDueYet.sendState = .sent
        notDueYet.setConversationState(.interested, now: now)
        p.setRecipients([overdue, notDueYet])

        let due = ConversationReminder.dueRecipients(from: [p], now: now)
        #expect(due.map(\.recipient.id) == ["a@act.example"])
    }

    // #652: the UI needs the CLASSIFIED reminder (kind + reason), same as the lead-level due(from:)
    // already returns, not just which recipients are due. Each DueRecipient carries its own reminder.
    @Test func dueRecipientsCarriesTheClassifiedReminderPerRecipient() throws {
        let ctx = try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                     configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let context = ModelContext(ctx)
        let now = Date(timeIntervalSince1970: 2_000_000)
        let p = Prospect(naturalKey: "k", groupName: "G", discipline: "music", venue: "V",
                         performanceDate: nil, sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        context.insert(p)
        let wantsToBook = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        wantsToBook.sendState = .sent
        wantsToBook.setConversationState(.wantsToBook, now: now.addingTimeInterval(-40 * 86_400))
        let needsState = Recipient(id: "b@act.example", email: "b@act.example", provenance: .act)
        needsState.sendState = .sent
        needsState.replied = true   // replied but never categorized: needsState is due immediately
        p.setRecipients([wantsToBook, needsState])

        let due = ConversationReminder.dueRecipients(from: [p], now: now)
            .sorted { $0.recipient.id < $1.recipient.id }
        #expect(due.map(\.recipient.id) == ["a@act.example", "b@act.example"])
        #expect(due[0].reminder.kind == .active(.wantsToBook))
        #expect(due[0].reminder.reason == ConversationReminder.reason(for: .active(.wantsToBook)))
        #expect(due[1].reminder.kind == .needsState)
    }

    @Test func dueRecipientsExcludesABookedShow() throws {
        let ctx = try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                     configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let context = ModelContext(ctx)
        let now = Date(timeIntervalSince1970: 2_000_000)
        let p = Prospect(naturalKey: "k", groupName: "G", discipline: "music", venue: "V",
                         performanceDate: nil, sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        p.outcome = .booked
        context.insert(p)
        let overdue = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        overdue.sendState = .sent
        overdue.setConversationState(.interested, now: now.addingTimeInterval(-20 * 86_400))
        p.setRecipients([overdue])

        #expect(ConversationReminder.dueRecipients(from: [p], now: now).isEmpty)
    }

    @Test func dueRecipientsSkipsAResolvedOrBouncedRecipient() throws {
        let ctx = try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                     configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let context = ModelContext(ctx)
        let now = Date(timeIntervalSince1970: 2_000_000)
        let p = Prospect(naturalKey: "k", groupName: "G", discipline: "music", venue: "V",
                         performanceDate: nil, sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        context.insert(p)
        let resolved = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        resolved.sendState = .sent
        resolved.setConversationState(.interested, now: now.addingTimeInterval(-20 * 86_400))
        resolved.markOutcomeManually(resolution: .declinedSoft)
        p.setRecipients([resolved])

        #expect(ConversationReminder.dueRecipients(from: [p], now: now).isEmpty)
    }

    // A never-sent recipient (sendState still .pending) must never read as due, even if it somehow
    // carries a conversation state: standing.isInPlay requires sendState == .sent, so a pending
    // recipient is not in play and therefore closed. No real code path sets a conversation state on
    // a pending recipient yet (that lands in a later phase), so this is constructed directly to prove
    // dueRecipients uses r.standing rather than an inline check that misses the sendState condition.
    @Test func dueRecipientsExcludesANeverSentRecipientEvenWithAConversationState() throws {
        let ctx = try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                     configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let context = ModelContext(ctx)
        let now = Date(timeIntervalSince1970: 2_000_000)
        let p = Prospect(naturalKey: "k", groupName: "G", discipline: "music", venue: "V",
                         performanceDate: nil, sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        context.insert(p)
        let neverSent = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        neverSent.setConversationState(.interested, now: now.addingTimeInterval(-20 * 86_400))
        p.setRecipients([neverSent])

        #expect(ConversationReminder.dueRecipients(from: [p], now: now).isEmpty)
    }
}
