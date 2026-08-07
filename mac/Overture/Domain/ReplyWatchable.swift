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
    // #2149: when the repair pass last TRIED to fill in the message text, set whether or not it found any.
    // A reply with no decodable body yields nothing every time, so without a record of the attempt the row
    // stays in the gap and its thread is refetched from Gmail forever with nothing changing (L47).
    var replyTextCheckedAt: Date? { get set }
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
    // The default is the plain recording, which is all a test double has to do. `Recipient` overrides it
    // to clear a stand-down as well.
    func reopenOnReply(at repliedAt: Date) {
        replied = true
        self.repliedAt = repliedAt
    }
}

// A contacted entity (a show's lead, or an inquiry) that owns one or more watched threads.
protocol ReplyWatchable: AnyObject {
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
}

extension Prospect: ReplyWatchable {
    var replyWatchDisplayName: String { groupName }
    var replyWatchManualOutcome: Bool { outcomeSourceRaw == OutcomeSource.manual.rawValue }
    var replyWatchIsBooked: Bool { outcome == .booked }
    var replyWatchRecipients: [any ReplyWatchableRecipient] { recipients }
}
