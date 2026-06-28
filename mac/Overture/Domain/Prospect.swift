import Foundation
import SwiftData

// A discovered, ranked performance Dan reviews. Persisted locally (SwiftData,
// cloud sync off, like Downbeat). Identity is a content-derived natural key
// (group + date + venue) so re-ingesting a fresh results file updates the ranking
// in place and PRESERVES Dan's keep/dismiss decision rather than duplicating rows.

@Model
final class Prospect {
    @Attribute(.unique) var naturalKey: String

    var groupName: String
    var discipline: String
    var venue: String?
    var performanceDate: String?
    var sourceListingURL: String?
    var websiteURL: String?

    var priorRelationship: String
    var production: String
    var profile: String
    var coverage: String

    var fitScore: Int
    var tier: String
    var fitReason: String

    var matchedClientName: String?
    var possibleMatchSource: String?
    var possibleMatchName: String?

    var statusRaw: String
    var dismissReasonRaw: String?
    var ingestedAt: Date

    // The rules classifier's confidence ("confident"/"uncertain"). Scout-owned: refreshed
    // every run. confidenceReviewedByDan is Dan-owned: once he has eyeballed a guess, the
    // "unsure" mark stays cleared even across re-scouts (#32). Defaulted so existing
    // records and the scout's inserts are unaffected.
    var classificationConfidence: String = Confidence.confident.rawValue
    var confidenceReviewedByDan: Bool = false
    // Dan-owned: once he corrects the discipline/production, the scout must not revert
    // them. Mirrors confidenceReviewedByDan. Defaulted so existing records migrate cleanly.
    var classificationOverriddenByDan: Bool = false

    // Filled by the Prep run (Trigger 2). Defaulted so the scout's inserts are unaffected.
    var contactName: String? = nil
    var contactRole: String? = nil
    var contactEmail: String? = nil
    var contactMethodRaw: String? = nil
    var contactConfidenceRaw: String? = nil
    var contactFormURL: String? = nil

    var draftSubject: String? = nil
    var draftBody: String? = nil
    var draftVariant: String? = nil
    var draftEditedByDan: Bool = false

    // Phase 2.5 (#393): set when the salutation normalizer found a greeting-shaped opener it could
    // not confidently strip, so the stored body may still carry an inline greeting. Such a draft is
    // treated as act-only (it can't be reused for a differently-named recipient) until a Prep re-run
    // produces a salutation-free body.
    var draftNeedsSalutationReview: Bool = false

    // A freeze SEPARATE from draftEditedByDan (#392): set once Dan has curated the recipient list
    // (manual add/remove at approval, Phase 7), so a Prep re-run never clobbers his recipient edits
    // even while a body redraft still flows. The two freezes are independent.
    var recipientsEditedByDan: Bool = false

    // The voice-learning pair (#240 / #119). originalDraft* is the AI's draft before Dan's first
    // SUBSTANTIVE edit, snapshotted once and never clobbered; sent* is the exact text emailed,
    // frozen at send so a later draft edit can't make the "sent" side lie. Together they let the
    // drafter learn how Dan revises. Defaulted nil so existing records migrate cleanly (lightweight
    // additive, like #132).
    var originalDraftSubject: String? = nil
    var originalDraftBody: String? = nil
    var sentSubject: String? = nil
    var sentBody: String? = nil

    // Dan-owned: he marked this send as a poor example ("don't learn from this") so the voice-learning
    // export (#241) skips it, keeping the signal clean (#244). Defaulted so existing records migrate
    // cleanly (lightweight additive, like #132).
    var excludedFromVoiceLearning: Bool = false

    // Outcome of the outreach. Defaults to no-response (like Dan's sheet), so most
    // prospects need no touch. Set manually by Dan, or automatically later from
    // Gmail (replied) / Downbeat (booked). Only meaningful once sent.
    var outcomeRaw: String = Outcome.noResponse.rawValue
    var outcomeSourceRaw: String? = nil
    var outcomeAt: Date? = nil
    var sentAt: Date? = nil
    var gmailThreadId: String? = nil   // set on send; used for reply detection
    var gmailMessageId: String? = nil  // the first send's Message-ID, so a follow-up threads (#74)
    var sendError: String? = nil       // last send failure, surfaced for retry
    var lostReason: String? = nil      // Dan's free-text note when he marks a lead lost (#90/#91)
    // The prior relationship captured the moment Dan sent, immune to later scout refreshes, so a
    // Downbeat match can tell a genuine new booking from a pre-existing client (#66).
    var priorRelationshipAtSend: String? = nil

