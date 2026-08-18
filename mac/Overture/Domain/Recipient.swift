import Foundation
import SwiftData

// Where a recipient came from. `act` = a single-act waterfall result; `performer` = a named
// individual performer on a self-produced show (#587, #366 Phase 2), mutually exclusive with `act`
// per performance (never both used at once); `presenter` = a real presenting org (never the host
// venue); `manual` = an address Dan typed in at approval.
enum RecipientProvenance: String, Codable, CaseIterable, Sendable {
    case act, performer, presenter, manual

    // #885: the codebase's convention is a `.label` on the enum (ConversationState, ArchiveStatus,
    // PerformanceStatus and DismissReason all have one). This one was a switch inside a view body.
    var label: String {
        switch self {
        case .act: return "act"
        case .performer: return "performer"
        case .presenter: return "presenter"
        case .manual: return "added"
        }
    }
}

// A recipient's place in sending. Distinct from a performance's review status (ReviewStatus);
// "suppressed" is an unsent send cancelled because the performance froze (any-yes rule).
// "sending" is claimed synchronously right before the network call (#475/#476): it closes the
// double-send race (a second call sees anything but .pending and backs off) and, persisted before
// the await, survives a crash so an interrupted send is never silently re-queued as still-pending.
enum SendState: String, Codable, CaseIterable, Sendable {
    case pending, sending, sent, suppressed
}

// Why a recipient carries sendState == .suppressed (#542): the original booking-freeze only ever
// meant "the show got booked elsewhere," but the same freeze now also fires on a manual decline or
// closing note, so the label shown for a suppressed contact needs to say which actually happened.
// Only meaningful while sendState == .suppressed.
// #399: a third reason, distinct from an actual outcome. removedByDan means Dan hand-removed an
// already-sent contact without recording a decline (reply/decline stats stay honest); the other
// two cases both reflect a real event (the show booked elsewhere, or this contact declined).
// #2151: a fourth, and the only one that is not about STOPPING something. joinedFromReply means this
// address is on the show because somebody wrote from it, not because Overture ever pitched it. It is
// suppressed for the opposite reason to the others: not because pursuit ended, but because pursuit never
// applied. A cold pitch to the person already mid-conversation is the failure this prevents, and pending
// would not prevent it, since resumePausedRecipients deliberately makes the show's other contacts
// sendable again the moment Dan triages the reply.
enum RecipientSuppressionReason: String, Codable, CaseIterable, Sendable {
    case bookedElsewhere, declined, removedByDan, joinedFromReply
}

// A recipient's terminal commercial outcome (#389 derived-outcome model). The active states
// (pending / awaiting / in conversation) are inferred from sendState + replied + bounced; this
// captures only the resolutions that aren't otherwise knowable. `booked` is the attribution of the
// performance's single booking to the contact who landed it, never a second booking. Phase 5 reads
// this to derive the performance status.
enum RecipientResolution: String, Codable, CaseIterable, Sendable {
    case booked
    case declinedSoft = "declined_soft"  // a "no" with the door left open
    case declinedHard = "declined_hard"  // not interested
    // #1840: DAN stopped working this event. Its own case, not a decline, because the other three all
    // attribute the outcome to the CONTACT and here nobody declined anything. Reusing `declinedSoft`
    // would have made every show he walked away from permanently indistinguishable from one where
    // somebody said no, inside the reporting whose whole job is telling him which pitches work.
    //
    // It closes the contact exactly as a decline does (the asking stops, the show reads closed), and it
    // is the ONE closed state that still raises a post-event closing note, because that note serves the
    // NEXT event. See ConversationReminder.
    case stoodDown = "stood_down"
    // #2112: Dan closed this out because nobody ever answered. Its own case, and NOT `Outcome.noResponse`,
    // which is the DEFAULT every sent contact carries and means "nothing has happened yet". Writing the
    // affirmative "they never answered, I am closing this" into the same field as "still waiting to hear"
    // would make the two the same record forever, and the difference can only be captured at the moment
    // he closes it out.
    //
    // Its raw value and its wording match `InquiryLostReason.neverHeardBack`, because the two halves of
    // the funnel are answering the same question and a second vocabulary for it is how a report ends up
    // unable to add them together.
    //
    // A silence is not a refusal, so it closes the door as gently as `declinedSoft` does: the org is not
    // recorded as having turned Dan down, and nothing may rank them lower for it.
    case neverHeardBack = "never_heard_back"
}

// One party emailed for a performance: an act contact, a presenter, or a manual add. A performance
// holds one or more of these as its own SwiftData rows (#409, promoted from a JSON blob so editing
// one recipient can't overwrite another's state and the row identity survives a form-only contact
// gaining an email). Each carries its own send + engagement state so reply detection, follow-ups, and
// reminders are per-recipient, while booking and the one draft stay on the performance.
@Model
final class Recipient {
    // Identity + contact. `id` is the canonicalized email when there is one, otherwise the contact
    // form URL (a form-only act, #368), so the SAME recipient is kept when Dan fills in an email
    // later. `email` is nil for a form-only contact until Dan adds one. NOTE: `id` is deliberately
    // NOT @Attribute(.unique): the same act emailed for two performances shares an id, and a unique
    // constraint would merge those rows across prospects.
    var id: String = ""
    var email: String?
    var name: String?
    var role: String?
    var provenanceRaw: String = RecipientProvenance.manual.rawValue
    var contactMethodRaw: String?
    var contactConfidenceRaw: String?
    var contactFormURL: String?
    // #363: the page this contact was actually read from, so the confidence badge can link Dan
    // through to verify it himself. Only ever meaningful when contactConfidence == .high;
    // RecipientSnapshot.contactSourceLinkURL is the single place that gate is enforced for
    // display, so a stale value left over from a since-downgraded confidence is inert rather
    // than shown as a false citation. Distinct from contactFormURL, which stays the form_or_dm
    // contact's own submission link.
    var contactSourceURL: String?
    // v4 (#640, #634 Phase B): only ever meaningful when provenance == .performer, a direct,
    // second-person draft for THIS recipient, preferred over the shared Prospect.draftBody at send.
    // PrepImporter clears this whenever a re-ingested contact's provenance is no longer .performer.
    var overrideBody: String?

    // #789: the EXACT text Dan explicitly confirmed is fine to send despite a blocking lint finding.
    // A copy of the text rather than a bare boolean, so a later edit to DIFFERENT text silently
    // invalidates the override with no migration bookkeeping (isLintOverridden below); the same
    // shape as Prospect.draftSalutationReviewOverriddenBody (#718). Per RECIPIENT, not per prospect,
    // because the text that reaches each one can differ (see effectiveBody).
    var lintOverriddenBody: String?

    // #388: a heuristic guess (VenueContactGuard) that this contact's address belongs to the host
    // venue, not the act/presenter, set on ingest and blocking sendability until Dan dismisses it
    // (a weaker signal than the runbook's own STRICT venue-disqualify rule for the AI, so it's
    // reversible rather than absolute).
    var looksLikeVenue: Bool = false
    var looksLikeVenueDismissed: Bool = false

    // #722: same shape as looksLikeVenue above, for the runbook's separate press/media-disqualify
    // rule (#635); a heuristic guess (PressContactGuard), dismissible for the same reason.
    var looksLikePressContact: Bool = false
    var looksLikePressContactDismissed: Bool = false

    // #726: a heuristic guess (DuplicateContactGuard) that this contact is already being pitched
    // on another still-open prospect for what looks like the same real-world performance, a
    // safety net for #369's grouping. Dismissible for the same reason as the two flags above.
    var looksLikeDuplicateContact: Bool = false
    var looksLikeDuplicateContactDismissed: Bool = false

    // #2624: the fifth guard, recorded the way the three above are. UnaccountedAddressGuard catches a
    // contact naming one person and holding an address in a different person's name with no page cited:
    // the greeting is composed from `name`, so such a row would greet the artist and be delivered to a
    // stranger at an agency (L75). Dismissible for the same reason the venue and press guesses are: Dan
    // can look at an address and judge whether it really reaches the person named.
    var looksLikeAnotherPersons: Bool = false
    var looksLikeAnotherPersonsDismissed: Bool = false

