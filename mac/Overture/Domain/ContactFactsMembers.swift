import Foundation

// #4357 slice D1 (plan v7 Phase 3 step 1): the computed members the reached-out terms read about one CONTACT,
// moved here from `Recipient` so both conformers of `ContactFacts`, the live model and the retained
// `RecipientRecord`, answer them by ONE body (L263, L370). The comments travelled with the rules unchanged.
//
// Three kinds, and how each is kept to one body:
//   - A rule with no setter (everything from `hasWatchableConversation` down) lives ONLY here; the model
//     answers it by conforming.
//   - A typed view of a stored raw value that the model also WRITES through (`sendState`, `resolution`,
//     `outcomeSource`, `outreachChannel`) keeps its get/set property on `Recipient`, because a protocol
//     extension cannot add a setter to a value type's conformance. Its getter reads THIS body, through
//     `Recipient.asContactFacts`, so the decoding rule exists once.
//   - `replyArrivedAt` is shared with an inquiry through `ReplyWatchableRecipient`, so it lives on
//     `ReplyArrivalFacts`, which both protocols refine. Defined on each, a `Recipient` (which is both) would
//     have two equally good answers and every call would be ambiguous.
//
// In a file of its own rather than in `QueueFacts.swift`, for the reason `ProspectFactsMembers.swift` gives.
extension ContactFacts {
    var sendState: SendState { SendState(rawValue: sendStateRaw) ?? .pending }

    var resolution: RecipientResolution? { resolutionRaw.flatMap(RecipientResolution.init) }

    var outcomeSource: OutcomeSource? { outcomeSourceRaw.flatMap(OutcomeSource.init) }

    // #2716: HOW THE PITCH WENT OUT, and nothing else. It is stamped at send and never flips (L37): a
    // pitch that left through a contact form did not retrospectively become an email because a reply to
    // it arrived by one. Milestone #58 lets Dan attach the Gmail conversation such a pitch was answered
    // on, and the question that then matters, "can Overture watch this?", is the separate predicate
    // below rather than a second meaning loaded onto this one.
    var outreachChannel: OutreachChannel { outreachChannelRaw.flatMap(OutreachChannel.init) ?? .email }

