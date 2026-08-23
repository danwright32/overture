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
// #2400: an inquiry ends in the SAME words a pitched show does. Its own three reasons (They declined, Not
// a fit for me, Never heard back) were already three of the five under different spellings, and one of them
// (`neverHeardBack`) had deliberately been given the shared stored value from the start precisely so the two
// halves of the funnel could be added together. This finishes that job for the other two.
//
// A namespace rather than a second enum: there is one vocabulary (`ShowOutcome`) and this says which part of
// it an inquiry can reach. Dan's decision, 2026-08-09, when asked directly.
enum InquiryEnding {
    // The four Dan picks from the row's "Mark lost" section. Booked is deliberately absent: it has its own
    // control on the row, and putting it under a heading that says "lost" would be the one place the words
    // and the act disagree.
    //
    // Derived from `ShowOutcome.pitched` rather than listed again, so a value added to the show side cannot
    // silently leave the inquiry side behind.
    static var danCanChoose: [ShowOutcome] { ShowOutcome.pitched.filter { $0 != .booked } }
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
    // #2661: the `References` header carried by the LAST message Overture sent on this inquiry's
    // conversation, which is the ancestry the NEXT one has to extend. Beside `gmailMessageId` and written
    // in the same step, for the same reason `Recipient.gmailReferences` is (#2648): the chain is only
    // meaningful as the ancestry OF that message, and updating one without the other emits a chain that
    // skips a generation. Nil until a reply has been sent, which is the first message with any ancestry.
    var gmailReferences: String?
    var threadIdDegraded: Bool = false
    // #2647: the Message-ID read back off the sent reply could not be read, so a later message on this
    // inquiry's thread cannot reference it. The Recipient side carries the same flag for the same reason.
    var threadingDegraded: Bool = false
    // #2712: when the conversation on this inquiry was FOUND in Gmail rather than started by a send from
    // inside Overture. Its readers are `replyWatchConversationIsAttached` (which stops the threading
    // repair claiming Dan's own hand-sent message as Overture's, and stops a bounce on the thread being
    // blamed on the inquirer) and the row's own badge, which says where the conversation came from.
    //
    // A separate fact from the predicate rather than inferred from it, for the same reason
    // `Recipient.conversationAttachedAt` is: the predicate is deliberately self-healing and stops being
    // true the moment Overture's own reply lands on the thread, while the fact that Overture found this
    // conversation rather than starting it is permanent.
    var conversationAttachedAt: Date?
    // #2712: when the mailbox was last read for a message from this inquirer. The mirror of
    // `Recipient.replyCandidateSearchedAt` and read by the same `ReplySearchScope.windowStart`: the shared
    // high-water mark says how far the MAILBOX has been read, which is only an answer for an inquiry that
    // was in scope when it was read, so one logged since then needs its own window back to when Dan
    // logged it.
    var replyCandidateSearchedAt: Date?
    // #2675: WHY the last reply failed to go out. Its reader is the inquiry's own row, added in the same
    // change (L46). Before this the sender returned `false` and stored nothing, so the reason lived only
    // in a notice that clears, while the inquiry stayed on screen looking unsent with nothing saying why
    // (L126). The prospect side has carried the same field on `Recipient` and `Prospect` since #499, and
    // both are read through the same `SendFailureLine`, so one failure cannot be worded two ways.
    var sendError: String?

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
    // #2113: who actually wrote the latest reply, and when they sent it. An inquiry starts from one
    // person, but the answer can come from a colleague copied in, so the writer is no more knowable here
    // than on a shared prospect thread.
    var replyFromAddress: String?
    var replyFromName: String?
    var inboundReplySentAt: Date?
    // #2653: the Message-ID of the message being answered, the same fact `Recipient` carries and for the
    // same reason. Read through `ReplyThreading`.
    var inboundReplyMessageId: String?
    // #2149: when the repair pass last TRIED to fill in the message text, whether or not it found any.
    // Without it a reply with no decodable body stays in the gap and its thread is refetched forever.
    var replyTextCheckedAt: Date?
    // #2943: when Dan ANSWERED, the mirror of `Recipient.replyHandledAt` (#2170) rather than a second
    // vocabulary for the same fact. Its own field, because the reply genuinely happened and its arrival
    // still dates the row.
    //
    // Both paths that recorded an answer used to say it by clearing `replied`, which is L163 exactly: the
    // model had no field for the fact, so the fact was expressed by negating a neighbouring one, and every
    // reader of `replied` went on reading that negation as "nobody ever wrote back". The row reverted to
    // "Sent, waiting to hear back" and #16's funnel filed a real two way conversation as silence.
    //
    // Optional and nil by default, which is the only kind of schema change this app makes (see
    // `AppSchema`): purely additive, handled by SwiftData's lightweight migration, no MigrationPlan. Nil
    // reads as "not answered", which is honest for every row already in the store: measured 2026-08-18,
    // the live store holds ONE inquiry, booked, never sent and carrying no thread, so nothing there has an
    // answer this field could have recorded and there is nothing to backfill.
    var replyHandledAt: Date?
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
    // LEGACY, read by ShowOutcomeBackfill.runForInquiries and written by nothing else since #2400. The
    // ending an inquiry reached now lives in `showOutcomeRaw` below, in the same words and the same stored
    // spellings a show uses, so a season report reads one column across both halves of the funnel.
    var lostReasonRaw: String? = nil
    // #2400: how this inquiry ended, from the one vocabulary (`ShowOutcome`). Nil means it has not ended,
    // and that is the only thing nil means: somebody is still waiting on a reply.
    var showOutcomeRaw: String? = nil

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