    var isLooksLikeAnotherPersons: Bool { looksLikeAnotherPersons && !looksLikeAnotherPersonsDismissed }

    // #1866: the fourth guard on a contact, recorded the way the three above are. ContactConfidenceGuard
    // (#1856) rewrites a `high` find down to `low` when it names no page it was read off, and used to store
    // nothing saying it had, so the row read exactly like one the run itself judged weak. Two different
    // things produced one badge, and Dan could tell neither which it was nor say the guard was wrong.
    //
    // Set by PrepImporter, on the pair each ingest LEAVES BEHIND, and re-derived every time rather than
    // latched: a later run that finally names the page clears it along with the downgrade it explains.
    //
    // The dismissal is his answer about THIS address, for the same reason the three above are dismissible:
    // he can look at an address and judge whether it is really the act's, and a missing citation is a fact
    // about the run's bookkeeping rather than about the address. Once he says so, the card stops calling it
    // unverified (QueueItem.isUnverified).
    //
    // FALSE on every row written before this shipped, which means "not known to have been held down", not
    // "the guard did not fire". Nothing asserts anything on a false, so an old row keeps exactly today's
    // wording; the next ingest over that show restores the truth, because the run still reports `high` and
    // still cites nothing.
    var heldDownToUnverified: Bool = false
    var heldDownToUnverifiedDismissed: Bool = false

    // Whether the hold is IN FORCE, which is not the same as whether it was ever applied. One definition,
    // so the card, the review panel and the merge cannot each spell the pair differently.
    var isHeldDownToUnverified: Bool { heldDownToUnverified && !heldDownToUnverifiedDismissed }

    // #2912: the run said the ONLY thing tying this route to the person named here is the NAME. The live
    // case is a social profile found by searching the platform (#2892): the account carries the right
    // name and its bio and recent posts say nothing about this show, so who is on the end of it was never
    // established. Dan asked to SEE those rather than have them withheld, and to be told they are guesses.
    //
    // Set by PrepImporter from the contact's own `nameMatchOnly`, and re-derived on EVERY ingest rather
    // than latched, exactly like `heldDownToUnverified` above: a later run that emits the same profile
    // without the declaration is making the verification claim a bare `form_or_dm` carries, so the mark
    // clears with the doubt it describes.
    //
    // FALSE on every row written before this shipped, which means "nobody has said it is a guess", not
    // "confirmed". Nothing asserts anything on a false, so an old row keeps exactly today's wording.
    //
    // What it deliberately does NOT do is make the show reachable. `Prospect.socialRouteURLs` excludes a
    // profile carrying this, so the stored verdict, the fit score and the organisation ledger see what
    // they saw when such a profile was refused outright (#2147, L75): the app still never CLAIMS a route
    // it cannot tie to anybody. The card shows the handle and says what could not be confirmed.
    var nameMatchOnly: Bool = false

    // #2622: WHO this contact is to the show (primary, secondary, tertiary), as the check judged it from
    // the page it read. Raw, like the confidence and method beside it, so a value this build does not know
    // decodes as nil rather than being invented here. nil means nobody has said, which every contact
    // stored before this shipped is, and which is deliberately not the same thing as a show no check has
    // looked at (that is `Prospect.reachabilityResult`).
    var contactTierRaw: String?

    var contactTier: ContactTier? {
        get { contactTierRaw.flatMap(ContactTier.init(rawValue:)) }
        set { contactTierRaw = newValue?.rawValue }
    }

    // #1630: HOW this contact was actually reached. nil means email, the only channel that existed
    // before this, so every stored record migrates as what it is. `contact_form` means Dan submitted
    // the act's own form by hand and told Overture he did: real outreach that Gmail never touched, so
    // it has no thread to watch and no message id. Raw so a future channel decodes here without a
    // migration.
    var outreachChannelRaw: String?
    // When Dan confirmed he sent it. This is the form channel's counterpart to `gmailMessageId`: the
    // evidence that the outreach actually happened, as opposed to a bare `sentAt` that proves nothing
    // (#963). nil on every email send.
    var formOutreachRecordedAt: Date?
    // The form Dan actually submitted, frozen at that moment. NOT read back off `contactFormURL`,
    // which is scout-owned and rewritten by every re-ingest (PrepImporter), so the record would
    // otherwise end up naming a page he never used (L37).
    var formOutreachURL: String?
    // Where the show sat before the record, so undoing it restores exactly that rather than guessing an
    // inverse (the #752 snapshot shape). A form-only show is normally `.drafted`, but it can be recorded
    // from other states and guessing would quietly move it somewhere Dan did not leave it.
    var formOutreachPriorStatusRaw: String?
    // When Dan copied the pitch and opened the form. PERSISTED, not view state: he leaves for the
    // browser and may not come back this session, and a confirm step that evaporates leaves the row
    // reading untouched again, which is the whole defect this issue exists to fix, only smaller. It also
    // makes the in-between state honest, "you opened their form and have not said whether you sent it",
    // instead of collapsing into either end.
    var formOutreachStartedAt: Date?
    // #2711: when Dan told Overture a reply arrived on a channel it cannot watch (a DM answered inside
    // Instagram, a form reply that never reached Gmail). Kept as its own stamp rather than folded into
    // `repliedAt`, so a hand-marked reply is never mistaken for one Overture read: it is what the reply
    // panel reads to say why there are no words to show, and what the undo reads to know there is a mark
    // of its own to take back rather than a detection to argue with.
    var replyMarkedByHandAt: Date?
    // Whether that mark cleared a stand-down. `reopenOnReply` nulls a `.stoodDown` resolution and nothing
    // else remembers it, so without this the undo could only guess at an inverse (L5).
    var replyMarkClearedStandDown: Bool = false
    // #2713: when the mailbox search last READ for a reply to this pitch, set whether or not it found
    // one. Written by `GmailReplySearch` only on a tick that completed, never on one that failed, so it
    // is a record of the mailbox having been read rather than of the attempt.
    //
    // Its own fact rather than a corner of the shared high-water mark, and read by
    // `ReplySearchScope.windowStart`, which is what makes the pair work: the mark says how far the
    // MAILBOX has been read, this says whether THIS contact was in scope while that happened. A pitch
    // recorded after the mark was set has never been read for, so it needs its window back to the pitch
    // rather than only the new mail, and without this field the two are indistinguishable and its reply
    // is skipped for ever.
    //
    // Its second reader is the row (#2718), which has to tell "read for, and nothing arrived" from
    // "never read for" rather than showing one sentence for both (L98).
    var replyCandidateSearchedAt: Date?
    // #2715: when Dan LINKED a Gmail conversation to this pitch by hand.
    //
    // Its own stamp rather than being inferred from `replyWatchConversationIsAttached`, because that
    // predicate is deliberately self-healing (it stops being true the moment Overture's own reply lands
    // on the thread), and the fact that a person made this link by hand is permanent. Its reader is
    // `ReplyPanel.linkedByHandLine`, so the row does not read as though Overture emailed them (L46).
    var conversationAttachedAt: Date?
    // #2715: the Subject the linked thread actually carries.
    //
    // Gmail requires the Subject to match the thread's when a message is sent with its threadId, and
    // `SendService.replySubject` otherwise falls back to `prospect.draftSubject`, which on an attached
    // pitch is the subject of an email that was never sent and that this thread has never carried. The
    // likely outcomes are an opaque 400 or a message Gmail groups server side while every
    // standards-based client files it separately. Its reader is `SendService.replySubject`.
    var attachedThreadSubject: String?
    // #2715: what the attach found here before detection overwrote it, so the compensating detach
    // (#2719) can put it back. `reopenOnReply` clears a `.stoodDown` resolution and nulls the three
    // draft-baseline fields, and nothing else in the app remembers any of them, so without capturing
    // them at the moment of the write the undo cannot exist at all (L5). Read by #2719.
    var attachPriorResolutionRaw: String?
    var attachPriorOriginalReplyDraftBody: String?
    var attachPriorReplyDraftWrittenByDan: Bool = false
    var attachPriorReplyDraftEditedByDan: Bool = false
    // #2715: which of the show's other contacts THIS attach froze. `pausePendingForReply` freezes every
    // still-pending contact with an address, so a detach that simply cleared every pause it found would
    // unfreeze rows that were paused for some other reason and were never this attach's to touch. Read
    // by #2719.
    var attachPausedRecipientIds: [String]?
    // #2719: whether the attach WROTE the address now on this contact, so a detach takes back only what
    // it put there. An address that was already on the contact was never the attach's to remove, and nil
    // afterwards is indistinguishable from nil before without recording the fact at the time.
    var attachWroteAddress: Bool = false
    // #2719: that a conversation has EVER been attached here, which the detach deliberately does not
    // clear.
    //
    // It is what `undoFormOutreach` refuses on, and it has to be permanent rather than "while one is
    // attached". `undoFormOutreach` sets `sendState = .pending`, `sentAt = nil` and unfreezes the send
    // snapshot while clearing none of the reply state, so with a saved address it would leave a pending
    // recipient carrying a stranger's address, sendable the moment the pause clears, and Overture would
    // queue the cold pitch to them. Refusing only while a conversation is attached would leave that door
    // open behind a detach.
    var conversationEverAttachedAt: Date?
    // #2718: the conversation Overture is ASKING Dan about, stored in full because a SwiftUI row cannot
    // make a Gmail call and the question has to be answerable without one.
    //
    // Held from the FIRST candidate proposed until he answers it, rather than replaced by whatever
    // scores highest on the latest tick. A question that changes under him between reading it and
    // pressing Yes is the defect L64 names: what he approves has to be exactly what happens.
    //
    // Written by `ProposedConversation.propose`, read by `ProposedConversation.stored` and, through it,
    // by the row and by `DueWork.counts`.
    var replyProposedMessageId: String?
    var replyProposedThreadId: String?
    var replyProposedFromAddress: String?
    var replyProposedFromName: String?
    var replyProposedSubject: String?
    var replyProposedSentAt: Date?
    var replyProposedScore: Int = 0
    var replyProposedAt: Date?
    // #2718: the conversations Dan has said are NOT them.
    //
    // A SET, and keyed on the CONVERSATION rather than on a message. `dismissedReplyId` above is the
    // precedent and is deliberately spelled the same way, but it is a single slot, which is sufficient
    // there because an emailed contact has exactly one watched thread. Here the mailbox search returns
    // many candidates over time, so a slot would let him decline A, be offered B, decline B, and meet A
    // again on the next tick (L131). Keying on the message id instead would re-propose the same
    // conversation the moment that sender writes again, which on a live conversation is what happens
    // next (L92).
    var dismissedConversationIds: [String]?

