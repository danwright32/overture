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
    // The presenter the classifier read when it judged this row. Defaulted, so existing rows migrate
    // cleanly: they predate this and stay nil, which honestly means "we never kept it" rather than
    // "the listing named none".
    //
    // Stored because classification is otherwise a ONE-WAY DOOR. EventClassifier reads title AND
    // presenter, but only the title survived as `groupName`, so a rule change could never be replayed
    // over the store: recomputing from `groupName` alone does not reproduce the classifier, it
    // approximates it, and writes answers a real scout would not give. #980 hit exactly this and had to
    // ship forward-only.
    var presenter: String?
    // #970: where the page said the show is, VERBATIM and unresolved. Defaulted, so existing rows
    // migrate cleanly and stay nil, which is honest: every row that predates this was never asked.
    //
    // Stored raw on purpose. The geo verdict is NOT stored: it is derived at queue time from this plus
    // the discipline, so changing the rule (or Dan refusing a town) re-decides every row at once
    // instead of leaving a stale verdict baked into the store.
    var location: String?
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

    var draftSubject: String? = nil
    var draftBody: String? = nil
    var draftVariant: String? = nil
    var draftEditedByDan: Bool = false

    // Phase 2.5 (#393): set when the salutation normalizer found a greeting-shaped opener it could
    // not confidently strip, so the stored body may still carry an inline greeting. Such a draft is
    // treated as act-only (it can't be reused for a differently-named recipient) until a Prep re-run
    // produces a salutation-free body.
    var draftNeedsSalutationReview: Bool = false

    // #718: the EXACT draftBody text Dan explicitly confirmed is fine to send despite the flag
    // above, deliberately a copy of the text rather than a bare boolean, so a later edit to
    // DIFFERENT text silently invalidates the override with no extra migration bookkeeping (see
    // isSalutationReviewOverridden below). `nil` means never overridden (or a stale override).
    var draftSalutationReviewOverriddenBody: String? = nil

    // True only when the current draftBody is the EXACT text Dan overrode; a mismatch (edited
    // since, or never overridden) means the #407 block still applies.
    var isSalutationReviewOverridden: Bool {
        draftSalutationReviewOverriddenBody != nil && draftSalutationReviewOverriddenBody == draftBody
    }

    // A freeze SEPARATE from draftEditedByDan (#392): set once Dan has curated the recipient list
    // (manual add/remove at approval, Phase 7), so a Prep re-run never clobbers his recipient edits
    // even while a body redraft still flows. The two freezes are independent.
    var recipientsEditedByDan: Bool = false

    // #367: Dan asked for a re-prep on a prospect that already has a draft. Independent flags so he
    // can request just a redraft, just a fresh contact search, or both; PrepQueueBuilder.needsPrep
    // admits a prospect with either flag set even though hasDraft is true. Cleared by PrepImporter
    // once the run produces any result for this prospect, served or not.
    var reprepDraftRequested: Bool = false
    var reprepContactsRequested: Bool = false
    // #733: when a Prep run last produced a result for this prospect (a normal fresh draft OR a
    // served re-prep), so the UI can warn before re-prepping something that was just researched.
    var reprepLastServedAt: Date? = nil

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
    // tiebreak), but an exact Downbeat booking STILL auto-books: dismissal silences
    // noise, not hard facts (#114). Defaulted so existing records migrate cleanly.
    var bookingSuggestionDismissed: Bool = false

    // #611: a fit-risk Prep's own research found (the org's site explicitly names its own
    // photographer), never changes fitScore/tier, surfaced as a dismissible warning so Dan
    // decides himself whether to deprioritize or skip. Mirrors bookingSuggested/
    // bookingSuggestionDismissed's shape: the original finding is kept even after Dan dismisses
    // it, with dismissal tracked separately, so a later re-run reporting the SAME note doesn't
    // silently reactivate something already judged a false positive (PrepImporter.ingest resets
    // the dismissal only when the note text actually changes). Defaulted so existing records
    // migrate cleanly.
    var alreadyCoveredNote: String? = nil
    var alreadyCoveredDismissed: Bool = false

    // Performer-name warm-lead detection (#749, plan #748, issue #585). Prep matched this
    // performance's PERFORMER (not its org) to a past client, and corrected the relationship the
    // org-name matcher had scored cold. Defaulted so existing records migrate cleanly.
    //
    // relationshipCorrectedByPerformerMatch is the sticky guard, and it is the load-bearing one: the
    // next scout re-derives priorRelationship from the ORG name, which by definition still doesn't
    // match, so without this lock every correction would be silently reverted on the next run and the
    // draft would sit warm next to a cold tier with nothing explaining it. Phase 2 (#750) makes
    // ScoutService.apply honor it.
    var relationshipCorrectedByPerformerMatch: Bool = false
    var matchedPerformerName: String? = nil
    var performerMatchNote: String? = nil
    // Dismissed: Dan says this specific match is WRONG (reverts the correction from the snapshot
    // below). Reviewed: Dan has merely SEEN it. Deliberately distinct, because Phase 4 (#752) gates
    // the warm drafting tone on reviewed, not on the mere absence of a dismissal. Both reset to false
    // whenever a new match fires, so a re-prep that finds a DIFFERENT performer is judged afresh
    // rather than inheriting a verdict Dan passed on something else (the #611 alreadyCovered shape).
    var performerMatchDismissed: Bool = false
    var performerMatchReviewed: Bool = false
    // Pre-correction snapshot, so dismissing restores exactly what the scout had scored rather than
    // guessing at an inverse. Written only when a correction is actually applied.
    var performerMatchPreviousRelationship: String? = nil
    var performerMatchPreviousFitScore: Int? = nil
    var performerMatchPreviousTier: String? = nil
    var performerMatchPreviousMatchedClientName: String? = nil
    var performerMatchPreviousDownbeatClientId: String? = nil

    // #769: this ORG asked Dan to stop emailing them. Dan-owned; the scout never touches it. Distinct
    // from any performance-level loss: "not this show" and "never contact us again" are genuinely
    // different messages, and conflating them would either burn orgs who only meant the former or keep
    // pitching ones who meant the latter. Set on every prospect of the org (see OrgDoNotContact), so
    // the derived "dnc" history record survives whichever show Dan happened to be looking at.
    // Defaulted so existing records migrate cleanly.
    var orgDoNotContact: Bool = false

    // #384: Dan passed on this exact show before (same org, same venue), so the fit score carries a
    // penalty. Scout-owned and refreshed every run, like the rest of the scoring inputs. Stored rather
    // than recomputed on demand because ClassificationOverride rebuilds the ranking Candidate from
    // this prospect's own fields: without it, the penalty would silently evaporate the moment Dan
    // corrected the discipline. Defaulted so existing records migrate cleanly.
    var passedOnThisShow: Bool = false

    // #901: a day of this show's run that Dan cannot work, as a BlockedCalendar.Day key.
    //
    // Scout-owned and refreshed every run: the day may stop being blocked (the vacation was cancelled),
    // or start being blocked by something else (a shoot booked over the week he was merely away).
    //
    // The KEY is stored, never the sentence. The sentence is composed for display from the key, so
    // rewording the copy cannot silently re-raise every conflict Dan has already cleared, and cannot
    // leave old prospects quoting last month's wording back at him.
    var conflictKey: String? = nil

    // Dan-owned: the exact conflict he waved through ("I can shoot this anyway"). Stored as the KEY he
    // accepted rather than a bare boolean, on the #718 pattern, so a conflict that CHANGES under him is
    // a fact he has not seen yet and blocks again. Waving through "you're on vacation" is not waving
    // through "you are already shooting a wedding that night".
    var conflictClearedKey: String? = nil

    // The two keys above, reduced to the one question every gate actually asks. Derived, but STORED, for
    // a reason that is not premature optimization: RootView gates the "Prep kept" button with a SwiftData
    // #Predicate, a #Predicate cannot call a Swift function, and the rule expressed inline there
    // ("a key exists AND differs from the cleared one", two optional-to-optional comparisons on top of the
    // existing four-term expression) overruns the #Predicate type-checker outright.
    //
    // The alternative was a predicate that is merely a SUPERSET of the real rule, refined afterwards in
    // Swift. That is the #863 bug by construction: the button would light up for a show the Prep run then
    // refuses to work on, and Dan would click Prep and watch it find nothing.
    //
    // So the flag is written in exactly three places (setScoutConflict, clearConflict, restoreConflict),
    // it is what `hasUnclearedConflict` reads, and it is what the #Predicate reads. One column, one truth,
    // and no way for the button and the work-list to disagree.
    var conflictOpen: Bool = false

    // The Downbeat booking id that auto-booked this prospect (#203). Recorded at auto-book
    // time so Dan can reject that exact match. Defaulted so existing records migrate cleanly.
    var autoBookedFromBookingId: String? = nil

    // Booking ids Dan has rejected as wrong auto-detections (#203), newline-joined for
    // SwiftData. reconcileBooked skips re-booking from any id in this set, so the rejection
    // sticks per booking (a different genuine booking can still auto-detect). Read via
    // rejectedBookingIds. Defaulted so existing records migrate cleanly.
    var rejectedBookingIdsRaw: String = ""

    // The performance's recipients as their own rows (#409). Cascade-deleted with the performance.
    // (Recipients briefly lived in a JSON blob, #391; that column was dropped once the live store was
    // migrated to rows; Dan's store never carried blob data, so there was nothing to migrate from it.)
    @Relationship(deleteRule: .cascade, inverse: \Recipient.prospect)
    var recipients: [Recipient] = []

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

    // #804: the model that wrote the draft currently on this show.
    //
    // Dan pinned drafting to the strong TIER rather than an exact version, so he picks up each new Opus
    // as it ships and accepts that his voice can shift with it. That trade is only reasonable because
    // this exists: when an email reads oddly he can tell whether the model changed underneath him,
    // instead of sensing that something did and having no way to check. Defaulted, so drafts written
    // before this existed migrate cleanly and simply carry no trace.
    var draftModel: String? = nil

    // #792: contacts on this show held back by a review guard and waiting on Dan. A show can be
    // genuinely contacted (somebody was emailed) AND still have somebody waiting, and both facts have to
    // survive at once: the bug was that the first silently erased the second.
    var blockedContactCount: Int {
        recipients.filter(\.isBlockedAwaitingReview).count
    }

    // #864: the typed reason, so callers stop hand-rolling `DismissReason(rawValue: dismissReasonRaw ?? "")`.
    var dismissReason: DismissReason? {
        get { dismissReasonRaw.flatMap(DismissReason.init(rawValue:)) }
        set { dismissReasonRaw = newValue?.rawValue }
    }

    // #861/#864: "has this show demonstrably happened?", asked in exactly one place.
    //
    // The Scout pill asks it to decide what is still waiting on Dan, and the launch retirement asks it to
    // decide what has rotted. They are the same question, and if they ever answered it differently a show
    // could be retired while still being counted, or counted while already retired. Judged on the run's
    // LAST night (EasternDate, #798), so a run that opened last week but plays through next week is still
    // a live lead. An UNDATED show has not happened: "date to be confirmed" is a normal state on a season
    // page, and treating it as past would silently throw away a real lead whose date is not announced yet.
    func hasGoneBy(today: String) -> Bool {
        EasternDate.runHasPassed(
            lastNight: EasternDate.runLastNight(runEndDate: runEndDate, performanceDate: performanceDate),
            today: today
        )
    }

    // Consecutive scouts where this prospect's source was scouted but it was absent from the
    // feed (#133). Reset to 0 whenever it reappears. Past performances are never counted.
    // Defaulted so existing records migrate cleanly.
    var missedScoutCount: Int = 0

    // Which watched sources surfaced this show (#771). The `sourceId` of a WatchedSource row, or the
    // reserved "manual" for a lead Dan added by hand. Defaulted so existing records migrate cleanly
    // without an explicit migration plan (the same precedent as runSourceURLs above); the #800 backfill
    // then stamps every stored Carnegie show, which is where every prospect in the store today did in
    // fact come from.
    //
    // A LIST, and never a @Relationship, for two separate reasons:
    //
    // Many, because the upsert chain deliberately MERGES the same show arriving from a venue's calendar
    // and from the presenter's own site into one row. A single id could only remember one of them, and
    // Phase 3's per-source reconcile would then find the show absent from the other source's feed and
    // accrue misses toward disappearedFromFeed on a live show Dan may already have drafted and emailed.
    //
    // Plain strings, because a @Relationship(deleteRule: .cascade) from a source row to its prospects
    // would mean the one action Dan asked for (stop watching a permanently dead source) deletes every
    // prospect it ever surfaced, cascading into Recipient, including sent emails and live reply threads.
    var sourceIds: [String] = []

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

    var hasDraft: Bool { draftBody != nil }

    // MARK: - The date conflict (#901)

    // A day of this run Dan cannot work, that he has NOT waved through. This is the one every gate asks:
    // it keeps the show out of the Prep run (no money is spent drafting a show he cannot shoot) and out
    // of the send (a conflict can turn up AFTER the draft exists, which a prep-only gate would miss).
    var hasUnclearedConflict: Bool { conflictOpen }

    // What Dan reads on the row: "You blocked Nov 14 (Vacation)." / "You're already shooting X on Nov 14."
    // Composed from the key, never stored, so it can never be a stale quotation of older copy.
    var conflictNote: String? {
        conflictKey.flatMap { BlockedCalendar.Day(key: $0) }?.reason
    }

    // The scout's write, every run. The ONLY thing that sets a conflict.
    //
    // A conflict that has GONE takes the clearance with it: a clearance is Dan's answer to one specific
    // clash, so once that clash no longer exists there is nothing left for it to be an answer to, and
    // leaving it behind would silently pre-clear a DIFFERENT conflict that landed on the same show later.
    func setScoutConflict(_ key: String?) {
        conflictKey = key
        if key == nil { conflictClearedKey = nil }
        conflictOpen = key != nil && key != conflictClearedKey
    }

    // "I can shoot this anyway." His call, recorded against the exact conflict he saw, so a conflict that
    // CHANGES under him is a new fact he has not seen and blocks again (#718's pattern).
    func clearConflict() {
        conflictClearedKey = conflictKey
        conflictOpen = false
    }

    // Undo of the above (the queue offers it in the confirmation banner, like every other reversible
    // action here), which puts the flag back rather than pretending the clash never existed.
    func restoreConflict() {
        conflictClearedKey = nil
        conflictOpen = conflictKey != nil
    }

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
    // learning pair stays trustworthy (#240 / #119). Idempotent (#395): under per-recipient fan-out
    // this fires once per recipient, but the captured pair is lead-level and one-per-shared-body, so
    // only the FIRST send writes it. Later recipient sends (and any draft edits after) leave it intact,
    // making the frozen template stable regardless of recipient send order.
    func freezeSentCopy(subject: String, body: String) {
        guard sentBody == nil else { return }
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

    // Phase F (#424): the show's status derived from its contacts (Booked > Active > Lost > New).
    var performanceStatus: PerformanceStatus { PerformanceStatus.of(self) }

    // Closed for routine follow-ups/reminders: booked, every contact resolved (derived), or Dan closed
    // the lead by hand / with a closing note (a lead lostSoft/lostHard not yet written through to a
    // contact). A fresh reply still surfaces independently via `hasUnhandledReply`.
    var isClosed: Bool {
        // #769: the org asked Dan to stop. Nothing routine may fire again, on any of their shows. This
        // is the load-bearing line: without it a do-not-contact org would keep receiving follow-ups
        // and reminders on a show already sent, which is precisely the email that issue exists to
        // prevent. Suppressing the untried recipients only stops FIRST sends.
        if orgDoNotContact { return true }
        switch performanceStatus {
        case .booked, .lostDoorOpen, .lostNotInterested: return true
        case .active, .new: return outcome == .lostSoft || outcome == .lostHard
        }
    }

    // A contact replied and nobody has dealt with it: not booked, and some replied / unresolved /
    // un-bounced contact hasn't had ITS OWN conversation state hand-set yet (#653: per-recipient, not
    // the lead's legacy field, so triaging one contact -- or a stale lead-level value -- never masks
    // a different, still-uncategorized contact's reply). Deliberately INDEPENDENT of `isClosed` (#424,
    // Dan's call) so a late reply on a closed show still surfaces for triage.
    var hasUnhandledReply: Bool {
        performanceStatus != .booked
            && recipients.contains { $0.hasUnhandledReply && $0.conversationStateSource != .manual }
    }

    // Record a lead outcome as Dan's own call (manual source, timestamped, booking-suggestion
    // cleared) so ReplyService never silently overwrites it (#111 / #60). Still used by the lead-level
    // booking confirm, closing close, and conversation state; the editable outcome picker is gone (#447).
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

    // Wipe every trace of a performer match (#750). Used when a fresh, confident ORG match supersedes
    // the correction: the lock, the note Dan reads, and the snapshot the dismiss path would revert to
    // all describe a finding that no longer applies, and leaving any of them behind means the UI
    // explains this prospect's warm tier with a performer who had nothing to do with it. The single
    // owner of this reset, so the Phase 4 dismiss/revert path reuses it rather than growing a second
    // copy that forgets a field.
    func clearPerformerMatch() {
        relationshipCorrectedByPerformerMatch = false
        matchedPerformerName = nil
        performerMatchNote = nil
        performerMatchDismissed = false
        performerMatchReviewed = false
        performerMatchPreviousRelationship = nil
        performerMatchPreviousFitScore = nil
        performerMatchPreviousTier = nil
        performerMatchPreviousMatchedClientName = nil
        performerMatchPreviousDownbeatClientId = nil
    }

    // The performer-match correction is live: it was made, Dan hasn't said it was wrong, and so the
    // scout must not revert it (#750).
    var hasActivePerformerMatch: Bool {
        relationshipCorrectedByPerformerMatch && !performerMatchDismissed
    }

    // Dan says this match is WRONG (#752). Restore exactly what the scout had scored, from the
    // snapshot taken when the correction was applied, rather than guessing at an inverse. Clearing
    // the lock releases Phase 2's guard, so ordinary org-name matching resumes on the next scout run
    // instead of protecting a correction Dan has rejected.
    //
    // The FINDING itself (matchedPerformerName, performerMatchNote) deliberately survives: it is the
    // record that stops PrepImporter re-applying this same rejected match the next time it ingests
    // the same evidence. Keeping the finding and tracking the rejection separately is the
    // alreadyCoveredNote/alreadyCoveredDismissed shape (#611).
    func dismissPerformerMatch() {
        guard relationshipCorrectedByPerformerMatch else { return }
        if let relationship = performerMatchPreviousRelationship { priorRelationship = relationship }
        if let score = performerMatchPreviousFitScore { fitScore = score }
        if let previousTier = performerMatchPreviousTier { tier = previousTier }
        matchedClientName = performerMatchPreviousMatchedClientName
        downbeatClientId = performerMatchPreviousDownbeatClientId
        relationshipCorrectedByPerformerMatch = false
        performerMatchDismissed = true
    }

    // Dan says this match is RIGHT (#752, his call: an explicit confirmation, never merely having
    // laid eyes on the prospect). Only this unlocks the warm drafting tone, so an email can sound
    // like it is going to a returning client only because Dan actively said the match was correct.
    // Changes nothing about the score, which the correction already applied.
    func confirmPerformerMatch() {
        guard relationshipCorrectedByPerformerMatch else { return }
        performerMatchReviewed = true
        performerMatchDismissed = false
    }

    // The relationship the DRAFTER is allowed to see (#752). The correction is sticky by design, so it
    // survives into a later Prep cycle's redraft, and that run picks its tone from this value. Until
    // Dan confirms the match, the drafter sees the cold value the scout originally had, so an
    // unconfirmed guess can change how the lead is RANKED (useful immediately) but never how an email
    // SOUNDS (irreversible once sent). Read by PrepQueueService, the single writer of the queue's
    // priorRelationship field.
    var priorRelationshipForDrafting: String {
        guard relationshipCorrectedByPerformerMatch, !performerMatchReviewed else {
            return priorRelationship
        }
        return performerMatchPreviousRelationship ?? PriorRelationship.none.rawValue
    }

    // The performance's recipients (#409): each act contact, presenter, or manual add Dan emails
    // separately over the shared body, now their own rows (the `recipients` @Relationship above).
    // These helpers mutate the relationship directly; deletions go through the model context so a
    // removed recipient row is actually destroyed, not just detached.
    func setRecipients(_ newRecipients: [Recipient]) {
        for existing in recipients where !newRecipients.contains(where: { $0 === existing }) {
            modelContext?.delete(existing)
        }
        recipients = newRecipients
    }

    func addRecipient(_ recipient: Recipient) {
        recipients.append(recipient)
    }

    func removeRecipient(id: String) {
        for r in recipients where r.id == id {
            modelContext?.delete(r)
        }
        recipients.removeAll { $0.id == id }
    }

    // Dan removes a recipient by hand (#399). A never-sent contact is truly gone, nothing to lose.
    // An already-sent contact is never deleted: it just stops being pursued (no more follow-ups or
    // reminders) without recording a decline, so reply/decline stats stay honest. Distinct from the
    // real "Closed (not now)" mark (markOutcomeManually), which DOES mean Dan read an actual no.
    func removeOrSuppressRecipient(id: String) {
        guard let r = recipients.first(where: { $0.id == id }) else { return }
        if r.sendState == .pending {
            removeRecipient(id: id)
        } else {
            r.sendState = .suppressed
            r.suppressionReason = .removedByDan
        }
    }

    // Mutate exactly one recipient in place (it is a managed row, so the change persists on save).
    // A no-op for an unknown id, so callers needn't pre-check membership.
    func updateRecipient(id: String, _ mutate: (Recipient) -> Void) {
        guard let r = recipients.first(where: { $0.id == id }) else { return }
        mutate(r)
    }

    // Takes every still-untried recipient on this lead out of future sends once the lead itself has
    // resolved, so a resolved show can't still generate a fresh cold email to a sibling contact it
    // never reached. Originally only the auto-detected-booking freeze (DownbeatBooking); #542 shares
    // it across every manual resolve path too (confirming a booking by hand, declining, closing).
    // Mirrors the original freeze exactly: only still-.pending recipients move, already-sent or
    // already-suppressed ones are untouched. Leaves resolution untouched (nil): an untried contact was
    // never actually declined or booked, it is simply no longer being pursued.
    func suppressUntriedRecipients(reason: RecipientSuppressionReason) {
        for r in recipients where r.sendState == .pending {
            r.sendState = .suppressed
            r.suppressionReason = reason
        }
    }

    // #430: a reply on a multi-contact show auto-pauses the still-unsent contacts (those that have an
    // address and haven't gone yet) so the drip/queue won't email them while Dan triages the reply.
    // Its own flag, distinct from the booking-freeze (sendState .suppressed).
    func pausePendingForReply() {
        for r in recipients where r.sendState == .pending && (r.email?.isEmpty == false) {
            r.pausedByReply = true
        }
    }

    // #430: Dan triaged the reply (set/confirmed a conversation state, marked a contact, or dismissed
    // a false reply), so the paused contacts resume and are sendable again.
    func resumePausedRecipients() {
        for r in recipients where r.pausedByReply { r.pausedByReply = false }
    }

    // Dan dismissed a wrong auto-detected reply (#219): revert to no-response and remember which
    // reply (its Gmail message id) was wrong so ReplyService never re-flags that same one, while a
    // genuinely newer reply on the thread still gets detected.
    func dismissAutoReply(now: Date) {
        guard outcome == .replied else { return }
        let dismissed = lastReplyId
        outcome = .noResponse
        outcomeSourceRaw = nil
        outcomeAt = now
        lastReplyText = nil
        lastReplyAt = nil
        dismissedReplyId = dismissed
        // Per-recipient detection (#418 A2) reads recipient.dismissedReplyId, so the lead dismiss must
        // also dismiss the contact(s) that produced this reply or detection would immediately re-flag it.
        // (Until the Phase B per-recipient surface, this keeps the existing lead-level dismiss button correct.)
        for r in recipients where r.replied && r.lastReplyId == dismissed {
            r.dismissAutoReply()
        }
        resumePausedRecipients()   // #430: a false reply shouldn't keep the other contacts paused
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

    // True once the email was actually sent (approved-and-sent). Outcomes only count
    // for these in the stats.
    // Contacted means the pitch actually went out (#200): a send always stamps sentAt and
    // advances status to .contacted. Reads the send date so prospects sent before the explicit
    // .contacted state (stored as .approved + a send date) still count, with no migration.
    var wasContacted: Bool { sentAt != nil }

    // #963: `wasContacted` alone is not proof of a real send (#378's lesson, extended past the
    // Reached-out queue): every genuine send (SendService.deliver, and DebugStaging's synthetic
    // stand-in for one) stamps `gmailMessageId` alongside `sentAt`, so a record with a timestamp but
    // no message id was never actually sent. Outreach stats and booking auto-detection read this,
    // not the bare timestamp, so a future bug that sets `sentAt` without sending can't silently
    // skew a booking rate or auto-book a show that was never pitched.
    var wasProvablyContacted: Bool { gmailMessageId != nil }

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