    // nil when it has not ended, or when a later version wrote an ending this build doesn't know. A raw
    // value it can't read must never be reported as one of today's endings.
    var showOutcome: ShowOutcome? {
        get { showOutcomeRaw.flatMap(ShowOutcome.init(rawValue:)) }
        set { showOutcomeRaw = newValue?.rawValue }
    }

    // #2915: WHEN it was closed out, so a reply arriving afterwards can be told from the one Dan already
    // had in hand. Same field and same reason as the prospect's.
    var showOutcomeAt: Date? = nil

    // #2915: a reply after a close out, deciding through the SAME `ReplyReopen` the prospect uses. An
    // inquiry closed as "never heard back" whose sender writes back is the same situation as a scouted
    // show's, and it rides the same reply check, so a rule stated only on the prospect would leave half
    // the funnel uncovered (L30).
    @discardableResult
    func reopenOnReply(at repliedAt: Date) -> Bool {
        guard ReplyReopen.shouldClear(outcome: showOutcome, closedAt: showOutcomeAt,
                                      repliedAt: repliedAt) else { return false }
        showOutcome = nil
        showOutcomeAt = nil
        return true
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

    // #2943: they wrote and nobody has dealt with it yet. The mirror of `Recipient.hasUnhandledReply`,
    // asking the same three facts first: `isOpen` is where an inquiry keeps what `resolution == nil`
    // keeps for a contact, and a bounce is its own fact on both.
    //
    // Compared against when their message ARRIVED rather than being a plain flag, for the same reason the
    // contact side is: a SECOND reply on the same thread re-opens it, and without that the back half of
    // every conversation would be unanswerable from the queue.
    var hasUnhandledReply: Bool {
        guard replied, isOpen, !bounced else { return false }
        guard let handled = replyHandledAt else { return true }
        guard let theirs = replyArrivedAt else { return false }
        return theirs > handled
    }

    // #2943: they wrote, Dan answered, and nothing has arrived since. Written OVER `hasUnhandledReply`
    // rather than beside it (#2921's rule, and the same shape `Recipient.replyIsAnswered` took in #2919),
    // so the two can never disagree about whether this conversation has been dealt with. The three facts
    // in front of it are the three that predicate short-circuits on, and they are here because
    // `!hasUnhandledReply` on its own is equally true of an inquiry nobody ever answered, one that
    // bounced, and one Dan closed out. A line may claim only what its check actually measured (L11).
    var replyIsAnswered: Bool {
        replied && !bounced && isOpen && replyHandledAt != nil && !hasUnhandledReply
    }

    // #2943: the answer, recorded. Never moves backwards, exactly as `Recipient.markReplyAnswered` does
    // not, so a later answer on this conversation cannot be undone by an earlier one arriving out of
    // order.
    func markReplyAnswered(now: Date) {
        guard let existing = replyHandledAt else { replyHandledAt = now; return }
        if now > existing { replyHandledAt = now }
    }

    // #1513: when this inquiry next needs Dan, so it can be grouped in Reached out under the SAME date
    // heading as the shows there ("Grouped by when to reach out next", #1233) instead of carrying its
    // event date into a view where every other date means something else.
    //
    // Waiting on them: the day the follow-up nudge comes due. Already replied: the day the reply arrived,
    // because it is Dan's move now, and dating it at a nudge that no longer applies would bury the one
    // row actually waiting on him under a future heading. nil when there is nothing to be due about
    // (never sent, so it belongs in Review; or closed).
    //
    // #2118: answered through NextReachOut, the same rule a scouted show's contact answers it through, so
    // the two kinds of row that share one set of date headings cannot mean different things by them. It
    // shares only the rule: an inquiry stays a fully separate entity, its own pacing below, and it still
    // bypasses the queue's lead-time window because somebody is waiting on a reply whatever the event date.
    //
    // Takes `now` because a reply that has already landed is dated by its own arrival, clamped to the
    // clock. Waiting was the divergence this closed: the show half took the moment the person WROTE and
    // this half took the moment Overture noticed, up to a night apart on the two cards for one reply.
    func nextReachOutDate(now: Date) -> Date? {
        NextReachOut.date(isInPlay: isOpen && sentAt != nil, now: now) {
            guard let sentAt else { return [] }
            // Falls back to the send for a row that replied before an arrival time was ever captured,
            // which is a real past instant rather than the reading of the clock `.waiting(since: nil)`
            // would settle for.
            // #2943: asked of the UNHANDLED reply, not of `replied`. Once the answer became its own fact
            // rather than the absence of a reply, `replied` stays true for the rest of the conversation,
            // and a row keyed on it would sit under the day they wrote forever instead of restarting the
            // nudge from Dan's answer.
            if hasUnhandledReply { return [.waiting(since: replyArrivedAt ?? sentAt)] }
            return [.scheduled(BusinessDay.advance(sentAt, byBusinessDays: Inquiry.followUpNudgeBusinessDays))]
        }
    }

    // #2943: `!hasUnhandledReply` rather than `!replied`, for the reason above. Chasing is what Dan does
    // while he is waiting on THEM, which is exactly the state an answered conversation is back in.
    func followUpNudgeDue(now: Date) -> Bool {
        guard isOpen, !hasUnhandledReply, !bounced, let sentAt else { return false }
        // #1438: the two nudges are drawn as badges side by side on the row, so they must not both be
        // true. Once the silence is long enough to suggest closing, that supersedes "follow up"; showing
        // both told Dan to chase it and to give up on it at the same time.
        guard !shouldSuggestClosing(now: now) else { return false }
        return BusinessDay.count(after: sentAt, through: now) >= Inquiry.followUpNudgeBusinessDays
    }

    func shouldSuggestClosing(now: Date) -> Bool {
        guard isOpen, !hasUnhandledReply, let sentAt else { return false }
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
        reasonSaveIsDisabled(name: name) == nil
    }

    // #2546: why Save is refusing, taken from the same predicate that decides whether it is. The sheet
    // shows this beside the button, so a grey Save and the words next to it cannot disagree (L109).
    //
    // It names the FIELD rather than saying the form is incomplete, because only one of the six is
    // required and every other box on the sheet is legitimately blank at that moment. "Fill in the
    // required fields" would send him looking at five that are already fine.
    static func reasonSaveIsDisabled(name: String) -> String? {
        name.trimmingCharacters(in: .whitespaces).isEmpty ? "Add the name of whoever got in touch" : nil
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