    // Per-recipient send + engagement.
    var sendStateRaw: String = SendState.pending.rawValue
    // Why sendState == .suppressed (#542). Only meaningful while sendState == .suppressed; nil for
    // every other state and for any suppression that predates this field.
    var suppressionReasonRaw: String?
    var sentAt: Date?
    var gmailThreadId: String?
    var gmailMessageId: String?
    // #2648: the `References` header carried by the LAST message Overture sent on this contact's
    // conversation, which is the ancestry the NEXT one has to extend. Kept beside `gmailMessageId` and
    // written in the same step, because the two are one fact: the chain is only meaningful as the
    // ancestry OF that message, and updating one without the other would emit a chain that skips a
    // generation. Nil until a reply has been sent, which is the first message with any ancestry at all.
    var gmailReferences: String?
    // #483: set when a send succeeded but Gmail's response had no parseable threadId, so this
    // recipient's replies can never be auto-detected until Dan checks Gmail directly.
    var replyTrackingDegraded: Bool = false
    // #2647: set when a send succeeded but the real Message-ID Gmail stamped on it could not be read
    // back, so `gmailMessageId` holds no id for that message and the NEXT message Overture sends on this
    // conversation cannot reference it. Its own field beside replyTrackingDegraded rather than folded
    // into it: replies can still be watched (the threadId is fine), and only the outbound threading is
    // broken, so one field for both would say the wrong thing about whichever check actually failed (L53).
    var threadingDegraded: Bool = false
    var sendError: String?
    // When the current .sending claim was made (#475/#476); cleared when it resolves to .sent or
    // reverts to .pending. Only meaningful while sendState == .sending.
    var sendClaimedAt: Date?
    // #468 (SUP-005): the same claim-before-await pattern as sendClaimedAt, for a reply send.
    // Kept on its OWN field (not shared with nudgeSendClaimedAt below) because a replied
    // recipient can legitimately be due for a conversation nudge at the same time (two different
    // open surfaces), so sharing would cause spurious refusals rather than catching a real race.
    var replySendClaimedAt: Date?
    // #468 (SUP-005): shared by sendFollowUp and sendConversationNudge. Safe to share: a
    // recipient eligible for a follow-up (isAwaitingFollowUp, which requires outcomeSourceRaw ==
    // nil) and one eligible for a conversation nudge (which requires a conversationState, and
    // setConversationState always pairs that with outcomeSourceRaw = .manual) are mutually
    // exclusive by construction, so a recipient can never legitimately want both at once.
    var nudgeSendClaimedAt: Date?
    var followUpCount: Int = 0
    // #1740: when Dan stood this contact's outreach down ("I'm not going to action this"), and when he
    // last pushed its nudge out a gap instead. Both default nil so existing records migrate cleanly, and
    // both are read through `isOutreachStoodDown` / `FollowUp.isAwaitingNudge` rather than directly.
    var outreachStoodDownAt: Date? = nil
    var nudgeRemindedAt: Date? = nil
    // #1740: the closing note stood down WITHOUT being sent. Its own fact, not the pitch stand-down
    // above, because the two mean different things: the pitch stand-down is "I am not working this event",
    // and the closing note serves the next one, so it survives that and is declined separately if at all.
    // Dan, 2026-07-30: "not sent but also done."
    var closingNoteStoodDownAt: Date? = nil
    var lastFollowUpAt: Date?
    var replied: Bool = false
    // When Overture NOTICED a reply. Not when it was written: the watcher stamps this as it runs, so a
    // reply that lands while the app is shut carries the next launch. `inboundReplySentAt` is the real
    // thing and is preferred wherever the date is shown or grouped (#2113).
    var repliedAt: Date?
    // #2113: WHO wrote back, captured from the From header Gmail already returns. Both are needed: the
    // address identifies the mailbox, the display name is what a person is actually called. Nil on a row
    // that replied before this was recorded, until the backfill reaches it.
    var replyFromAddress: String?
    var replyFromName: String?
    // #2113: when they actually SENT it, off the same message's internalDate.
    var inboundReplySentAt: Date?
    // #2653: the Message-ID of the message being answered. Overture read the thread to detect the reply
    // and extract its text and then DISCARDED this, so the answer threaded off Overture's own last
    // outgoing message instead, making the contact's reply a sibling of Dan's answer rather than its
    // parent. Read through `ReplyThreading`, never directly, so both send paths answer the same way.
    var inboundReplyMessageId: String?
    // #2149: when the repair pass last TRIED to fill in the message text, whether or not it found any.
    // Without it a reply with no decodable body stays in the gap and its thread is refetched forever.
    var replyTextCheckedAt: Date?