    // Follow-up sequencer state (#45). Defaulted so existing records migrate cleanly.
    var followUpCount: Int = 0
    var lastFollowUpAt: Date? = nil

    // Conversation lifecycle (#111): where an active reply sits between replied and booked, plus the
    // timing anchors for its reminder (setAt = when the state was set; remindedAt = last time Dan
    // acted on the reminder, re-anchoring it) and the auto/manual source so #112 cannot overwrite a
    // manual set. Defaulted nil so existing records migrate cleanly (lightweight, like #132).
    var conversationStateRaw: String? = nil
    var conversationStateSetAt: Date? = nil
    var conversationRemindedAt: Date? = nil
    var conversationStateSourceRaw: String? = nil

    // The latest inbound reply's text + when it was captured (#112): pulled lazily when a reply is
    // first detected, handed to the classify workflow. Defaulted nil so existing records migrate cleanly.
    var lastReplyText: String? = nil
    var lastReplyAt: Date? = nil
    // The Gmail message id of the auto-detected reply (#219), recorded so a wrong detection can be
    // dismissed by id. dismissedReplyId holds the one Dan said was not a real reply. Defaulted so
    // existing records migrate cleanly.
    var lastReplyId: String? = nil
    var dismissedReplyId: String? = nil

    // Downbeat client id from the relationship match, used for per-event booking
    // detection (#99). Defaulted so existing records migrate cleanly.
    var downbeatClientId: String? = nil

    // Set when a booking match is possible but not conclusive enough to auto-book.
    // Defaulted so existing records migrate cleanly.
    var bookingSuggested: Bool = false

    // Set when Dan explicitly dismisses a booking suggestion ("Not a booking").
    // Once set, reconcileBooked suppresses soft re-suggestions (possible/client-list/
    // tiebreak), but an exact Downbeat booking STILL auto-books — dismissal silences
    // noise, not hard facts (#114). Defaulted so existing records migrate cleanly.
    var bookingSuggestionDismissed: Bool = false

    // The Downbeat booking id that auto-booked this prospect (#203). Recorded at auto-book
    // time so Dan can reject that exact match. Defaulted so existing records migrate cleanly.
    var autoBookedFromBookingId: String? = nil

    // Booking ids Dan has rejected as wrong auto-detections (#203), newline-joined for
    // SwiftData. reconcileBooked skips re-booking from any id in this set, so the rejection
    // sticks per booking (a different genuine booking can still auto-detect). Read via
    // rejectedBookingIds. Defaulted so existing records migrate cleanly.
    var rejectedBookingIdsRaw: String = ""

    // The performance's recipients (#391), stored as a JSON-encoded blob and read via `recipients`.
    // Defaulted "" so existing records and the scout's inserts migrate cleanly (additive, like the
    // other defaulted fields the live store already carries). "" decodes to no recipients.
    var recipientsRaw: String = ""

    // Fallback for #203 when the rejected auto-booking has no recorded source id (#218): a booking
    // auto-detected before that id was tracked. Set true on such a reject so reconcileBooked never
    // re-books this prospect at all. Defaulted so existing records migrate cleanly.
    var autoBookingRejectedWithoutId: Bool = false

    // Run-collapse fields (#132). The engine groups overlapping performances into a
    // collapsed run and emits these on every member. Defaulted so existing records
    // and older results files migrate cleanly without an explicit migration plan.
    var runEndDate: String? = nil
    var partOfRelatedRun: Bool = false
    var runSourceURLs: [String] = []

    // Consecutive scouts where this prospect's source was scouted but it was absent from the
    // feed (#133). Reset to 0 whenever it reappears. Past performances are never counted.
    // Defaulted so existing records migrate cleanly.
    var missedScoutCount: Int = 0

