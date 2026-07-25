import Foundation
import SwiftData

// Where a direct hire inquiry came from. Contact form and direct email ONLY (Dan's locked scope,
// #1435): referral, phone, and repeat-client are deliberately out.
enum InquirySource: String, CaseIterable, Sendable {
    case contactForm = "contact_form"
    case directEmail = "direct_email"

    var label: String {
        switch self {
        case .contactForm: return "Contact form"
        case .directEmail: return "Direct email"
        }
    }
}

// A direct hire inquiry: someone reaching out to hire Dan, tracked ALONGSIDE the scout/pitch queue
// but a fully separate entity. Zero `@Relationship` to Prospect or Recipient by design (#1433), never
// linked or merged even when it references the same show. Its identity is the EVENT, not the
// inquirer, because Dan logs it by hand and wouldn't re-log the same event twice. Reuses the shared
// `Outcome` vocabulary (open = noResponse/replied, booked, lost = lostSoft/lostHard) and rides the
// Phase 1 `ReplyWatchable` / `BookingMatchable` seams so reply detection and booking-match are the
// same tested code prospects use, not a second copy.
@Model
final class Inquiry {
    // Contact form / direct email, stored raw so a future source can't break decoding.
    var sourceRaw: String
    var inquirerName: String
    var inquirerEmail: String?
    // The event, the natural key's basis. All optional past the name because an inquiry can arrive
    // as a bare email with nothing pinned down yet.
    var eventName: String
    var performanceDate: String?   // yyyy-MM-dd, Eastern
    var venue: String?
    var notes: String?
    // When Dan logged it. Drives the longer-silence "consider closing" suggestion.
    var createdAt: Date

    // Dan types and sends the first reply himself (#1435); these track that send and its thread.
    var sentAt: Date?
    var gmailThreadId: String?
    var gmailMessageId: String?    // stamped on the sent reply → `wasProvablyContacted`
    var threadIdDegraded: Bool = false

    // Reply / bounce detection state. An inquiry has ONE thread, not a contact list, so it presents
    // itself to the shared pipeline as a single self-thread (see Inquiry+ReplyWatchable).
    var replied: Bool = false
    var repliedAt: Date?
    var lastReplyId: String?
    var lastReplyText: String?
    var dismissedReplyId: String?
    var bounced: Bool = false
    var lastBounceId: String?
    var dismissedBounceId: String?
    var lastDelayMessageId: String?
    var delayNoticeAt: Date?

    // Outcome, reusing the shared Outcome enum. open = noResponse/replied, booked, lost = the two
    // lost cases. Lost is ALWAYS a manual close (#1435); nothing here auto-closes.
    var outcomeRaw: String = Outcome.noResponse.rawValue
    var outcomeSourceRaw: String? = nil
    var outcomeAt: Date? = nil

    // Downbeat booking match: SUGGESTION-ONLY for an inquiry, never a silent auto-book (#1435), since
    // the org-name matcher it reuses isn't calibrated for private-individual name collisions.
    var bookingSuggested: Bool = false
    var bookingSuggestionDismissed: Bool = false
    var autoBookingRejectedWithoutId: Bool = false
    var rejectedBookingIdsRaw: String = ""
    var downbeatClientId: String? = nil   // a private individual usually has none.
    var runEndDate: String? = nil

    init(source: InquirySource, inquirerName: String, inquirerEmail: String?,
         eventName: String, performanceDate: String? = nil, venue: String? = nil,
         notes: String? = nil, createdAt: Date = Date()) {
        self.sourceRaw = source.rawValue
        self.inquirerName = inquirerName
        self.inquirerEmail = inquirerEmail
        self.eventName = eventName
        self.performanceDate = performanceDate
        self.venue = venue
        self.notes = notes
        self.createdAt = createdAt
    }

    var source: InquirySource { InquirySource(rawValue: sourceRaw) ?? .directEmail }

    var outcome: Outcome {
        get { Outcome.fromStored(outcomeRaw) }
        set { outcomeRaw = newValue.rawValue }
    }

    // Booking ids Dan has rejected as wrong matches (#203 idiom, reused).
    var rejectedBookingIds: Set<String> {
        Set(rejectedBookingIdsRaw.split(separator: "\n").map(String.init))
    }

    // The EVENT key (performance / date / venue), canonicalized exactly as a Prospect's is so the two
    // stay comparable. Computed, so editing the event re-keys the inquiry.
    var naturalKey: String {
        Inquiry.makeNaturalKey(eventName: eventName, performanceDate: performanceDate, venue: venue)
    }

    // A real send stamps a message id (mirrors Prospect.wasProvablyContacted, #963), so a record with
    // a timestamp but no id was never actually sent and never auto-books.
    var wasProvablyContacted: Bool { gmailMessageId != nil }

    static func makeNaturalKey(eventName: String, performanceDate: String?, venue: String?) -> String {
        let normalizedVenue = venue.map(VenueNormalization.normalizeForKey)
        return [eventName, performanceDate ?? "", normalizedVenue ?? ""]
            .map(Prospect.canonicalize)
            .joined(separator: "|")
    }
}