    // #2170: when Dan ANSWERED the reply, whichever way he sent it. Its own fact rather than clearing
    // `replied`, because the reply genuinely happened and replyArrivedAt still dates the row.
    var replyHandledAt: Date?
    var lastReplyId: String?
    var dismissedReplyId: String?
    var lastReplyText: String?
    var bounced: Bool = false
    // The Gmail message id of the auto-detected hard bounce that set `bounced` (#398), and the
    // one Dan said was wrong, mirroring lastReplyId/dismissedReplyId so a dismissed false
    // positive never re-flags while a genuinely new bounce still does.
    var lastBounceId: String?
    var dismissedBounceId: String?
    // #656: when the newest Gmail delay notice was first seen on this thread, paired with its
    // message id so a fresh delay notice restarts the fade window without re-triggering on the
    // same one repeatedly. Purely informational: never gates isSilent or follow-up eligibility,
    // and BounceService leaves both alone once bounced/replied (see the isSilent guard above).
    var delayNoticeAt: Date? = nil
    var lastDelayMessageId: String? = nil
    // Per-recipient conversation state (#650, Phase 1 of milestone #19), mirroring the four fields
    // already on Prospect exactly. The per-recipient conversation surface that sets these is a later
    // phase; for now this is a pure domain addition plus the migration in Task 3.
    // #2397: the three state fields are gone with the state. `conversationRemindedAt` stays, and is NOT
    // simply the fourth of a set: it is the anchor the post-event closing note re-stamps on send, which is
    // what stops a sent note coming due again the next morning.
    var conversationRemindedAt: Date? = nil
    var resolutionRaw: String?
    // Whether Dan hand-set this recipient's state (#418 A1b), mirroring Prospect.outcomeSourceRaw:
    // nil = no manual mark, OutcomeSource.manual = Dan judged this contact by hand. Per-recipient
    // reply detection short-circuits on this so one contact's manual mark can't blind the others.
    var outcomeSourceRaw: String?
    // Reply-triage auto-pause (#418 A4): a reply on the show pauses this still-unsent recipient
    // pending Dan's triage. Its OWN flag, distinct from sendState .suppressed (the booking-freeze).
    var pausedByReply: Bool = false
    // AI inbound-reply drafter outputs (#420 C0). `intentHint` is a NON-BINDING ReplyIntent hint shown
    // beside the manual controls; it never auto-sets a RecipientResolution (#420 C4). `replyDraft*` is
    // the drafted response Dan reviews; `replyDraftRequestedAt` stamps the request so the conversation
    // view can show progress and a timeout can surface a dead run as needs-attention (#420 C6).
    var replyDraftSubject: String?
    var replyDraftBody: String?
    var replyDraftRequestedAt: Date?
    // #2063: who the reply Overture is answering was itself addressed to (its sender plus everyone else it
    // named, minus Dan), captured with the reply text. Dan's answer goes to exactly these people, so a
    // reply he received privately is not answered in front of everybody he originally emailed.
    //
    // nil means never captured, which is every reply that arrived before this shipped, and is deliberately
    // distinguishable from an empty audience: the send falls back to the replier alone on nil rather than
    // to the original group, because under-sending is something Dan can correct and over-sending is not.
    var replyAudience: [String]?
    var intentHint: String?
    // Whether Dan hand-edited THIS reply draft (#459), mirroring Prospect.draftEditedByDan for the cold
    // draft: once set, the deterministic DraftCheck warnings stop nagging on text he already owns. A
    // fresh AI draft clears it again so warnings reappear on text he hasn't touched.
    var replyDraftEditedByDan: Bool = false
    // #846: which model wrote this reply, mirroring Prospect.draftModel for the cold draft. The runner
    // has stamped it into the results file since #804; the app decoded it nowhere and threw it away, so
    // the reply half of that record never existed. A reply goes to somebody who already wrote back to
    // Dan, which is a warmer lead than any cold pitch (#874), and it is exactly where he would want to
    // check what wrote the words. Defaulted, so replies drafted before this migrate cleanly carrying no
    // trace.
    var replyDraftModel: String? = nil

    // The reply-draft voice-learning pair (#463), mirroring Prospect.originalDraft*/sentBody for the cold
    // draft. originalReplyDraftBody is the AI's reply before Dan's first substantive edit; sentReplyBody
    // is the exact text he committed (sent via Overture or copied out to Gmail), frozen at commit so a
    // later re-draft can't rewrite the lesson. Reply subjects are auto ("Re: …"), never Dan-edited, so
    // only the body is captured.
    var originalReplyDraftBody: String?
    var sentReplyBody: String?
    var replySentAt: Date?

    // The performance this recipient belongs to (inverse of Prospect.recipients).
    var prospect: Prospect?

    init(id: String, email: String?, name: String? = nil, role: String? = nil,
         provenance: RecipientProvenance,
         contactMethodRaw: String? = nil, contactConfidenceRaw: String? = nil,
         contactFormURL: String? = nil, contactSourceURL: String? = nil) {
        self.id = id
        self.email = email
        self.name = name
        self.role = role
        self.provenanceRaw = provenance.rawValue
        self.contactMethodRaw = contactMethodRaw
        self.contactConfidenceRaw = contactConfidenceRaw
        self.contactFormURL = contactFormURL
        self.contactSourceURL = contactSourceURL
    }

    // The stable join + dedupe key: the canonicalized email when present, else the form URL (so a
    // form-only contact survives an email being added later), else nil when there is neither and so
    // nothing to make a recipient from.
    static func makeId(email: String?, formURL: String?) -> String? {
        if let email, !email.isEmpty { return ReplyDetection.email(from: email) }
        if let formURL, !formURL.isEmpty { return "form:" + formURL }
        return nil
    }

    var provenance: RecipientProvenance {
        get { RecipientProvenance(rawValue: provenanceRaw) ?? .manual }
        set { provenanceRaw = newValue.rawValue }
    }

    var sendState: SendState {
        get { SendState(rawValue: sendStateRaw) ?? .pending }
        set { sendStateRaw = newValue.rawValue }
    }

    // Defaults to .bookedElsewhere so a suppression from before this field existed (every one of
    // them was a booking-freeze) still reads correctly rather than as an unrepresentable nil (#542).
    var suppressionReason: RecipientSuppressionReason {
        get { suppressionReasonRaw.flatMap(RecipientSuppressionReason.init) ?? .bookedElsewhere }
        set { suppressionReasonRaw = newValue.rawValue }
    }

    var resolution: RecipientResolution? {
        get { resolutionRaw.flatMap(RecipientResolution.init) }
        set { resolutionRaw = newValue?.rawValue }
    }

    var outcomeSource: OutcomeSource? {
        get { outcomeSourceRaw.flatMap(OutcomeSource.init) }
        set { outcomeSourceRaw = newValue?.rawValue }
    }

    // #654: mirrors Prospect's own contactMethod/contactConfidence wrappers, now the only copy since
    // the lead-level ones were deleted.
    var contactMethod: ContactMethod? {
        get { contactMethodRaw.flatMap(ContactMethod.init) }
        set { contactMethodRaw = newValue?.rawValue }
    }

    var contactConfidence: ContactConfidence? {
        get { contactConfidenceRaw.flatMap(ContactConfidence.init) }
        set { contactConfidenceRaw = newValue?.rawValue }
    }

    // #1630: this contact was provably reached, whichever way it happened. An emailed contact proves it
    // with a Gmail message id against a real address (#331/#378: a bare `sentAt` with neither is a
    // staged or corrupt record that was never actually sent, and that guard is unchanged). A form
    // contact proves it with Dan's own confirmation, which is a different KIND of evidence, not the
    // absence of any. The one place that question is answered, so a surface cannot admit an outreach
    // the next surface refuses.
    var hasProvenOutreach: Bool {
        if formOutreachRecordedAt != nil { return true }
        return gmailMessageId != nil && (email?.isEmpty == false)
    }

    // Sent, no reply, not bounced: the only recipients that receive follow-ups or reminders.
    var isSilent: Bool { sendState == .sent && !replied && !bounced }

    // The contacts the follow-up sequencer may nudge (#418 D): silent AND not hand-resolved. A contact
    // Dan marked Closed/Booked (resolution set) or otherwise judged by hand (outcomeSource == .manual)
    // is still "silent" by the raw definition but must never be nudged again.
    // #1630: and never a form outreach. A nudge is an EMAIL, sent onto the original thread; a form
    // contact has neither an address nor a thread, so the whole sequence is unsendable for it. Offering
    // one would put a button in Follow-ups that can only fail, about a pitch that is perfectly fine. Its
    // own decide clock (ReachedOutQueue) covers it instead.
    // #2716: re-decided, and deliberately unchanged, now that a form pitch can carry an attached
    // conversation and an address learned from it. It asks the CHANNEL, which is history and never flips,
    // and that is the right question here: a nudge is an email onto the conversation Overture itself
    // started, and it anchors on `sentAt`, which for a form pitch is when Dan recorded it by hand and is
    // typically weeks old. Reading the attach as "this is an email contact now" would make the nudge
    // instantly OVERDUE, count it in the Due pill, and send a real cold nudge onto a stranger's
    // conversation. Do not "fix" this to consult the address or the thread.
    var isAwaitingFollowUp: Bool {
        isSilent && resolution == nil && outcomeSource != .manual && outreachChannel == .email
    }

