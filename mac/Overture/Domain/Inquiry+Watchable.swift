import Foundation

// An inquiry rides the Phase 1 reply/bounce pipeline (#1434) as its OWN single recipient: it has one
// email thread, not a contact list, so it is both the watched entity and its sole watched thread.
// Every stored field ReplyWatchableRecipient needs already lives on Inquiry, so the recipient
// conformance is just the two semantic guards; the lead conformance returns `[self]`.

extension Inquiry: ReplyWatchableRecipient {
    // #2032: an inquiry is its own single thread, so the address is simply the inquirer's.
    var replyWatchAddress: String? { inquirerEmail }
    var replyWatchManualOutcome: Bool { outcomeSourceRaw == OutcomeSource.manual.rawValue }
    var replyWatchIsBooked: Bool { outcome == .booked }
    // #2196: an inquiry keeps its open/closed judgement in one place already, so the second-reply re-read
    // rides that rather than restating it. `isOpen` is false for booked and for either lost close, which
    // is the same "nothing left to watch" the prospect side means.
    var replyWatchConversationIsOpen: Bool { isOpen }
}

extension Inquiry: ReplyWatchable {
    var replyWatchDisplayName: String { inquirerName }
    var replyWatchRecipients: [any ReplyWatchableRecipient] { [self] }
    // An inquiry has no other unsent contacts to hold back while Dan triages a reply, so the
    // prospect-side pause is a no-op here.
    func pausePendingForReply() {}
}

// Booking match for an inquiry (#1435): the "org" to name-match against a Downbeat booking is the
// inquirer, a private individual. Suggestion-only (`permitsAutoBook == false`), so an exact match
// never flips the outcome to booked; it only ever surfaces a suggestion for Dan to confirm.
extension Inquiry: BookingMatchable {
    var groupName: String { inquirerName }
    var bookingManualOutcome: Bool { outcomeSourceRaw == OutcomeSource.manual.rawValue }
    var bookingIsBooked: Bool { outcome == .booked }
    // An inquiry has no "already a client when pitched" concept; it is always a fresh hire ask.
    var bookingPriorRelationshipBooked: Bool { false }
    var permitsAutoBook: Bool { false }

    // Never reached: reconcileBooked only calls this when `permitsAutoBook` is true. Implemented as a
    // suggestion (never a book) so that even under future misuse an inquiry can never silently
    // auto-book, honoring the locked suggestion-only rule.
    func markAutoBooked(bookingId: String, now: Date) {
        if !bookingSuggestionDismissed { bookingSuggested = true }
    }
}
