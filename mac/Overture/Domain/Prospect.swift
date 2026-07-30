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
    // #1788: this row's blank presenter is a name Overture DISCARDED (the run reported the room), not a
    // page that named nobody. Stored rather than derived: once the name is drained the two are identical
    // in the data, and only the boundary that dropped it knows which happened. Optional so every row
    // written before this decodes unchanged and simply carries none.
    var presenterWasTheRoom: Bool? = nil
    // #970: where the page said the show is, VERBATIM and unresolved. Defaulted, so existing rows
    // migrate cleanly and stay nil, which is honest: every row that predates this was never asked.
    //
    // Stored raw on purpose. The geo verdict is NOT stored: it is derived at queue time from this plus
    // the discipline, so changing the rule (or Dan refusing a town) re-decides every row at once
    // instead of leaving a stale verdict baked into the store.
    //
    // #1065: this ONE raw string now feeds TWO independent consumers with DIFFERENT tolerances, so a
    // change to how it is populated or normalized has to satisfy BOTH:
    //   1. the GEOGRAPHY GATE, EventPlace.resolve, which places or refuses a show and reads the messier
    //      shapes on purpose (a full street address, a spelled-out state, a country, a region).
    //   2. the DISPLAY FALLBACK, VenueDisplay.resolve's safeCityStateLine (#1030), which is stricter:
    //      it shows this on the card ONLY when it is already a clean city/state shape and REJECTS
    //      anything address-shaped.
    // LocationTwoConsumersGuardTests pins both tolerances against shared inputs, so a change that
    // silently diverges them turns that guard red. Do not touch this field's shape without checking
    // both consumers.
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
    // "Last read", NOT "first found": ScoutService.apply rewrites this on every run, including on shows
    // already pitched, so it walks forward for as long as a show stays on a watched calendar.
    var ingestedAt: Date

    // #16: when this show FIRST entered the store, which is the funnel's opening node and the one thing
    // ingestedAt above cannot answer. Written once at insert and never touched again by the scout.
    // Defaulted nil so existing rows migrate cleanly; FirstSeenBackfill then stamps them from their
    // ingestedAt, which for a show re-scouted since it was found is an UPPER BOUND (no later than), not
    // an exact sighting. Nothing distinguishes a backfilled row from a natively stamped one, so a report
    // covering the months before this shipped is reading upper bounds (Dan's call, 2026-07-23).
    var firstSeenAt: Date? = nil

    // #16: when this show LEFT the queue, the missing half of dismissReasonRaw above. The eight reasons
    // are the whole drop-off side of the funnel and none of them carried a date, so a cut could be
    // counted but never placed in a year. Owned entirely by markDismissed/clearDismissal, so the four
    // paths that dismiss a show (Dan's own cut, wentBy, tooFar, a DNC org) and the two that restore one
    // cannot drift apart. Nil on every row dismissed before this shipped, which honestly means "we never
    // recorded it" rather than a guessed date.
    var dismissedAt: Date? = nil

    // #4: the ranking features exactly as they stood when Dan pitched. The scout refreshes every one of
    // these forever after the email went out (ScoutService.apply), so a feedback loop reading them off
    // the live row would learn from a profile the pitch was never scored against. Frozen once, on the
    // first send, alongside priorRelationshipAtSend and freezeSentCopy, which exist for the same reason.
    var fitScoreAtSend: Int? = nil
    var tierAtSend: String? = nil
    var profileAtSend: String? = nil
    var coverageAtSend: String? = nil
    var disciplineAtSend: String? = nil
    var productionAtSend: String? = nil

    // RETAINED STORAGE, read by nothing (#1533). These held the rules classifier's confidence and Dan's
    // acknowledgement of it, for the "Not sure of the genre or type" badge that #1533 retired. Nothing
    // writes or reads either one now; they are left on the model deliberately rather than deleted,
    // because every schema change this app has ever made was ADDITIVE and it carries no MigrationPlan or
    // VersionedSchema (see AppSchema). Dropping a stored property would be its first subtractive
    // migration, against a live store whose only safety net is the launch backup, so it gets its own
    // change with a rehearsal against a store clone first.
    var classificationConfidence: String = "confident"
    var confidenceReviewedByDan: Bool = false
    // Dan-owned: once he corrects the discipline/production, the scout must not revert
    // them. Mirrors confidenceReviewedByDan. Defaulted so existing records migrate cleanly.
    var classificationOverriddenByDan: Bool = false

    // #1274: Dan-owned display-name override. groupName is normally scout-owned and rewritten every
    // re-ingest (ScoutService.apply). Once Dan renames a show, this flag makes apply() leave his name
    // alone. The rename deliberately does NOT touch naturalKey (still scout-name-derived), so the
    // scout's exact-key match keeps firing and no duplicate row is inserted. `scoutGroupName` mirrors
    // the LATEST scout-emitted name (kept current by apply even while overridden) so a "reset to scout
    // name" restores the real, current name instantly. Both defaulted so existing records migrate cleanly.
    var groupNameOverriddenByDan: Bool = false
    var scoutGroupName: String? = nil

    // #1308 Layer 2: when a reachability probe last researched this show's contacts (nil = never probed).
    // Set unconditionally by the probe import whether or not an email was found, so the Review badge can
    // say "email found"/"no email found" firmly instead of falling back to the free heuristic forever.
    // Defaulted so existing records migrate cleanly.
    var reachabilityProbedAt: Date? = nil
    // #1596 (milestone 32 Phase 3): what the check CONCLUDED, stored rather than re-derived from
    // `recipients` on every render. Raw string so the schema stays additive and a value written by a
    // future version decodes here without a migration. nil means no check has ever run, which is a
    // different thing from a check that came back empty. See Reachability.ProbeResult.
    var reachabilityResultRaw: String? = nil
    // #1722: WHY the check above came back with nothing usable, when the run said. Its own field rather
    // than a fifth `reachabilityResultRaw` value, deliberately: the verdict really is "no email found",
    // and a new verdict would reach the fit score, ContactScoreAdjustment, the org ledger and a stored
    // migration, none of which should move because a sentence got more honest. Raw string for the same
    // additive reason as the line above; an unrecognised value reads as no reason and falls back to the
    // old wording rather than becoming a claim the app cannot explain. See Reachability.EmptyReason.
    var reachabilityEmptyReasonRaw: String? = nil
    // #1648 Phase D: what this show scored immediately BEFORE its contact answer last moved the score,
    // and which answer moved it. Kept so the weights can be retuned later against a clean baseline, which
    // is impossible if the only surviving number is the adjusted one.
    //
    // Three fields on this model now hold a "score from earlier" and they have DIFFERENT LIFETIMES; do
    // not merge them. `fitScoreAtSend` freezes once at first send and never moves again.
    // `performerMatchPreviousFitScore` is transient undo state, cleared by clearPerformerMatch. These
    // two describe the MOST RECENT contact adjustment and are OVERWRITTEN on every re-check, never
    // write-once, or a re-check would leave them describing an answer that is no longer the one applied.
    //
    // Deliberately NOT stored: the score AFTER the adjustment. It is the value that goes stale the moment
    // the weights are retuned, which is the exact scenario this record exists to serve, and it is not
    // recoverable from `fitScore` either, since a genre correction or a performer match can rewrite that
    // afterwards. The after is derived, never remembered.
    var fitScoreBeforeContactCheck: Int? = nil
    var contactRouteAtScore: String? = nil
    // #1648: the contact answer as the RANKER should read it. Identical to the stored result except
    // that an answer past its 90 day expiry reads as `.unchecked`, so a demotion lifts at the same
    // moment the badge reverts to "worth re-checking" and the card and the score can never disagree
    // about whether an answer is current. Both read the SAME staleness helper, evaluated at the same
    // instant, rather than each asking the clock separately.
    //
    // It RECOMPUTES rather than restoring the score stored before the check: restoring an integer
    // would also silently undo any unrelated correction made since (the #1648 Phase A3 mistake).
    func contactRouteForScoring(now: Date) -> ContactRoute {
        if Reachability.probeIsStale(probedAt: reachabilityProbedAt, now: now) { return .unchecked }
        return ContactRoute(probeResult: reachabilityResult)
    }
    // #1596 Phase 3: classify this row's CURRENT recipients into a stored result. One definition, used by
    // every writer, so the importer's upgrade and the row's own snapshot can never disagree about what
    // counts as sendable. Mirrors the venue and press guard outcome exactly: an address held by either
    // guard is real but not sendable, which is `weakContactOnly` rather than `noEmailFound` (#1324).
    var reachabilityResultFromRecipients: Reachability.ProbeResult {
        if recipients.contains(where: \.isSendablePending) { return .emailFound }
        let weak = recipients.contains { r in
            r.email?.isEmpty == false
                && ((r.looksLikeVenue && !r.looksLikeVenueDismissed)
                    || (r.looksLikePressContact && !r.looksLikePressContactDismissed))
        }
        if weak { return .weakContactOnly }
        // #1626: no address anywhere, but the act publishes a form on its own site. Ranked below the
        // address states deliberately: those are about whether an address exists at all, and leaving
        // their order untouched keeps #1324's tested behaviour exactly as it was. The combination (a
        // venue address AND the act's own form) was not observed in the 2026-07-27 run and is not
        // re-ranked on speculation.
        return usableContactFormURLs.isEmpty ? .noEmailFound : .contactFormOnly
    }

    // #1626: the contact forms Dan would actually use, which is a form on the ACT's own site. An
    // Instagram or another login-walled page is a dead end (his rule, 2026-07-27), judged through the
    // one shared social-host list rather than a second copy of it.
    //
    // #1629: and never the ROOM's own booking form, judged through the same VenueContactGuard
    // comparison the email path has used since #388. Without it a check that returned the host venue's
    // form gave a card reading "Contact form only" that pointed Dan straight at the room, which is the
    // oldest standing rule in the product (#368: a room's own address is never a real contact, not even
    // a named booking person). Excluding it here means the show falls through to `noEmailFound`, the
    // same answer he would get if the check had returned the room's email address.
    var usableContactFormURLs: [String] {
        recipients.compactMap { r -> String? in
            guard let raw = r.contactFormURL?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty, !Reachability.isSocialOnly(raw),
                  !VenueContactGuard.looksLikeVenue(formURL: raw, venue: venue),
                  // #1636: nor a press or media page, the same rule the email path applies to a
                  // "press@" address (#722/#635). The venue guard above cannot cover this: the live case
                  // is a press office on a domain that is not this show's room at all.
                  !PressContactGuard.looksLikePressContact(formURL: raw),
                  let url = URL(string: raw), url.scheme != nil else { return nil }
            return raw
        }
    }

    var reachabilityResult: Reachability.ProbeResult? {
        get { reachabilityResultRaw.flatMap(Reachability.ProbeResult.init(rawValue:)) }
        set { reachabilityResultRaw = newValue?.rawValue }
    }

    // #1722. An unrecognised stored value reads as nil (no reason given), which the copy degrades to the
    // old sentence, so a newer producer's vocabulary can never put a claim on the card this build cannot
    // explain.
    var reachabilityEmptyReason: Reachability.EmptyReason? {
        get { reachabilityEmptyReasonRaw.flatMap(Reachability.EmptyReason.init(rawValue:)) }
        set { reachabilityEmptyReasonRaw = newValue?.rawValue }
    }

    var draftSubject: String? = nil
    var draftBody: String? = nil
    var draftVariant: String? = nil
    var draftEditedByDan: Bool = false

    // #5 (opener A/B testing), Phase 1: the experiment stamp. All defaulted so existing records migrate
    // cleanly (lightweight additive, like #132). `assignedArm` is the APP-ASSIGNED archetype token and is
    // the source of truth for the tally, deliberately distinct from `draftVariant` (the drafter's echo of
    // what it actually produced). `experimentID` ties this stamp to the Experiment that assigned it, so a
    // past experiment's outcomes stay attributable after the next one goes active. Assignment is sticky:
    // once `assignedArm` is set it is never re-rolled. `experimentOpenerEdited` is set at send time
    // (Phase 3) when Dan materially rewrote the assigned opener, which excludes that send from the tally.
    var experimentID: String? = nil
    var assignedArm: String? = nil
    var experimentOpenerEdited: Bool = false

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

    // #1824: what the Prep run understood this show to BE, read off the show's own listing page (which the
    // APP renders and hands over, because the detached run's tools cannot). One plain line, or nothing when
    // the run had nothing to go on, in which case `showSummaryAbsentReasonRaw` says which of the three
    // honest reasons applied. Shown on the review card so Dan can see whether the draft beside it was
    // grounded in anything. Defaulted so existing records migrate cleanly.
    var showSummary: String? = nil
    // The raw wire string, so a value a newer run invents survives the round trip and is simply not
    // understood, rather than failing the decode. Read through `showSummaryAbsence` below, never directly.
    var showSummaryAbsentReasonRaw: String? = nil

    var showSummaryAbsence: ShowSummaryAbsence? {
        showSummaryAbsentReasonRaw.flatMap(ShowSummaryAbsence.init(rawValue:))
    }

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
    // Pre-correction snapshot, so dismissing restores exactly what the scout had rather than guessing
    // at an inverse. Written only when a correction is actually applied, and CLEARED by
    // clearPerformerMatch: transient undo state, never an analytics record. #1648 Phase D adds separate
    // durable fields for "the score before a contact check" precisely because these have the wrong
    // lifetime for it; do not reuse them there.
    var performerMatchPreviousRelationship: String? = nil
    // #1648 Phase A3: these two are no longer READ. dismissPerformerMatch now restores the relationship
    // and re-scores from the row, because putting a snapshotted number back also discarded any genuine
    // change made since. They are still written, and kept rather than dropped, so a dismiss remains
    // auditable and so removing two attributes does not ride along in an unrelated schema change.
    // Anything that starts reading them again is reintroducing the bug A3 fixed. Tracked for removal.
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
    // #1523: the nights this run ACTUALLY plays, not merely its first and last. A weekly series spans
    // months and is dark most of them, so the span alone made every blocked day inside it look like a
    // clash. Stored rather than derived because the member rows are gone by the time anything asks.
    // Empty on every row that predates this, which BlockedCalendar.conflict reads as "fall back to the
    // span", so nothing already flagged is cleared on no evidence. Fills in on the next scout.
    var runNights: [String] = []

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

    // #861/#864/#1540: "is this show past the point where Dan would ever work it?", asked in one place.
    //
    // The Scout pill asks it to decide what is still waiting on Dan, and the launch retirement asks it to
    // decide what has rotted. They are the same question, and if they ever answered it differently a show
    // could be retired while still being counted, or counted while already retired.
    //
    // #1540 moved the answer from the run's closing night to its OPENING night, reversing #1122: Dan
    // ruled that once a run has opened its client no longer needs photos, so an untriaged opened run is
    // not a lead he will work, whatever nights remain on it. A run opening TONIGHT has not opened yet.
    // An UNDATED show has not opened: "date to be confirmed" is a normal state on a season page, and
    // treating it as gone would silently throw away a real lead whose date is not announced yet.
    func hasOpened(today: String) -> Bool {
        EasternDate.runHasOpened(openingNight: performanceDate, today: today)
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

    // #1260 Phase 2: the merged-concert identity, persisted so a merged prospect survives a re-scout
    // WITHOUT depending on emit order. It is the synthetic id SameDateVenueMerge stamps
    // ("samedatevenue:DATE|VENUE"), already carried transiently on AssembledProspect but never stored
    // until now. Set only for a merged DCINY cluster; nil for every ordinary show. Its purpose: the
    // merged prospect's natural key rides on the emit-order-dependent combinedName and its URL-based
    // re-key fallbacks ride on the representative row's URL (which shifts when the scout re-lists the
    // rows in a new order or with refreshed links), so a re-scout could otherwise miss all three match
    // arms and silently INSERT A DUPLICATE, stranding Dan's keep/dismiss. Matching on this stable id
    // closes that. Defaulted optional, so existing rows decode with nil (same additive-migration
    // precedent as runSourceURLs/sourceIds above); a stored merged prospect gains its id on its first
    // post-deploy re-scout (forward-only, matching #980).
    var seriesId: String? = nil

    // #1276: is this a merged same-date+venue concert (so its groupName is a conductor LIST, not a real
    // title)? The one true test, so the outbound-email guard keys on the persisted merge fact rather than
    // sniffing for a "; " that a legitimate single title (Carnegie's "Symphony of Psalms & Les Noces
    // (Stravinsky); No Time for Idle Tears") also carries.
    var isMergedConcert: Bool { SameDateVenueMerge.isMerged(seriesId) }

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
        runSourceURLs: [String] = [],
        runNights: [String] = []
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
        // #16: the row exists as of this moment, so its first sighting IS its first ingest. The only
        // place this is ever written for a new row; the scout's refresh path deliberately skips it.
        self.firstSeenAt = ingestedAt
        self.runEndDate = runEndDate
        self.partOfRelatedRun = partOfRelatedRun
        self.runSourceURLs = runSourceURLs
        self.runNights = runNights
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

    // #1501: which night of this show's run the clash is on. Read off the stored key and this show's own
    // date, so the pill and the sentence below are two renderings of ONE decision rather than two rules.
    var conflictScope: ConflictScope? {
        ConflictScope.of(blockedDate: conflictKey.flatMap { BlockedCalendar.Day(key: $0) }?.date,
                         performanceDate: performanceDate)
    }

    // What Dan reads on the row: "You blocked Nov 14 (Vacation)." / "You're already shooting X on Nov 14."
    // Composed from the key, never stored, so it can never be a stale quotation of older copy.
    //
    // #1501: and framed by WHICH night of the run is blocked, because under a date-group header the old
    // sentence read as a claim about that header's date even when the clash was a week later.
    var conflictNote: String? {
        guard let day = conflictKey.flatMap({ BlockedCalendar.Day(key: $0) }) else { return nil }
        return day.reason(scope: conflictScope ?? .thisNight)
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
        restoreConflictClearance(nil)
    }

    // #1583: put back whatever clearance was on this show BEFORE an action changed it, which since Keep
    // became the acceptance is not always nil. A show Dan waved through by hand, then dismissed, then kept
    // again holds an older acceptance that undoing the keep must not silently discard.
    //
    // Written as the general form with `restoreConflict` calling it, rather than as a second rule beside it,
    // so `conflictOpen` still has ONE definition of what it means (a key exists and differs from the cleared
    // one) rather than one per writer. Safe against a background writer too: if the scout has changed the
    // clash since, the restored key no longer matches it and the show blocks, which is the honest direction.
    func restoreConflictClearance(_ key: String?) {
        conflictClearedKey = key
        conflictOpen = conflictKey != nil && conflictKey != key
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
    // #16: the ONE place a show is recorded as leaving the queue, so the four paths that dismiss one
    // (Dan's own cut through ProspectMutations.setStatus, WentByRetirement, ExcludedTownRetirement and
    // OrgDoNotContact) all date it the same way instead of each remembering to.
    //
    // The date is kept if one is already set: re-labelling WHY a dismissed show was cut is not a second
    // exit, and re-stamping would date the drop-off to whenever Dan last tidied up the reason.
    func markDismissed(reason: DismissReason?, at now: Date = Date()) {
        status = .dismissed
        dismissReasonRaw = reason?.rawValue
        dismissedAt = dismissedAt ?? now
    }

    // The exact reverse, for Archive's restore (#28) and the blocked-town Undo (#1238). A show back in
    // the queue has no exit date; leaving one behind would count a live show as a drop-off.
    func clearDismissal(to newStatus: ReviewStatus = .new) {
        status = newStatus
        dismissReasonRaw = nil
        dismissedAt = nil
    }

    // #4: freeze the ranking features as they stood for this pitch. Called from the send path's existing
    // write-once block, beside priorRelationshipAtSend; guarded here as well so a second recipient's send
    // cannot re-stamp the snapshot from a row a later scout has since re-scored.
    func freezeFeaturesAtSend() {
        guard fitScoreAtSend == nil else { return }
        fitScoreAtSend = fitScore
        tierAtSend = tier
        profileAtSend = profile
        coverageAtSend = coverage
        disciplineAtSend = discipline
        productionAtSend = production
    }

    // #1630: the exact inverse of the write-once send snapshot above (the two freezes plus
    // priorRelationshipAtSend), for unwinding a hand-recorded form outreach that never happened. It
    // lives HERE, beside the freezes, rather than in the undo path, because the recurring defect is
    // reversing N minus 1 of N fields (L38): a frozen feature added above and forgotten below would
    // leave a show carrying the ranking snapshot of a pitch that does not exist. Only ever called when
    // the form record is the show's sole outreach, so there is no genuine send whose history it erases.
    func unfreezeSendSnapshot() {
        sentAt = nil
        priorRelationshipAtSend = nil
        fitScoreAtSend = nil
        tierAtSend = nil
        profileAtSend = nil
        coverageAtSend = nil
        disciplineAtSend = nil
        productionAtSend = nil
        sentSubject = nil
        sentBody = nil
        experimentOpenerEdited = false
    }

    func freezeSentCopy(subject: String, body: String) {
        guard sentBody == nil else { return }
        sentSubject = subject
        sentBody = body
        // #5 Phase 3: freeze whether Dan materially rewrote the ASSIGNED opener, so a rewritten arm is
        // excluded from the A/B tally (Phase 4) while staying visible. Judge the SHARED body's opener
        // (the text the assigned arm shaped), NEVER the passed `body` (which for a performer is a
        // different second-person override Dan cannot edit). Only meaningful under an experiment; a
        // non-experiment send leaves it false. Frozen inside the same once-only guard as the sent copy,
        // so it is stable against later draft edits and idempotent under the per-recipient fan-out.
        if assignedArm != nil {
            experimentOpenerEdited = Prospect.experimentOpenerWasEdited(
                originalDraftBody: originalDraftBody, draftBody: draftBody)
        }
    }

    // #5 Phase 3: did Dan materially change the ASSIGNED opener? Compare the opener SENTENCE of the AI's
    // original shared body against the current shared body. `originalDraftBody` is the AI's produced body,
    // snapshotted by applyEdit only on Dan's first substantive edit; nil means he never edited, so the
    // opener is unchanged. Pure (never in a view, #863) so the send path stays testable.
    static func experimentOpenerWasEdited(originalDraftBody: String?, draftBody: String?) -> Bool {
        // No snapshot means Dan never substantively edited, so the arm's opener is exactly as produced.
        guard let original = originalDraftBody else { return false }
        return RecentOpenersBuilder.opener(from: original) != RecentOpenersBuilder.opener(from: draftBody ?? "")
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
    //
    // #1419: returns whether it actually changed anything, so a caller can tell a real dismissal from
    // a no-op instead of saving and carrying on either way. Not reachable from the queue (the flag
    // renders only while the correction is live), but the write that had nothing to write was real,
    // and an undo stack built on a Void return (#1413) would reverse a no-op into a performer-match
    // correction that never existed.
    @discardableResult
    func dismissPerformerMatch(now: Date = Date()) -> Bool {
        guard relationshipCorrectedByPerformerMatch else { return false }
        if let relationship = performerMatchPreviousRelationship { priorRelationship = relationship }
        // #1648 Phase A3 (Dan's sign-off): RECOMPUTE from the row rather than restoring the snapshotted
        // integers. The snapshot describes the row as it stood when the match was applied, so putting it
        // back also throws away anything that legitimately changed the score since (a genre correction,
        // and from #1648 onward a contact check). Accepted consequence: the score after a dismiss may
        // differ from the number the row held before the match, when something else changed in between.
        let refit = ClassificationOverride.rescored(self, now: now)
        fitScore = refit.score
        tier = refit.tier.rawValue
        matchedClientName = performerMatchPreviousMatchedClientName
        downbeatClientId = performerMatchPreviousDownbeatClientId
        relationshipCorrectedByPerformerMatch = false
        performerMatchDismissed = true
        return true
    }

    // Dan says this match is RIGHT (#752, his call: an explicit confirmation, never merely having
    // laid eyes on the prospect). Only this unlocks the warm drafting tone, so an email can sound
    // like it is going to a returning client only because Dan actively said the match was correct.
    // Changes nothing about the score, which the correction already applied.
    //
    // #1419: like dismissPerformerMatch, reports whether it changed anything. Needs the second check as
    // well as the lock: on an already-confirmed match the lock is still held, so that guard passes while
    // both fields already hold exactly what this would set.
    @discardableResult
    func confirmPerformerMatch() -> Bool {
        let alreadyConfirmed = performerMatchReviewed && !performerMatchDismissed
        guard relationshipCorrectedByPerformerMatch, !alreadyConfirmed else { return false }
        performerMatchReviewed = true
        performerMatchDismissed = false
        return true
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
    //
    // #1630 widens what counts as proof without weakening how much is demanded: a pitch Dan submitted
    // through the act's own form and confirmed by hand never touches Gmail, so it can never carry a
    // message id, and it is still a real pitch. His own assertion is a different KIND of evidence, not
    // the absence of any. What it is NOT is equally strong, which is why `permitsAutoBook` below reads
    // the Gmail half on its own.
    var wasProvablyContacted: Bool { gmailMessageId != nil || hasRecordedFormOutreach }

    // #1630: any contact on this show that Dan pitched through its form and confirmed himself.
    var hasRecordedFormOutreach: Bool { recipients.contains { $0.formOutreachRecordedAt != nil } }

    // The content key two results files agree on for "the same performance". Each
    // part is CANONICALIZED so a scraped name and the same name fetched/decoded
    // elsewhere produce one key (the silent-mismatch root): HTML entities decoded,
    // unicode normalized (NFC), exotic whitespace folded, lowercased, trimmed.
    // #1064: the venue is normalized through VenueNormalization BEFORE canonicalize, so two spellings of
    // one physical venue (a bare name versus the same name with its street address appended, a comma
    // before a state code, a street-suffix abbreviation, slash spacing) collapse to ONE key instead of
    // inserting a second prospect row for the same show. canonicalize still lowercases, folds unicode
    // whitespace, and decodes HTML entities on top. Existing stored rows carry their OLD, unfolded keys
    // until NaturalKeyVenueMigration re-keys them at launch.
    // #1590: the TITLE is now folded too, through TitleNormalization, so a source that respells one
    // show's title (an accent, an em dash for a hyphen, an ellipsis character for three dots, brackets
    // for an exclamation mark, a stray comma) stops minting a second row for the same night. The fold
    // runs AFTER canonicalize, never before: canonicalize is what decodes "&amp;", and stripping
    // punctuation first would leave "amp" behind and split the rows #25 taught this key to join.
    static func makeNaturalKey(groupName: String, performanceDate: String?, venue: String?) -> String {
        let normalizedVenue = venue.map(VenueNormalization.normalizeForKey)
        let foldedTitle = TitleNormalization.normalizeForKey(canonicalize(groupName))
        return [foldedTitle, canonicalize(performanceDate ?? ""), canonicalize(normalizedVenue ?? "")]
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
