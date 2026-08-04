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
    var replied: Bool { get set }
    var repliedAt: Date? { get set }
    var lastReplyId: String? { get set }
    var lastReplyText: String? { get set }
    // #2063: who the latest reply was addressed to, captured from the same message as the text above, so
    // Dan's answer can be addressed the way it was rather than the way his original send was. A settable
    // requirement rather than a default no-op: both conformers have a send path that reads it, and a field
    // written with no reader is the shape L46 names.
    var replyAudience: [String]? { get set }
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
}

extension Prospect: ReplyWatchable {
    var replyWatchDisplayName: String { groupName }
    var replyWatchManualOutcome: Bool { outcomeSourceRaw == OutcomeSource.manual.rawValue }
    var replyWatchIsBooked: Bool { outcome == .booked }
    var replyWatchRecipients: [any ReplyWatchableRecipient] { recipients }
}
