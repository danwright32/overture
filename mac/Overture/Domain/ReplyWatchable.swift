import Foundation

// Phase 1 (#1434): the seam that lets reply and bounce detection run over ANY contacted entity, not
// just `Prospect`, so a second entity type (Inquiry, #1435) rides the same tested ReplyService /
// BounceService pipeline instead of a duplicated one. Class-bound (`AnyObject`) on purpose: the
// detection loops mutate the recipient in place, and that write must reach the live `@Model`.
//
// The guards are exposed as semantic booleans (`replyWatchManualOutcome`, `replyWatchIsBooked`)
// rather than the raw `outcomeSourceRaw` / `resolution` enums, so a conformer whose outcome model
// differs from Prospect's (Inquiry keeps its own) still expresses the same "leave this alone" rule
// without inheriting Prospect's enum vocabulary.

// One contacted address whose Gmail thread is watched for a reply or a bounce.
protocol ReplyWatchableRecipient: AnyObject {
    var gmailThreadId: String? { get }
    // #2649: the Message-ID our own next message on this conversation references. Settable, because the
    // threading repair rewrites the minted ids Gmail discarded (#2647) with the ones it really assigned,
    // and it does that for every kind of thing that holds a thread rather than for prospects alone: an
    // inquiry carries its own thread and its own stored id and has exactly the same dangling follow-up.
    // A second pass written just for inquiries would be one nothing ever ran, since the live store holds
    // none today (L30).
    var gmailMessageId: String? { get set }
    // #2653: the ancestry of that message. A requirement now that both conformers carry it (Recipient
    // since #2648, Inquiry since #2661), so `ReplyThreading.references` below can be one implementation
    // rather than one per send path.
    var gmailReferences: String? { get set }
    // #2649: and whether the id above can be trusted to thread. Settable here because the repair is what
    // clears it (the real id is now stored) and what sets it (the thread read fine and named no message of
    // Dan's, so this conversation cannot be threaded and something has to say so rather than the pass
    // failing silently, L11).
    var threadingDegraded: Bool { get set }
    // #2032: the address this contact was written at, so a thread carrying more than one of them can say
    // which one a reply came from.
    var replyWatchAddress: String? { get }
    var replyWatchManualOutcome: Bool { get }   // Dan hand-set this contact's state; never auto-overwrite.
    var replyWatchIsBooked: Bool { get }         // this contact is booked; stop watching it.
    // #2196: is this conversation still going? A contact that has already replied is re-read on later
    // checks only while this is true, which is how a SECOND message on a live thread is found at all.
    // It is also the bound on that cost: the set of open conversations is small and shrinks as Dan closes
    // them out, where "every contact that ever replied" would grow with every show he ever pitched.
    var replyWatchConversationIsOpen: Bool { get }
    // #2717: was this conversation ATTACHED by hand rather than started by an Overture send? A thread used
    // to prove Overture had emailed here; since #2715 it can also be a conversation Dan linked to a form
    // or DM pitch, on which Overture has sent nothing and therefore has no message to thread a new one
    // off. Everything that would ADD a message of Overture's own must refuse those (`AttachedConversation`).
    //
    // A required member rather than a defaulted `false`, so a later conformer has to state its own answer
    // instead of silently inheriting an exemption nobody chose (L129).
    var replyWatchConversationIsAttached: Bool { get }
    var replied: Bool { get set }
    var repliedAt: Date? { get set }
    var lastReplyId: String? { get set }
    var lastReplyText: String? { get set }
    // #2063: who the latest reply was addressed to, captured from the same message as the text above, so
    // Dan's answer can be addressed the way it was rather than the way his original send was. A settable
    // requirement rather than a default no-op: both conformers have a send path that reads it, and a field
    // written with no reader is the shape L46 names.
    var replyAudience: [String]? { get set }
    // #2113: WHO wrote back, and when they sent it. Settable requirements rather than defaulted no-ops,
    // for the same reason `replyAudience` is: both conformers have a surface that reads them (the queue
    // row names the writer, the queue dates the row by the send time), and a field written with nothing
    // reading it is the shape L46 names.
    var replyFromAddress: String? { get set }
    var replyFromName: String? { get set }
    var inboundReplySentAt: Date? { get set }
    // #2653: the Message-ID of the message being answered, so Dan's reply names THEIR message as its
    // parent rather than his own last one. A settable requirement for the same reason the three above
    // are: both conformers have a send path that reads it, through `ReplyThreading` below.
    var inboundReplyMessageId: String? { get set }
    // #2149: when the repair pass last TRIED to fill in the message text, set whether or not it found any.
    // A reply with no decodable body yields nothing every time, so without a record of the attempt the row
    // stays in the gap and its thread is refetched from Gmail forever with nothing changing (L47).
    var replyTextCheckedAt: Date? { get set }
    // #2865: record that Dan answered this conversation from his mail client, dated by that message.
    //
    // A DEFAULTED no-op rather than a required member, which is the exception to this protocol's own rule
    // about defaults (L129). #2943 closed the reason it was written for: `Inquiry` had no answered stamp
    // in the live schema, so a required member would have had to invent one, and it now has
    // `replyHandledAt` and overrides this exactly as `Recipient` does. BOTH real conformers answer for
    // themselves; what the default still covers is the test doubles in this suite, which own no such
    // fact and are not the thing this protocol is about.
    func recordAnsweredElsewhere(at answeredAt: Date)

    var dismissedReplyId: String? { get }        // a reply Dan already dismissed as not real.
    var bounced: Bool { get set }
    var lastBounceId: String? { get set }
    var dismissedBounceId: String? { get }
    var lastDelayMessageId: String? { get set }
    var delayNoticeAt: Date? { get set }