extension Inquiry {
    // The follow-up nudge fires at 3 business days of silence after Dan's first reply. The longer
    // "consider closing" suggestion waits far longer (about six weeks of weekdays). Both are pure
    // derivations off stored timestamps, never a stored "fired" flag (#1435), so they self-correct
    // the instant a reply lands or Dan closes the inquiry.
    static let followUpNudgeBusinessDays = 3
    static let closingSuggestionBusinessDays = 30

    // Still live: not booked and not closed to a lost state. Keyed on the OUTCOME alone, deliberately.
    //
    // A prospect has to check that a lost outcome came from Dan by hand, because its outcome can also be
    // set automatically. An inquiry's cannot: bookings are suggestion-only for it (permitsAutoBook ==
    // false) and lost is always Dan's manual close, so the only automatic write an inquiry ever receives
    // is `.replied`, which is open either way. Requiring the manual source here therefore guarded a
    // state that cannot occur, and guarded it the WRONG WAY: a lost inquiry whose source was anything
    // but manual read as open forever and would have sat in the queue with no way to close it.
    //
    // Keying on one field is also what lets #1437 express this as a #Predicate for #16 to query
    // (InquiryReporting.openPredicate); a two-key version could not be (#901). InquiryReportingTests
    // pins the two in agreement across every outcome and source.
    var isOpen: Bool {
        switch outcome {
        case .booked, .lostSoft, .lostHard: return false
        case .noResponse, .replied: return true
        }
    }

    func followUpNudgeDue(now: Date) -> Bool {
        guard isOpen, !replied, !bounced, let sentAt else { return false }
        // #1438: the two nudges are drawn as badges side by side on the row, so they must not both be
        // true. Once the silence is long enough to suggest closing, that supersedes "follow up"; showing
        // both told Dan to chase it and to give up on it at the same time.
        guard !shouldSuggestClosing(now: now) else { return false }
        return BusinessDay.count(after: sentAt, through: now) >= Inquiry.followUpNudgeBusinessDays
    }

    func shouldSuggestClosing(now: Date) -> Bool {
        guard isOpen, !replied, let sentAt else { return false }
        return BusinessDay.count(after: sentAt, through: now) >= Inquiry.closingSuggestionBusinessDays
    }

    // Dan's own call on the outcome (booked or a lost close): manual source so auto reply/booking
    // detection never overwrites it, timestamped, and any booking suggestion cleared. Mirrors
    // Prospect.markOutcomeManually.
    func markOutcomeManually(_ outcome: Outcome, now: Date) {
        self.outcome = outcome
        outcomeSourceRaw = OutcomeSource.manual.rawValue
        outcomeAt = now
        bookingSuggested = false
    }
}

// Intake rules, kept OUT of the sheet that draws them (the WatchlistEditing / DayOffEditing idiom):
// logic stated in a SwiftUI body drifts under a green suite because nothing can reach it (#863).
@MainActor
enum InquiryIntake {
    // Soft pre-insert duplicate check on the EVENT natural key. A blank key (no event pinned down) is
    // NEVER a duplicate, so two under-specified inquiries don't falsely collide.
    static func duplicate(ofKey key: String, in inquiries: [Inquiry]) -> Inquiry? {
        guard !isBlankKey(key) else { return nil }
        return inquiries.first { $0.naturalKey == key }
    }

    static func isBlankKey(_ key: String) -> Bool {
        key.replacingOccurrences(of: "|", with: "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    // The only required field. Everything else about the event can legitimately be unknown when an
    // inquiry arrives as a bare email.
    static func canSave(name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // An unknown date must stay genuinely unknown rather than defaulting to whatever the picker was
    // showing: a wrong date both mis-keys the event and files the inquiry under the wrong day.
    static func performanceDate(hasDate: Bool, date: Date) -> String? {
        hasDate ? EasternDate.dayString(from: date) : nil
    }

    // Build a normalized inquiry from raw form fields and insert it: trims every field and turns a
    // blank optional into nil, so a bare intake keys cleanly and the view stays free of rules.
    @discardableResult
    static func create(source: InquirySource, name: String, email: String?, eventName: String,
                       performanceDate: String?, venue: String?, notes: String?,
                       in context: ModelContext) -> Inquiry {
        func cleaned(_ value: String?) -> String? {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed?.isEmpty ?? true) ? nil : trimmed
        }
        let inquiry = Inquiry(source: source,
                              inquirerName: name.trimmingCharacters(in: .whitespacesAndNewlines),
                              inquirerEmail: cleaned(email),
                              eventName: eventName.trimmingCharacters(in: .whitespacesAndNewlines),
                              performanceDate: cleaned(performanceDate),
                              venue: cleaned(venue),
                              notes: cleaned(notes))
        context.insert(inquiry)
        return inquiry
    }
}