    // #2716: is there a conversation Overture can read on this contact? Written by every genuine send
    // (`SendService.deliver`, the reply path, the batch send), by `RecipientBackfill` carrying a lead
    // rollup down, and, from #2715, by Dan attaching one to a form or DM pitch by hand.
    //
    // An empty string is not a conversation. SwiftData hands back whatever was stored, and a blank id
    // would otherwise read as watchable and be fetched, which is why every Gmail reader in the app
    // already spells the same `!isEmpty` guard inline. One definition instead of six.
    var hasWatchableConversation: Bool {
        guard let t = gmailThreadId else { return false }
        return !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // #2716: a pitch Overture can neither send on nor watch, which until this milestone was the whole
    // meaning of `.contactForm`. The four rules that used to ask the channel ask this instead, so a form
    // pitch carrying an attached conversation stops being treated as a silent one.
    var isUnwatchedFormPitch: Bool {
        outreachChannel == .contactForm && !hasWatchableConversation
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

    // #2717: a form or DM pitch carrying a conversation Overture never sent on.
    //
    // Self-healing rather than a permanent brand, which is why `gmailMessageId` is in it: the moment
    // Overture's own reply lands on the attached thread, `sendReplyDraft` stores the id Gmail assigned it,
    // and from then on there IS a message of Overture's to thread off. A rule keyed on the channel alone
    // would go on refusing long after its reason had gone (L68).
    // #3712: and never keyed on the CHANNEL alone any more. That clause was exactly right while an
    // attached conversation could only ever sit on a form pitch, and phase 3 of milestone 82 made an
    // emailed pitch attachable: on #3706's row the channel is `.email` and `gmailMessageId` names a real
    // message Overture sent, so all three clauses were false about a thread Overture has never sent a
    // word on, and the three readers of this predicate acted on that answer.
    //
    // The displaced arm asks the same question the original does, in the terms that row makes available:
    // is the outgoing message this row holds a message on the conversation it now stores? While it is
    // still the one the link displaced, it is not. It heals the same way too, because `sendReplyDraft`
    // stores the id Gmail assigns Overture's own answer on the linked thread.
    //
    // #4357 slice D1: here rather than in `Recipient`'s `ReplyWatchableRecipient` conformance, which it
    // still satisfies, so the facts a retained contact carries answer it by the same body.
    var replyWatchConversationIsAttached: Bool {
        guard hasWatchableConversation else { return false }
        if attachDisplacedThreadId != nil { return gmailMessageId == attachDisplacedMessageId }
        return outreachChannel == .contactForm && gmailMessageId == nil
    }

    // #4357 slice E2: three `ReplyWatchableRecipient` members, moved from `Recipient`'s conformance (which they
    // still satisfy) so a retained contact answers the reply search and the conversation proposal by them.
    var replyWatchManualOutcome: Bool { outcomeSourceRaw == OutcomeSource.manual.rawValue }
    var replyWatchIsBooked: Bool { resolution == .booked }
    // #2196: nothing has closed it out. Deliberately the same three facts `hasUnhandledReply` reads
    // before it asks anything else, so a conversation that could still put itself in front of Dan is
    // exactly the one still being watched, and the two cannot disagree about which those are.
    var replyWatchConversationIsOpen: Bool { resolution == nil && !bounced }

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
    // #3712: and never onto a conversation Overture did not send on. This is the OPPOSITE direction to
    // the paragraph above and does not weaken it: that one refuses to read an attach as "this is an email
    // contact now", which would make a form pitch instantly nudgeable. This one refuses to go on treating
    // an EMAIL contact as nudgeable once a link has moved it onto somebody else's thread and somebody
    // else's address. The nudge is a cold chase, threaded onto the conversation Overture itself started,
    // and after a replacing attach the row holds neither: it would arrive as a chase of a pitch the writer
    // never received, on a conversation Overture never opened. It heals with the predicate, so a row
    // Overture has since answered on is nudgeable again exactly as it was.
    var isAwaitingFollowUp: Bool {
        isSilent && resolution == nil && outcomeSource != .manual && outreachChannel == .email
            && !replyWatchConversationIsAttached
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

    var standing: RecipientStanding {
        let reachable = (email?.isEmpty == false) || (contactFormURL?.isEmpty == false)
        return RecipientStanding(sendState: sendState, resolution: resolution, bounced: bounced,
                                 hasContactPath: reachable)
    }

    // The closing note was closed out by hand. Same reply-reopens rule as the pitch stand-down: if they
    // write back, there is a live conversation again and it is not done after all.
    var isClosingNoteStoodDown: Bool {
        guard let stoodDown = closingNoteStoodDownAt else { return false }
        if let repliedAt, repliedAt > stoodDown { return false }
        return true
    }

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

    // #4357 slice G1: the three address members the row's contact facts read, moved from `Recipient` with
    // their comments unchanged.
    //
    // #2937: whether the app may still treat this route as a guess. ONE predicate, because four readers
    // ask it (the social route list, the stored verdict, the card's own line, and whether a DM can be
    // recorded), and four spellings of one question is how they come to disagree about a single row
    // (L16).
    var isUnconfirmedNameMatch: Bool { nameMatchOnly && !nameMatchOnlyDismissed }

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

    // #3387 / milestone 61 Phase 0.1. Does an ADDRESS exist that no research guard is holding.
    //
    // Deliberately NOT `isSendablePending`. That answers whether this may go out RIGHT NOW and folds in
    // an uncleared calendar conflict (#901), a blank subject line (#2052), the lint and greeting holds
    // (#2545), `pausedByReply` and this row's send state, none of which is a fact about whether a way to
    // contact anybody exists. Measured on the live store 2026-08-31: 9 prospects held an unguarded
    // address while their stored verdict denied it, 7 of them masked by an open calendar conflict.
    //
    // Dan's rule, 2026-08-31: "It should only be impacted by whether or not I'm physically capable of
    // contacting them."
    //
    // ADDRESS ONLY, on purpose. It is substituted into the FIRST arm of the verdict cascade, and a
    // route bearing predicate there would report every form-only and social-only show as `emailFound`.
    // `Prospect.hasAnyRoute` is the "a way in of any kind" question and is derived from the whole
    // cascade rather than written beside it.
    //
    // The FIFTH hold state is decided here rather than left to be discovered. `isHeldDownToUnverified`
    // is in neither `isHeldByAGuard` nor `isSendablePending`; it drives warnings only. So a held down
    // address IS a route here, which matches today's behaviour and is the right answer: the hold down
    // describes confidence in WHO is on the end, which the card already warns about, and withholding
    // the route as well would silently remove a show Dan can judge in seconds.
    var hasUnguardedAddress: Bool { email?.isEmpty == false && !isHeldByAGuard }

    // #4357 slice F: the two reply draft members `StalledReplyDraft` reads, moved from `Recipient` unchanged.
    //
    // #2966: WHEN the reply draft this contact is still waiting on was asked for, from the one shared rule.
    // See `ReplyDraftRequest` for why the rule is not spelled here: three places asked this question and
    // only one of them allowed for a request belonging to an exchange already answered.
    var awaitedReplyDraftRequestedAt: Date? {
        ReplyDraftRequest.awaited(requestedAt: replyDraftRequestedAt, draftBody: replyDraftBody,
                                  replacingDraftOnFile: replyDraftReplacesDraftOnFile,
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
    func isReplyDraftStalled(now: Date, timeout: TimeInterval = Recipient.replyDraftStallTimeout,
                             runAlive: Bool = false) -> Bool {
        guard let requested = awaitedReplyDraftRequestedAt else { return false }
        return !runAlive && now.timeIntervalSince(requested) >= timeout
    }
}

extension Recipient {
    /// #4357 slice D1: this contact seen only as `ContactFacts`, so a member read through it reaches the
    /// protocol's one body above rather than the same-named property this model keeps for its setter.
    /// Without it, a getter on `Recipient` that named its own property would call itself.
    var asContactFacts: some ContactFacts { self }
}
