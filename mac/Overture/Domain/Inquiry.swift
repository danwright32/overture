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

// Why an inquiry ended without a booking. #16's year-end Sankey wants "Declined" and "Not a fit" as
// separate drop-offs, and unlike the rest of the funnel that distinction is NOT derivable from anything
// stored: only Dan knows whether the client said no or he passed on it. So it is captured at the one
// moment anyone knows, when he closes the inquiry. A silence is included because closing one out is a
// real, common ending and saying so beats leaving it blank.
enum InquiryLostReason: String, CaseIterable, Sendable {
    case theyDeclined = "they_declined"
    case notAFit = "not_a_fit"
    case neverHeardBack = "never_heard_back"

    var label: String {
        switch self {
        case .theyDeclined: return "They declined"
        case .notAFit: return "Not a fit for me"
        case .neverHeardBack: return "Never heard back"
        }
    }

    // Their refusal is the hard lost case. Dan's own pass and a silence both leave the door open for
    // future work, which is what the soft case means.
    var outcome: Outcome {
        self == .theyDeclined ? .lostHard : .lostSoft
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
    // #2063: who the latest reply named, so Dan's answer reaches them too. An inquiry has no send group to
    // over-send to, so the failure here is the mirror image of the prospect one: somebody the inquirer
    // brought in (a partner, a colleague booking alongside them) is silently dropped from the answer.
    var replyAudience: [String]?
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
    // Why it ended, for #16. Optional and defaulted so it migrates additively; an inquiry closed before
    // this shipped simply has none, and reporting falls back to what it can derive.
    var lostReasonRaw: String? = nil

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

    // nil when it was never lost, or when a later version wrote a reason this build doesn't know. A raw
    // value it can't read must never be reported as one of today's reasons.
    var lostReason: InquiryLostReason? {
        lostReasonRaw.flatMap(InquiryLostReason.init(rawValue:))
    }

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

    // #1513: when this inquiry next needs Dan, so it can be grouped in Reached out under the SAME date
    // heading as the shows there ("Grouped by when to reach out next", #1233) instead of carrying its
    // event date into a view where every other date means something else.
    //
    // Waiting on them: the day the follow-up nudge comes due. Already replied: the day they replied,
    // because it is Dan's move now, and dating it at a nudge that no longer applies would bury the one
    // row actually waiting on him under a future heading. nil when there is nothing to be due about
    // (never sent, so it belongs in Review; or closed).
    var nextReachOutDate: Date? {
        guard isOpen, let sentAt else { return nil }
        if replied { return repliedAt ?? sentAt }
        return BusinessDay.advance(sentAt, byBusinessDays: Inquiry.followUpNudgeBusinessDays)
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
    // Soft duplicate check on the EVENT natural key. A blank key (no event pinned down) is NEVER a
    // duplicate, so two under-specified inquiries don't falsely collide.
    //
    // #1504: `excluding` is the inquiry being EDITED. Without it an edit compares the record against
    // itself and warns Dan that everything he opens is already logged. A clash with any OTHER inquiry
    // must still warn, or editing becomes a way to create the very duplicate this exists to catch.
    static func duplicate(ofKey key: String, in inquiries: [Inquiry],
                          excluding editing: Inquiry? = nil) -> Inquiry? {
        guard !isBlankKey(key) else { return nil }
        return inquiries.first { $0.naturalKey == key && $0 !== editing }
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

    // Trims a field and turns a blank one into a genuine absence, so an empty string never masquerades
    // as a value. Shared by create and apply: if editing normalized differently, the same event typed
    // once at intake and once as an edit would key two different ways and stop matching itself.
    static func cleaned(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    // Build a normalized inquiry from raw form fields and insert it, so a bare intake keys cleanly and
    // the view stays free of rules.
    @discardableResult
    static func create(source: InquirySource, name: String, email: String?, eventName: String,
                       performanceDate: String?, venue: String?, notes: String?,
                       in context: ModelContext) -> Inquiry {
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

    // #1504: apply edited fields to an existing inquiry, through the SAME normalization create uses.
    // Touches only what the form owns. The reply already sent, the watched thread, and the outcome are
    // none of the edit sheet's business, and `naturalKey` is computed, so correcting the event or
    // filling in a date learned later simply re-keys the inquiry.
    static func apply(to inquiry: Inquiry, source: InquirySource, name: String, email: String?,
                      eventName: String, performanceDate: String?, venue: String?, notes: String?) {
        inquiry.sourceRaw = source.rawValue
        inquiry.inquirerName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        inquiry.inquirerEmail = cleaned(email)
        inquiry.eventName = eventName.trimmingCharacters(in: .whitespacesAndNewlines)
        inquiry.performanceDate = cleaned(performanceDate)
        inquiry.venue = cleaned(venue)
        inquiry.notes = cleaned(notes)
    }

    // Reopening an inquiry has to show the date it already has. An absent or unparseable stored value
    // must NOT come back pre-ticked, which would silently invent a date on the next save.
    static func editingDate(from stored: String?) -> (hasDate: Bool, date: Date) {
        guard let stored, let parsed = EasternDate.date(from: stored) else { return (false, Date()) }
        return (true, parsed)
    }

    // The sheet's whole save action: log a new inquiry or change the one being edited, then confirm the
    // write. Kept out of the view so both the choice and its failure path are reachable by a test
    // (#863). Returns whether it is confirmed on disk; a false means Dan has already been warned. The
    // sheet is the ONLY place these fields exist, so a silently failed write is his typing gone.
    @discardableResult
    static func save(editing: Inquiry?, source: InquirySource, name: String, email: String?,
                     eventName: String, performanceDate: String?, venue: String?, notes: String?,
                     in context: ModelContext, feedback: ActionFeedback) -> Bool {
        if let editing {
            apply(to: editing, source: source, name: name, email: email, eventName: eventName,
                  performanceDate: performanceDate, venue: venue, notes: notes)
        } else {
            create(source: source, name: name, email: email, eventName: eventName,
                   performanceDate: performanceDate, venue: venue, notes: notes, in: context)
        }
        return context.saveOrWarn(org: name.trimmingCharacters(in: .whitespaces), feedback: feedback)
    }
}