    init(
        naturalKey: String,
        groupName: String,
        discipline: String,
        venue: String?,
        performanceDate: String?,
        sourceListingURL: String?,
        websiteURL: String?,
        priorRelationship: String,
        production: String,
        profile: String,
        coverage: String,
        fitScore: Int,
        tier: String,
        fitReason: String,
        matchedClientName: String?,
        possibleMatchSource: String?,
        possibleMatchName: String?,
        status: ReviewStatus = .new,
        dismissReason: DismissReason? = nil,
        ingestedAt: Date = Date(),
        runEndDate: String? = nil,
        partOfRelatedRun: Bool = false,
        runSourceURLs: [String] = []
    ) {
        self.naturalKey = naturalKey
        self.groupName = groupName
        self.discipline = discipline
        self.venue = venue
        self.performanceDate = performanceDate
        self.sourceListingURL = sourceListingURL
        self.websiteURL = websiteURL
        self.priorRelationship = priorRelationship
        self.production = production
        self.profile = profile
        self.coverage = coverage
        self.fitScore = fitScore
        self.tier = tier
        self.fitReason = fitReason
        self.matchedClientName = matchedClientName
        self.possibleMatchSource = possibleMatchSource
        self.possibleMatchName = possibleMatchName
        self.statusRaw = status.rawValue
        self.dismissReasonRaw = dismissReason?.rawValue
        self.ingestedAt = ingestedAt
        self.runEndDate = runEndDate
        self.partOfRelatedRun = partOfRelatedRun
        self.runSourceURLs = runSourceURLs
    }

    var status: ReviewStatus {
        get { ReviewStatus(rawValue: statusRaw) ?? .new }
        set { statusRaw = newValue.rawValue }
    }

    // Gone from the feed: absent across enough consecutive scouts to rule out a transient
    // partial feed (#133). Cancelled or pulled, not merely a one-off glitch.
    var disappearedFromFeed: Bool { missedScoutCount >= FeedReconcile.goneThreshold }

    var contactMethod: ContactMethod? {
        get { contactMethodRaw.flatMap(ContactMethod.init) }
        set { contactMethodRaw = newValue?.rawValue }
    }

    var contactConfidence: ContactConfidence? {
        get { contactConfidenceRaw.flatMap(ContactConfidence.init) }
        set { contactConfidenceRaw = newValue?.rawValue }
    }

    var hasDraft: Bool { draftBody != nil }

    // Apply Dan's edit to the draft (#240 / #119). The FIRST time the edited text meaningfully
    // differs from the AI draft, snapshot the AI version into originalDraft* so the voice-learning
    // loop can study the delta; trivial / no-op saves never overwrite that baseline. draftEditedByDan
    // keeps its existing meaning (set on any save) so the lint-hiding and re-draft-skip behavior is
    // unchanged.
    func applyEdit(subject: String, body: String) {
        if originalDraftBody == nil,
           Prospect.isSubstantiveEdit(oldSubject: draftSubject, oldBody: draftBody,
                                      newSubject: subject, newBody: body) {
            originalDraftSubject = draftSubject
            originalDraftBody = draftBody
        }
        draftSubject = subject
        draftBody = body
        draftEditedByDan = true
    }

    // Freeze the exact subject/body emailed, immune to later draft edits, so the "sent" side of the
    // learning pair stays trustworthy (#240 / #119).
    func freezeSentCopy(subject: String, body: String) {
        sentSubject = subject
        sentBody = body
    }

    // An edit is substantive (worth learning from) when the text differs beyond whitespace. Pure
    // whitespace or no-op saves are not a voice signal; the richer min-delta gate lives in the
    // export step (#241).
    static func isSubstantiveEdit(oldSubject: String?, oldBody: String?,
                                  newSubject: String, newBody: String) -> Bool {
        normalizedForEditCompare(oldBody) != normalizedForEditCompare(newBody)
            || normalizedForEditCompare(oldSubject) != normalizedForEditCompare(newSubject)
    }