    // #677: this contact replied and nobody has dealt with it yet: replied, no resolution recorded,
    // and it didn't bounce. Was independently recomputed in OmniFocusSync, ReachedOutQueue, and
    // ConversationReminder (plus inline in Prospect.hasUnhandledReply); now the one shared source. A
    // manually hand-set conversation state (#653) is NOT excluded here: only two of the four call
    // sites need that exclusion, so they layer `&& conversationStateSource != .manual` on top.
    // #2170: and Dan has not ANSWERED it. Nothing in the model used to mean that, so the Answer button
    // went on offering itself after it had been pressed and succeeded, and the row said somebody was
    // waiting on him two hours after he had written back (L44, L11).
    //
    // Compared against when their message ARRIVED rather than being a plain flag, so a second reply on
    // the same thread re-opens it. Without that the whole back half of a conversation would be
    // unanswerable from the queue. It is the same shape freezeSentReply already uses to decide whether
    // they have written again since the last capture.
    // #2910, Dan's call: an ending recorded on the SHOW deliberately does NOT come into this. Closing a
    // show out records what happened to the show; it does not mean he wrote back to the person who took
    // the trouble to reply, so it must not answer them on his behalf. #2900 briefly made an ending close
    // the reply here, and that also made a reply arriving AFTER the ending silent, which is the reply
    // most worth hearing. What makes leaving it open safe is that clearing one no longer needs an ending
    // to stand in for it: answering in Overture, answering from his mail client (#2865), ticking the
    // triage task off in OmniFocus (#2899), or standing the contact down all retire it.
    var hasUnhandledReply: Bool {
        guard replied, resolution == nil, !bounced else { return false }
        guard let handled = replyHandledAt else { return true }
        guard let theirs = replyArrivedAt else { return false }
        return theirs > handled
    }

    // #2919: they wrote, Dan answered, and nothing has arrived since. The state #2170 created and no
    // surface ever spoke: once `replyHandledAt` clears the reply, the reached-out row went back to
    // looking exactly like a pitch nobody ever answered, so a live negotiation and total silence rendered
    // identically (L152).
    //
    // Written OVER `hasUnhandledReply` rather than beside it (#2921's rule), so the two can never disagree
    // about whether this conversation has been dealt with. The three facts in front of it are the three
    // that predicate short-circuits on, and they are here because `!hasUnhandledReply` on its own is
    // equally true of a contact that never replied, one that bounced, and one Dan stood down. A line may
    // claim only what its check actually measured (L11).
    var replyIsAnswered: Bool {
        replied && !bounced && resolution == nil && replyHandledAt != nil && !hasUnhandledReply
    }

    // #2113 lives on ReplyWatchableRecipient now (#2118): `replyArrivedAt` is one definition for every
    // watched thread, an inquiry's included, because the two kinds of row share the reached-out queue's
    // date headings and two of them dating a reply differently is how a card ends up under the wrong day.

    // Ready to actually receive the pitch: still pending and has a real address. A form-only contact
    // (#368) is pending but has no email, so it is never auto-sendable until Dan fills one in. The send
    // queue, the manual-send picker, and the "show fully sent?" rollup all read this one predicate.
    // A contact auto-paused by a reply on the same show (#430) is held back until Dan triages, so it
    // drops out of every send path that reads this predicate. #407: a performance whose draft still
    // carries an old, un-strippable inline greeting is blocked ENTIRELY (every recipient, not just a
    // differently-named one) until that clears OR Dan explicitly overrides it (#718,
    // Prospect.isSalutationReviewOverridden); a recipient with no prospect wired (every bare-
    // Recipient unit test in this file) is unaffected, since there is nothing to check. #388: a
    // recipient whose address looks like the host venue (VenueContactGuard, set at ingest) is
    // blocked until Dan dismisses that specific guess as wrong.
    // #789 adds the draft lint: a recipient whose OWN outgoing text carries a blocking finding is
    // held back until Dan either fixes the text or deliberately overrides it, the same way #407's
    // salutation flag blocks above.
    // #1798: an address that EXISTS and is held back by one of the guards, which is a different fact from
    // having no address at all. One definition, because the verdict on the row and the card's own answer
    // were two copies of this rule and both listed two of the three guards; the measured cost was a card
    // reading "No email found" in rust with `office@frigid.nyc` printed underneath it.
    //
    // The three members are exactly the three `isSendablePending` refuses on below, so the two can never
    // drift apart again: anything held there is held here.
    var isHeldByAGuard: Bool {
        email?.isEmpty == false
            && ((looksLikeVenue && !looksLikeVenueDismissed)
                || (looksLikePressContact && !looksLikePressContactDismissed)
                || (looksLikeDuplicateContact && !looksLikeDuplicateContactDismissed)
                || isLooksLikeAnotherPersons)
    }

    // #1798: WHICH kind of hold, so the card's sentence can be true of the row that produced it. Measured
    // on the live store 2026-07-31: the one row in this state was held by the duplicate guard alone, with
    // the venue and press guards both clear, so the wording written for those two would have been a false
    // claim about a real presenter's own office address.
    // #2624 adds the third: an address nobody on the row accounts for. Its own case for the same reason
    // the duplicate has one, that the badge has to be true of the row that produced it: neither "weak
    // contact only" nor "held as a duplicate" describes an address in a stranger's name.
    enum HoldReason: Equatable { case venueOrPress, duplicate, unaccountedAddress }

    var holdReason: HoldReason? {
        guard isHeldByAGuard else { return nil }
        if (looksLikeVenue && !looksLikeVenueDismissed)
            || (looksLikePressContact && !looksLikePressContactDismissed) { return .venueOrPress }
        if looksLikeDuplicateContact && !looksLikeDuplicateContactDismissed { return .duplicate }
        return .unaccountedAddress
    }

    var isSendablePending: Bool {
        sendState == .pending && (email?.isEmpty == false) && !pausedByReply
            // #901: a date conflict Dan has not cleared stops the send, not just the draft. The prep gate
            // alone would miss the case that matters most: the draft already existed, was approved, and
            // THEN he blocked the week or took a booking. Nothing should go out pitching a night he
            // cannot work until he says he can.
            && prospect?.hasUnclearedConflict != true
            // #2052: a written email with no subject line does not go out. Held HERE, and not only on the
            // confirmation sheet, because the sheet showed the gap ("(no subject)") and offered Send
            // beside it anyway: a guard on a screen is not a guard. There is no override, unlike the
            // greeting and lint holds, because those are judgements about words Dan can stand behind
            // and this is a field he has not filled in.
            && prospect?.draftIsMissingSubject != true
            && !(looksLikeVenue && !looksLikeVenueDismissed)
            && !(looksLikePressContact && !looksLikePressContactDismissed)
            && !(looksLikeDuplicateContact && !looksLikeDuplicateContactDismissed)
            // #2624: an address in a name nobody on this row accounts for. Held here, not merely marked,
            // because `low` confidence changed how the card DESCRIBED the find and did nothing to stop
            // the send: the greeting would name the artist and the mail would reach a stranger.
            && !isLooksLikeAnotherPersons
            && !isBlockedByDraftLint
            // #2545: a body that does not greet, or greets one person on an email several people get.
            // Held here rather than only on the draft card for the reason #2052 gives directly above:
            // a guard on a screen is not a guard.
            && !isBlockedByGreeting
    }