    // #1840: record a reply, and clear anything a reply should clear. A method rather than two field
    // writes because the rule ("a reply clears the stand-down, and only the stand-down") has to hold
    // wherever a reply is recorded; written as assignments at the call site it was already forgotten once.
    func reopenOnReply(at repliedAt: Date)
}

extension ReplyWatchableRecipient {
    // #2865: the default, for a conformer with no answered stamp of its own to write.
    func recordAnsweredElsewhere(at answeredAt: Date) {}

    // The default is the plain recording, which is all a test double has to do. `Recipient` overrides it
    // to clear a stand-down as well.
    func reopenOnReply(at repliedAt: Date) {
        replied = true
        self.repliedAt = repliedAt
    }

    // #2113: when the reply actually ARRIVED, which is what every date surface wants. Prefers the instant
    // they sent it over the instant Overture noticed, and falls back to the notice for a row recorded
    // before the send time was captured.
    //
    // #2118: stated here rather than on each conformer, so a scouted contact and a direct hire inquiry
    // cannot answer it differently. They already did: the queue dated a show's reply by when the person
    // wrote and an inquiry's by when Overture noticed, up to a night apart on two rows sharing one set of
    // date headings. One definition, because the queue, the reminder calculator and the OmniFocus sync all
    // ask it and two of them asking differently is how a card ends up under the wrong day (L16).
    var replyArrivedAt: Date? { inboundReplySentAt ?? repliedAt }
}

// A contacted entity (a show's lead, or an inquiry) that owns one or more watched threads.
protocol ReplyWatchable: AnyObject {
    // #2915: a reply after a close out clears an ending that says nobody ever answered. On the protocol
    // rather than on the prospect alone, because an inquiry rides this same check and is closed out from
    // the same vocabulary, so the half nobody wrote would be the half nobody noticed (L30).
    @discardableResult func reopenOnReply(at repliedAt: Date) -> Bool
    var replyWatchManualOutcome: Bool { get }   // lead hand-resolved; stop watching ALL its threads.
    var replyWatchIsBooked: Bool { get }         // lead booked; the whole thing is closed.
    var replyWatchRecipients: [any ReplyWatchableRecipient] { get }
    // #2032: what to call this in a report Dan reads.
    var replyWatchDisplayName: String { get }
    // A fresh reply on this entity pauses its still-unsent contacts pending Dan's triage (#430).
    func pausePendingForReply()
}

extension Recipient: ReplyWatchableRecipient {
    var replyWatchAddress: String? { email }
    var replyWatchManualOutcome: Bool { outcomeSourceRaw == OutcomeSource.manual.rawValue }
    var replyWatchIsBooked: Bool { resolution == .booked }
    // #2196: nothing has closed it out. Deliberately the same three facts `hasUnhandledReply` reads
    // before it asks anything else, so a conversation that could still put itself in front of Dan is
    // exactly the one still being watched, and the two cannot disagree about which those are.
    var replyWatchConversationIsOpen: Bool { resolution == nil && !bounced }
    // #2717: a form or DM pitch carrying a conversation Overture never sent on.
    //
    // Self-healing rather than a permanent brand, which is why `gmailMessageId` is in it: the moment
    // Overture's own reply lands on the attached thread, `sendReplyDraft` stores the id Gmail assigned it,
    // and from then on there IS a message of Overture's to thread off. A rule keyed on the channel alone
    // would go on refusing long after its reason had gone (L68).
    var replyWatchConversationIsAttached: Bool {
        outreachChannel == .contactForm && hasWatchableConversation && gmailMessageId == nil
    }
}

extension Prospect: ReplyWatchable {
    var replyWatchDisplayName: String { groupName }
    var replyWatchManualOutcome: Bool { outcomeSourceRaw == OutcomeSource.manual.rawValue }
    var replyWatchIsBooked: Bool { outcome == .booked }
    var replyWatchRecipients: [any ReplyWatchableRecipient] { recipients }
}


// #2653: WHICH message an answer threads onto, in one place so the prospect reply path and the inquiry
// reply path cannot answer it differently.
//
// The defect this replaces: both used the stored `gmailMessageId`, which is OVERTURE'S OWN last outgoing
// message. `In-Reply-To` is defined as the message this one is a direct response to, so pointing it there
// made the contact's reply a sibling of Dan's answer rather than its parent, and a client that draws the
// conversation as a tree hung his answer off his own earlier message instead of under theirs.
enum ReplyThreading {

    // Their message when it is known, ours when it is not. The fallback is exactly the old behaviour, and
    // it is deliberate rather than lazy: a reply detected before this shipped carries no inbound id, and
    // imperfect nesting is a great deal better than a message with no parent at all (L5).
    static func inReplyTo(for r: any ReplyWatchableRecipient) -> String? {
        let theirs = r.inboundReplyMessageId?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let theirs, !theirs.isEmpty { return theirs }
        return r.gmailMessageId
    }

    // The whole ancestry, oldest first: everything Overture already knew, then OUR last message, then
    // THEIRS. Their message is the new parent and Dan's own earlier one stays in the chain, because
    // dropping it would be #2648's defect arriving by a new route: a client that threads by walking
    // References would lose the link back through his side of the conversation.
    //
    // Degrades to exactly today's chain when their id is unknown, since `MailThreading.references` drops
    // every empty part.
    static func references(for r: any ReplyWatchableRecipient) -> String? {
        let ours = MailThreading.references(parentReferences: r.gmailReferences,
                                            parentMessageID: r.gmailMessageId)
        return MailThreading.references(parentReferences: ours,
                                        parentMessageID: r.inboundReplyMessageId)
    }
}