    private static func normalizedForEditCompare(_ s: String?) -> String {
        (s ?? "")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var outcome: Outcome {
        get { Outcome.fromStored(outcomeRaw) }
        set { outcomeRaw = newValue.rawValue }
    }

    var conversationState: ConversationState? {
        get { conversationStateRaw.flatMap(ConversationState.init) }
        set { conversationStateRaw = newValue?.rawValue }
    }

    var conversationStateSource: OutcomeSource? {
        get { conversationStateSourceRaw.flatMap(OutcomeSource.init) }
        set { conversationStateSourceRaw = newValue?.rawValue }
    }

    // Record an outcome as Dan's own call (manual source, timestamped, booking-suggestion cleared),
    // matching the queue's setOutcome so ReplyService never silently overwrites it (#111 / #60).
    func markOutcomeManually(_ outcome: Outcome, now: Date) {
        self.outcome = outcome
        outcomeSourceRaw = OutcomeSource.manual.rawValue
        outcomeAt = now
        bookingSuggested = false
    }

    // Booking ids Dan has rejected as wrong auto-detections (#203).
    var rejectedBookingIds: Set<String> {
        Set(rejectedBookingIdsRaw.split(separator: "\n").map(String.init))
    }

    // The performance's recipients (#391): each act contact, presenter, or manual add Dan emails
    // separately over the shared body. Stored as a JSON blob in recipientsRaw (Recipient is a struct,
    // not a stringly value, so JSON rather than rejectedBookingIds' newline-join), with a computed
    // accessor and mutating helpers — the same raw-string-plus-accessor idiom the live store already
    // survives. All writers decode -> change one element -> re-encode; the empty string decodes to [].
    var recipients: [Recipient] {
        get {
            guard let data = recipientsRaw.data(using: .utf8), !data.isEmpty else { return [] }
            return (try? JSONDecoder().decode([Recipient].self, from: data)) ?? []
        }
        set { recipientsRaw = Prospect.encodeRecipients(newValue) }
    }

    private static func encodeRecipients(_ recipients: [Recipient]) -> String {
        guard !recipients.isEmpty, let data = try? JSONEncoder().encode(recipients) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    func setRecipients(_ recipients: [Recipient]) {
        self.recipients = recipients
    }

    func addRecipient(_ recipient: Recipient) {
        recipients.append(recipient)
    }

    func removeRecipient(id: String) {
        recipients.removeAll { $0.id == id }
    }

    // Mutate exactly one recipient in place (the decode-mutate-reencode idiom). A no-op for an
    // unknown id, so callers needn't pre-check membership.
    func updateRecipient(id: String, _ mutate: (inout Recipient) -> Void) {
        var current = recipients
        guard let index = current.firstIndex(where: { $0.id == id }) else { return }
        mutate(&current[index])
        recipients = current
    }

    // Dan dismissed a wrong auto-detected reply (#219): revert to no-response and remember which
    // reply (its Gmail message id) was wrong so ReplyService never re-flags that same one, while a
    // genuinely newer reply on the thread still gets detected.
    func dismissAutoReply(now: Date) {
        guard outcome == .replied else { return }
        outcome = .noResponse
        outcomeSourceRaw = nil
        outcomeAt = now
        lastReplyText = nil
        lastReplyAt = nil
        dismissedReplyId = lastReplyId
    }

    // Dan rejected a wrong auto-detected booking (#203): revert the outcome to no-response and
    // remember this specific booking id so reconcileBooked never re-books from it. Other genuine
    // bookings for the same group can still auto-detect (per-booking, not per-prospect).
    func rejectAutoBooking(bookingId: String?, now: Date) {
        outcome = .noResponse
        outcomeSourceRaw = nil
        outcomeAt = now
        bookingSuggested = false
        bookingSuggestionDismissed = true
        autoBookedFromBookingId = nil
        if let bookingId, !bookingId.isEmpty {
            var ids = rejectedBookingIds
            ids.insert(bookingId)
            rejectedBookingIdsRaw = ids.sorted().joined(separator: "\n")
        } else {
            // Legacy auto-booking with no recorded id: block re-detection for this prospect (#218).
            autoBookingRejectedWithoutId = true
        }
    }

    // Dan sets the conversation state by hand (#111). An active state also marks a not-yet-replied
    // lead as replied (manual) so the silent FollowUp sequencer stands down and the lead can't be in
    // both queues; an existing reply keeps its source. `declined` resolves the lead to lost-soft
    // (door open), recording the decline and stopping the reminders in one action.
    func setConversationState(_ state: ConversationState, now: Date) {
        conversationState = state
        conversationStateSetAt = now
        conversationStateSource = .manual
        if state == .declined {
            markOutcomeManually(.lostSoft, now: now)
        } else if outcome == .noResponse {
            markOutcomeManually(.replied, now: now)
        }
    }

    // "Remind me later": step an active reminder forward by re-anchoring it, without sending.
    func remindLater(now: Date) {
        conversationRemindedAt = now
    }

    // The AI's auto-classification (#112) suggests a state (source = auto). NEVER overwrites a state
    // Dan set by hand (#60). The suggestion surfaces immediately in Due until Dan confirms/corrects;
    // the lead is already .replied from detection, so the outcome is left alone.
    func suggestConversationState(_ state: ConversationState, now: Date) {
        guard conversationStateSource != .manual else { return }
        conversationState = state
        conversationStateSetAt = now
        conversationStateSource = .auto
    }

    // Dan accepts a suggestion: it becomes his (manual) and the timed reminder clock restarts from now.
    func confirmConversationState(now: Date) {
        guard conversationState != nil else { return }
        conversationStateSource = .manual
        conversationStateSetAt = now
        conversationRemindedAt = nil
    }

    // True once the email was actually sent (approved-and-sent). Outcomes only count
    // for these in the stats.
    // Contacted means the pitch actually went out (#200): a send always stamps sentAt and
    // advances status to .contacted. Reads the send date so prospects sent before the explicit
    // .contacted state (stored as .approved + a send date) still count, with no migration.
    var wasContacted: Bool { sentAt != nil }

    // The content key two results files agree on for "the same performance". Each
    // part is CANONICALIZED so a scraped name and the same name fetched/decoded
    // elsewhere produce one key (the silent-mismatch root): HTML entities decoded,
    // unicode normalized (NFC), exotic whitespace folded, lowercased, trimmed.
    static func makeNaturalKey(groupName: String, performanceDate: String?, venue: String?) -> String {
        [groupName, performanceDate ?? "", venue ?? ""]
            .map(canonicalize)
            .joined(separator: "|")
    }

    static func canonicalize(_ raw: String) -> String {
        var s = decodeHTMLEntities(raw)
        // Fold non-breaking and other unicode spaces to a normal space.
        s = s.replacingOccurrences(of: #"[\u{00A0}\u{2007}\u{202F}\u{2009}\u{200A}\u{2002}\u{2003}]"#,
                                   with: " ", options: .regularExpression)
        s = s.precomposedStringWithCanonicalMapping // NFC
        s = s.lowercased()
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Decodes the HTML entities realistically seen in venue calendar text: the named
    // basics plus decimal/hex numeric refs. Not a full HTML parser (none needed).
    static func decodeHTMLEntities(_ input: String) -> String {
        var result = ""
        result.reserveCapacity(input.count)
        var i = input.startIndex
        let named: [String: String] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
            "nbsp": " ", "mdash": "—", "ndash": "–", "hellip": "…", "rsquo": "’",
            "lsquo": "‘", "ldquo": "“", "rdquo": "”", "eacute": "é", "egrave": "è",
        ]
        while i < input.endIndex {
            if input[i] == "&", let semi = input[i...].firstIndex(of: ";") {
                let body = String(input[input.index(after: i)..<semi])
                var decoded: String? = nil
                if body.hasPrefix("#x") || body.hasPrefix("#X") {
                    if let code = UInt32(body.dropFirst(2), radix: 16), let scalar = Unicode.Scalar(code) {
                        decoded = String(scalar)
                    }
                } else if body.hasPrefix("#") {
                    if let code = UInt32(body.dropFirst()), let scalar = Unicode.Scalar(code) {
                        decoded = String(scalar)
                    }
                } else {
                    decoded = named[body]
                }
                if let decoded {
                    result += decoded
                    i = input.index(after: semi)
                    continue
                }
            }
            result.append(input[i])
            i = input.index(after: i)
        }
        return result
    }
}