    // #789 / #641: the text THIS recipient actually receives. A directly-addressed performer's own
    // second-person draft (#634 Phase C) wins over the shared third-person body; for everyone else
    // it IS the shared body. SendService.deliver reads this to compose the mail, and the lint below
    // reads the same property to judge it, so what is CHECKED can never drift from what is SENT.
    var effectiveBody: String? {
        (provenance == .performer ? overrideBody : nil) ?? prospect?.draftBody
    }

    // #789: the blocking lint findings in that text. Derived live rather than stored at ingest on
    // purpose: it is a pure function of text already on disk, so it can never go stale, it needs no
    // migration, and it covers Dan's own edits and a performer's override body for free.
    var draftLintBlockers: [DraftIssue] {
        guard let body = effectiveBody, !body.isEmpty else { return [] }
        return DraftCheck.blockingFindings(in: body)
    }

    // True only when the current outgoing text is the EXACT text Dan overrode; a mismatch (edited
    // since, or never overridden) means the block still applies.
    var isLintOverridden: Bool {
        lintOverriddenBody != nil && lintOverriddenBody == effectiveBody
    }

    var isBlockedByDraftLint: Bool { !draftLintBlockers.isEmpty && !isLintOverridden }

    // #2545: the body must open with a greeting, because nothing composes one above it any more. Judged
    // on `effectiveBody` for the same reason the lint above is: a performer's own letter is judged by
    // its own words, and what is CHECKED is what is SENT.
    //
    // A missing body is not this guard's business (the send already refuses one), so it answers false
    // rather than claiming a greeting is absent from text that does not exist.
    var draftIsMissingGreeting: Bool {
        guard let body = effectiveBody, !body.isEmpty else { return false }
        return !DraftGreeting.opensWithAGreeting(body)
    }

    // #2545: a greeting that names one person on an email more than one person receives.
    //
    // This is the cost of moving the greeting inside the body: it is written once, at draft time, and
    // can no longer re-address itself when the contact list changes underneath it. A reachability check
    // that fills in a second address next week is exactly how "Hi Emma," ends up in front of Emma and
    // Tom, so the mismatch is detected rather than left to be noticed in a sent email.
    //
    // Only the wrong direction is held. A plain "Hello," to one person is not an error, and on a shared
    // inbox it is the correct opening, with the `Attn:` block above it naming the desk.
    var greetingMisaddressed: Bool {
        guard let prospect else { return false }
        // A performer's own second-person letter (#634) goes to them alone, whatever else is on the
        // show, so a name in it is right by construction.
        if provenance == .performer, overrideBody?.isEmpty == false { return false }
        return prospect.greetingAudienceSize > 1 && DraftGreeting.namesSomeone(effectiveBody)
    }

    // #2579: the greeting names somebody who is clearly not this contact.
    //
    // The one safety property the #2545 move gave up. Before it, the greeting was composed from this very
    // row, so it could not name anyone else; now the drafter writes it and nothing compared the two.
    //
    // A different question from `greetingMisaddressed` above, which is about a named greeting reaching
    // SEVERAL people. This one is about the single-contact case that guard cannot see: one contact, Tom,
    // and a body opening "Hi Emma,".
    //
    // The performer carve-out is deliberately NOT repeated here. A performer's own second-person letter
    // goes to them alone, which makes a name in it right by construction for the audience question, and
    // makes it exactly as wrong as any other if it is the wrong name.
    var greetingNamesSomeoneElse: Bool {
        DraftGreeting.namesSomeoneElse(greeting: effectiveBody, contactName: name)
    }

    // #2545: Dan's deliberate override of the two greeting holds, pinned to the EXACT text he took it
    // on, the same shape as `lintOverriddenBody` above. Editing the body afterwards re-arms the hold
    // rather than carrying an approval forward onto words nobody has read.
    var greetingOverriddenBody: String? = nil

    var isGreetingOverridden: Bool {
        greetingOverriddenBody != nil && greetingOverriddenBody == effectiveBody
    }

    var isBlockedByGreeting: Bool {
        // #2579 joins this disjunction rather than standing beside it, so it inherits the override Dan
        // already has for a greeting hold. A third hold with no way past it would be the one that made
        // him stop trusting the other two.
        (draftIsMissingGreeting || greetingMisaddressed || greetingNamesSomeoneElse)
            && !isGreetingOverridden
    }

    // RETAINED STORAGE, read by nothing (#2545). This held Dan's own opening for THIS contact, back when
    // the app composed an opening ABOVE the body (#2010). The greeting now lives inside the body, written
    // by whoever writes the body, so there is no second field for him to override.
    //
    // Left on the model deliberately rather than deleted, for the reason given on Prospect's own retained
    // columns: every schema change this app has made was ADDITIVE and it carries no MigrationPlan or
    // VersionedSchema (see AppSchema), so dropping a stored property would be its first subtractive
    // migration against a live store whose only net is the launch backup. Measured 2026-08-12: 3 rows
    // carry a value here, all of them on shows already contacted.
    var openingOverride: String? = nil

    // #2031: which SEND this contact went out with, when it went out with other people. Nil, the ordinary
    // case, means their own email. Two contacts sharing this value are reading the same conversation, and
    // that is the fact every later surface (the follow-up, the note, the reply, the queue row) has to read
    // before it addresses one of them alone.
    var sendGroupId: String? = nil

    // #1845: has anybody actually been written to here, as opposed to this address merely having been
    // FOUND by a reachability check? The two are different kinds of thing and the merges turn on it: a
    // found address is the result of a lookup, repeatable by running the lookup again, while a contacted
    // one records something that happened outside Overture and can never be recreated.
    //
    // Dan's call, 2026-08-03, on three duplicated shows sitting in his queue twice at two different ranks
    // because each copy held addresses nobody had written to: merge them and keep the better contact list.
    //
    // FAILS CLOSED, and that is the whole design. Every mark of contact counts, including a suppression
    // (a booking freeze or a decline is an outcome, not an untouched address) and a stand-down. A field
    // added later is not covered here, so anything that records contact must be added to this list; the
    // cost of missing one is a deleted outreach record, which is why the cheap direction is to count too
    // much rather than too little.
    // #2717: re-decided and unchanged for an attached conversation. `gmailThreadId != nil` no longer
    // proves Overture emailed this contact, but the question here is only whether anything at all marks
    // it as touched, and it does: Dan pitched them by hand, which `formOutreachRecordedAt` below already
    // records. The predicate fails CLOSED by design, so counting an attached thread as a mark of contact
    // errs in the safe direction anyway.
    var wasWrittenTo: Bool {
        if sendState != .pending { return true }        // sent, sending, or deliberately suppressed
        if sentAt != nil || sendClaimedAt != nil { return true }
        if gmailMessageId != nil || gmailThreadId != nil { return true }
        if sendGroupId != nil { return true }   // #2031: went out with other people, still went out
        if replied || bounced || repliedAt != nil { return true }
        // #2711: a reply Dan recorded by hand. `replied` above already covers every mark this can make,
        // since `HandMarkedReply.mark` sets both together, but it is spelled out anyway: this predicate
        // fails closed on purpose, and the cost of missing a field here is a deleted outreach record.
        if replyMarkedByHandAt != nil { return true }
        if followUpCount > 0 || lastFollowUpAt != nil { return true }
        if replySentAt != nil || replyDraftBody != nil || replyDraftRequestedAt != nil { return true }
        if replySendClaimedAt != nil || nudgeSendClaimedAt != nil { return true }
        if formOutreachStartedAt != nil || formOutreachRecordedAt != nil { return true }
        // #2719: a conversation was linked here at some point, which is proof a real exchange existed on
        // this contact. `formOutreachRecordedAt` above already covers every row this can be true of,
        // since an attach refuses without it, but it is spelled out anyway for the same reason
        // `replyMarkedByHandAt` is: this predicate fails closed on purpose, and the cost of missing a
        // field here is a deleted outreach record.
        if conversationEverAttachedAt != nil { return true }
        if outreachStoodDownAt != nil || closingNoteStoodDownAt != nil { return true }
        return false
    }

    // #792: a real contact, with a real address, held back by one of the review guards and waiting on a
    // single glance from Dan.
    //
    // This is NOT the same as "not sendable", and conflating the two is the bug. `isSendablePending` is
    // false for a contact that is FINISHED (already sent, deliberately suppressed, no address at all)
    // and equally false for one that is WAITING. SendService reads it to decide the show is contacted,
    // so a held contact made the whole show read as fully Sent and leave the queue, while that person
    // never received anything and nothing afterwards surfaced them. The held contact is usually the one
    // worth emailing: the act's own address, held back by a heuristic Dan only has to look at to dismiss.
    //
    // A contact paused because the org REPLIED is deliberately not counted. Nothing is blocking it; Dan
    // is choosing not to email again while a conversation is live, and nagging him about that would be
    // nagging him about a thing that is working.
    var isBlockedAwaitingReview: Bool {
        guard sendState == .pending, email?.isEmpty == false, !pausedByReply else { return false }
        // #2545: the greeting hold takes the place of #407's, which policed the same thing from the
        // other side. It belongs HERE and not only in `isSendablePending` for the reason above: a body
        // that forgot its greeting is one edit from sendable, so the person behind it is waiting, not
        // finished, and a show must not leave the queue reading as fully sent on their behalf.
        return isBlockedByGreeting
            || (looksLikeVenue && !looksLikeVenueDismissed)
            || (looksLikePressContact && !looksLikePressContactDismissed)
            || (looksLikeDuplicateContact && !looksLikeDuplicateContactDismissed)
            || isLooksLikeAnotherPersons
            || isBlockedByDraftLint
    }

    // Deterministic send order. SwiftData to-many relationships are UNORDERED, so the send queue and
    // the manual-send picker must impose a stable order or "the next recipient" (and which address each
    // click sends) would vary run to run. Act/performer contacts go first (mutually exclusive per
    // performance, so they tie), then a presenter, then a manual add (the #366/#368 contact ladder:
    // target the act or performer; the presenter only after), ties broken by id.
    var sendOrderRank: Int {
        switch provenance {
        case .act, .performer: return 0
        case .presenter: return 1
        case .manual: return 2
        }
    }

    var firstName: String { Salutation.firstName(name) }

    // Manual-judge outcome marking (#418 B2). Dan hand-sets THIS contact's outcome from the
    // conversation surface, after reading the reply in Gmail. Stamps `outcomeSource = .manual` so
    // per-recipient detection (A2) never overwrites his call, including an "In conversation" mark,
    // which sets the source flag even though it sets no resolution. The locked vocabulary maps onto
    // existing fields with NO new enum: In conversation = (nil, false), Booked = (.booked, false),
    // Closed-not-now = (.declinedSoft, false), Closed-no = (.declinedHard, false), Bounced = (nil, true).
    //
    // ATTRIBUTION ONLY for `.booked`: this attributes the single lead booking to the contact who
    // landed it (`resolution` doc, #389). It does NOT create or count a lead booking and does NOT set
    // `prospect.outcome`; the lead booking stays fully lead-level via DownbeatBooking.reconcileBooked
    // (locked decision g). Phase F's derivation reads `resolution == .booked` for attribution display
    // only; never wire this into the lead booking count.
    func markOutcomeManually(resolution: RecipientResolution?, bounced: Bool = false) {
        self.resolution = resolution
        self.bounced = bounced
        self.outcomeSource = .manual
    }

    // "Remind me later" for this recipient: step its reminder forward by re-anchoring it, without
    // sending.
    func remindLater(now: Date) {
        conversationRemindedAt = now
    }

    // #1740: Dan's answer to a nudge he is never going to send. His words, on the Mark Morris row:
    // "I'm not going to action this." Before this the row offered only Send nudge and View in Archive,
    // so the only ways to clear it were to send an email he did not want to send or to leave it counting
    // toward the badge until the next nudge arrived for the same show he had already declined.
    //
    // ONE fact across both tracks (the silent nudge sequence and the closing note), because it is one
    // decision in his head: stop asking me to write to this contact. Deliberately NOT a resolution. He is
    // not marking the lead lost, and on the closing note specifically (Dan, 2026-07-30) it is "not sent
    // but also done", so nothing here may claim a note went out.
    func standDownOutreach(now: Date) {
        outreachStoodDownAt = now
    }

    // The undo. The row sits one click away from Send nudge, so a decision that removes work from a queue
    // and cannot be taken back is a trap.
    func resumeOutreach() {
        outreachStoodDownAt = nil
    }

    // The closing note was closed out by hand. Same reply-reopens rule as the pitch stand-down: if they
    // write back, there is a live conversation again and it is not done after all.
    var isClosingNoteStoodDown: Bool {
        guard let stoodDown = closingNoteStoodDownAt else { return false }
        if let repliedAt, repliedAt > stoodDown { return false }
        return true
    }

    // #1840: a reply is new information, so it takes the stand-down AND the state that stand-down
    // recorded. A contact who wrote back is not a closed lead, and reporting one against a live
    // conversation is the kind of quiet wrongness nobody goes looking for.
    //
    // Only `.stoodDown` is cleared. A booking or a real decline is a fact about the world that a later
    // email does not undo, and clearing those would let an inbound message erase Dan's own judgement.
    func reopenOnReply(at repliedAt: Date) {
        replied = true
        self.repliedAt = repliedAt
        if resolution == .stoodDown { resolution = nil }
        // #2132: a new exchange starts from no baseline. Left behind, the next pair would measure this
        // answer against a draft written for an older message, which is a lesson about nothing.
        originalReplyDraftBody = nil
        replyDraftWrittenByDan = false
        replyDraftEditedByDan = false
    }

    func standDownClosingNote(now: Date) { closingNoteStoodDownAt = now }
    func resumeClosingNote() { closingNoteStoodDownAt = nil }

    // Whether the stand-down is IN FORCE, which is not the same as whether it was ever made.
    //
    // A reply that lands afterwards puts the contact back in play, and that is derived here from the two
    // stamps rather than cleared by whoever records the reply. If it were a mutation, every present and
    // future reply path would have to remember it, and the failure would be the expensive direction: a
    // contact stood down in June writes back in July and the app stays quiet about it. That costs a
    // booking, where the other direction costs an unsent nudge.
    var isOutreachStoodDown: Bool {
        guard let stoodDown = outreachStoodDownAt else { return false }
        if let repliedAt, repliedAt > stoodDown { return false }
        return true
    }

    // "Remind me later" for the silent nudge track. Deliberately its own stamp rather than moving
    // `lastFollowUpAt`: that field means a nudge actually WENT, and a record of the past must not be
    // rewritten by a decision to wait (L37).
    func remindLaterAboutNudge(now: Date) {
        nudgeRemindedAt = now
    }

    // The AI's auto-classification suggests a state for this recipient (source = auto). Never
    // overwrites a state Dan set by hand.
    // #2171: re-suggesting the SAME state leaves the date alone. #2116 anchored an unconfirmed guess to
    // the instant it was made so an untriaged one ages and can read as overdue, and this writer defeated
    // it: the classifier re-stamped the anchor on every run, so the guess was always freshly made and the
    // card re-filed itself under today. Measured on the live store, a day-old suggestion carried a stamp
    // from one minute before Dan looked at it, and the card read "Reach out now" (L74, L55).
    //
    // Copy-out path (#421): Dan pasted the draft into the Gmail thread he's reading and sent it there
    // himself, so Overture sends nothing. Consume the draft and re-anchor this contact's clock.
    // #431: a "Drafting a reply…" run that has produced nothing after this long is treated as a dead
    // run and surfaced as needs-attention, so a stranded request never sits in progress forever.
    static let replyDraftStallTimeout: TimeInterval = RunTimeouts.replyDraft

    // #2966: WHEN the reply draft this contact is still waiting on was asked for, from the one shared rule.
    // See `ReplyDraftRequest` for why the rule is not spelled here: three places asked this question and
    // only one of them allowed for a request belonging to an exchange already answered.
    var awaitedReplyDraftRequestedAt: Date? {
        ReplyDraftRequest.awaited(requestedAt: replyDraftRequestedAt, draftBody: replyDraftBody,
                                  answeredAt: replyHandledAt)
    }

    // True when a reply draft is still awaited and the timeout has elapsed (#431).
    // #471: `runAlive` is the classify run's real heartbeat (ReplyClassifyService.isRunning); when it's
    // still alive, past-timeout no longer counts as stalled, since the wall clock alone can't tell a
    // genuinely dead run from one that's just slower than usual.
    //
    // #2966: this used to ask "requested, and nothing stored" for itself, which is the same question
    // `ReplyPanel.isDrafting` asks with one more guard on it. It reads the shared answer now: an answered
    // conversation was reading as permanently stalled, and since #2878 that number is on the Follow-ups
    // pill, the Due header, the toolbar badge, the Dock tile and the menu bar.
    func isReplyDraftStalled(now: Date, timeout: TimeInterval = Recipient.replyDraftStallTimeout, runAlive: Bool = false) -> Bool {
        guard let requested = awaitedReplyDraftRequestedAt else { return false }
        return !runAlive && now.timeIntervalSince(requested) >= timeout
    }

    // True when a send was claimed and has run long enough to be considered stuck rather than a
    // normal brief send (#475/#476): the app was interrupted (crash, or a save that never landed)
    // between claiming the send and recording its outcome. Must be surfaced for Dan to check Gmail
    // and resolve by hand: never auto-resent (still not .pending) and never auto-assumed sent.
    func isSendStuck(now: Date, timeout: TimeInterval = RunTimeouts.send) -> Bool {
        guard sendState == .sending, let claimed = sendClaimedAt else { return false }
        return now.timeIntervalSince(claimed) >= timeout
    }

    // Apply Dan's edit to the AI reply draft (#459), mirroring Prospect.applyEdit for the cold draft:
    // his text wins and the deterministic DraftCheck warnings stop nagging on it.
    // #2131: Dan wrote this reply himself, with nothing to edit. Its own field rather than reusing
    // "edited", which would say the card had an earlier version it never had, and which also switches the
    // lint off (QueueView+Model.replyDraftFindings) so the default path would silently skip it.
    // Mirrors the cold path's own draftWrittenByDan.
    var replyDraftWrittenByDan: Bool = false

    func applyReplyDraftEdit(_ body: String) {
        // #2143: text that is the same as what is already stored is not an edit of it. Unreachable while
        // the reply panel's compose box always opened empty, since the only words that could arrive here
        // were words Dan had typed; now that the box opens on the waiting draft, sending it back untouched
        // would claim on the card that he edited it, and would switch the lint off on a draft nobody has
        // read (L11).
        guard body != replyDraftBody else { return }
        // Snapshot the AI reply as the learning baseline on the first substantive edit only, mirroring
        // Prospect.applyEdit; trivial / whitespace saves never overwrite it (#463).
        // #2131: only ever the AI's version. Capturing his own first draft here would teach the voice
        // pair that he "edited" himself, from a baseline no model ever wrote.
        if originalReplyDraftBody == nil, !replyDraftWrittenByDan,
           Prospect.isSubstantiveEdit(oldSubject: nil, oldBody: replyDraftBody, newSubject: "", newBody: body) {
            originalReplyDraftBody = replyDraftBody
        }
        // Writing where there was nothing, or revising his own words, is his; changing a draft the AI
        // produced is an edit. The two are different claims and the card states whichever is true.
        let hadSomethingToEdit = (replyDraftBody?.isEmpty == false)
        if hadSomethingToEdit && !replyDraftWrittenByDan {
            replyDraftEditedByDan = true
        } else {
            replyDraftWrittenByDan = true
        }
        replyDraftBody = body
    }

    // Freeze the exact reply body Dan committed (sent or copied out), immune to later re-drafts, as the
    // "sent" side of the voice pair (#463).
    //
    // #2132: once per EXCHANGE, not once per contact. Guarding on "never captured" meant only the first
    // answer in any thread ever taught anything, and answering from the queue is precisely about the
    // second and third. A capture is allowed again only once they have written again since the last one,
    // so a stray re-send cannot overwrite a captured pair with a later timestamp.
    func freezeSentReply(now: Date) {
        guard let body = replyDraftBody, !body.isEmpty else { return }
        if let captured = replySentAt {
            guard let theirs = replyArrivedAt, theirs > captured else { return }
        }
        sentReplyBody = body
        replySentAt = now
    }

    // #2170: everything that is true once Dan's answer has actually gone, whichever way he sent it.
    //
    // ONE routine, called by both paths (SendService.sendReplyDraft after a confirmed send, and the
    // copy-out path in ProspectMutations), because the defect this fixes was present in both and a fix
    // written into only the in-app send would leave the Answer button sitting there for anyone who
    // answered by copying the draft into Gmail, which is the harder case to notice (L30).
    //
    // Named for what it means rather than for one of the two ways it happens: it used to be called
    // recordRepliedInGmail, which stopped being true the moment the in-app send started calling it.
    func recordAnswerSent(now: Date) {
        freezeSentReply(now: now)   // capture the committed copy before consuming the draft (#463)
        replyDraftSubject = nil
        replyDraftBody = nil
        lastFollowUpAt = now
        // The fact that had no home: Dan answered. Stamped LAST and unconditionally, unlike the freeze
        // above, which legitimately declines when there is nothing new to capture. An answer that went
        // out is an answer that went out.
        replyHandledAt = now
    }

    // #2865: Dan answered this conversation in his mail client, and detection read it off the thread.
    //
    // The answered fact ONLY. `sentReplyBody` and `replySentAt` mean "these are the words Dan committed
    // through Overture" and feed the voice pair (#463); a message sent from a mail client supplies
    // neither, so claiming them would file words Overture never saw and teach the voice learner from a
    // record it cannot read. Exactly the split `markReplyAnswered` already makes for a peer.
    // Deliberately NO new stored field marking where the answer came from. That would be a schema
    // addition to the live model, which this repo rehearses against a clone of the real store before
    // shipping (#2284), and it buys nothing today: an answered row carrying no `sentReplyBody` already
    // exists and is already handled, because that is exactly what a PEER on a joint reply looks like
    // after `markReplyAnswered`. The surfaces treat this identically.
    func recordAnsweredElsewhere(at answeredAt: Date) {
        markReplyAnswered(now: answeredAt)
    }

    // #2191: the GROUP half of an answer, for a peer that was on the same incoming reply but sent nothing
    // itself. Only the answered stamp, never the sent body or send time, which belong to whoever sent them.
    // Never moves backwards, so a later answer on the thread cannot be undone by an earlier one arriving
    // out of order.
    func markReplyAnswered(now: Date) {
        guard let existing = replyHandledAt else { replyHandledAt = now; return }
        if now > existing { replyHandledAt = now }
    }

    // Dan dismissed a wrong auto-detected reply for THIS contact (#219, per-recipient #418): revert
    // the replied state and remember the wrong reply's id so detection never re-flags that same one,
    // while a genuinely newer reply on the contact's thread still gets detected.
    func dismissAutoReply() {
        guard replied else { return }
        replied = false
        repliedAt = nil
        lastReplyText = nil
        dismissedReplyId = lastReplyId
        // The reply is gone, so its derived AI hint + draft must go too (#449); otherwise the
        // contact reads "Awaiting reply" yet still shows an intent suggestion and a leftover draft.
        intentHint = nil
        replyDraftSubject = nil
        replyDraftBody = nil
        replyDraftRequestedAt = nil
        replyDraftEditedByDan = false
        // The reply was wrong, so any half-captured voice pair for it is bogus too (#463).
        originalReplyDraftBody = nil
        sentReplyBody = nil
        replySentAt = nil
    }

    // Dan dismissed a wrong auto-detected bounce for THIS contact (#398): revert bounced and
    // remember the wrong bounce message's id so detection never re-flags that same one, while
    // a genuinely new bounce on the contact's thread still gets detected. Mirrors dismissAutoReply.
    func dismissAutoBounce() {
        guard bounced else { return }
        bounced = false
        dismissedBounceId = lastBounceId
    }
}
