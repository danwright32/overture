import Foundation

// #1630: how a contact was actually reached. Until now there was one channel (Gmail) and it was
// implicit, which is why `nil` reads as email rather than as unknown: every record written before
// this existed went out by email, and saying so costs no migration.
enum OutreachChannel: String, CaseIterable, Sendable {
    case email
    case contactForm = "contact_form"
}

extension Recipient {
    var outreachChannel: OutreachChannel {
        get { outreachChannelRaw.flatMap(OutreachChannel.init) ?? .email }
        set { outreachChannelRaw = newValue.rawValue }
    }
}

extension Prospect {
    // Record that Dan pitched this contact through the act's own form. The stamping mirrors
    // SendService.deliver deliberately, field for field: the same recipient receipt, the same
    // write-once lead rollup (so the ~20 lead-level "was this contacted at all" readers keep
    // working), and the same flip to `.contacted` once nothing sendable is left. What it cannot
    // mirror is the Gmail side, and that absence is the point: no thread, no message id, so nothing
    // downstream goes looking for a conversation Overture cannot see.
    @discardableResult
    func recordFormOutreach(_ recipient: Recipient, now: Date, formURL: String? = nil) -> Bool {
        // Assume it runs twice. The recorded date is what the decide clock counts from and what #16
        // will attribute an outcome to, so a second click must not move it.
        guard recipient.formOutreachRecordedAt == nil else { return false }
        recipient.formOutreachPriorStatusRaw = status.rawValue
        recipient.outreachChannel = .contactForm
        recipient.formOutreachRecordedAt = now
        recipient.formOutreachURL = formURL
        recipient.sentAt = now
        recipient.sendState = .sent
        if sentAt == nil {
            sentAt = now
            priorRelationshipAtSend = priorRelationship
            freezeFeaturesAtSend()
            // Deliberately NOT stamping gmailThreadId/gmailMessageId: there is no conversation to
            // thread off and nothing for reply detection to watch.
        }
        freezeSentCopy(subject: draftSubject ?? "", body: recipient.effectiveBody ?? "")
        if !recipients.contains(where: \.isSendablePending) {
            status = .contacted
        }
        return true
    }

    // Unwind a form record Dan takes back ("Didn't send"), or a misclick. Refused once a real email has
    // also gone out on this show: the lead-level rollup (the send date, the frozen ranking features, the
    // relationship captured at send) then describes THAT send, and clearing it to unwind a form record
    // would rewrite the history of a genuine one. Refusing is honest; a partial undo is not.
    @discardableResult
    func undoFormOutreach(_ recipient: Recipient) -> Bool {
        guard recipient.formOutreachRecordedAt != nil else { return false }
        guard !recipients.contains(where: { $0.gmailMessageId != nil }) else { return false }

        if let raw = recipient.formOutreachPriorStatusRaw, let prior = ReviewStatus(rawValue: raw) {
            status = prior
        }
        recipient.formOutreachPriorStatusRaw = nil
        recipient.formOutreachRecordedAt = nil
        recipient.formOutreachURL = nil
        recipient.outreachChannelRaw = nil
        recipient.sentAt = nil
        recipient.sendState = .pending
        // Only this contact's record existed, so the show's whole send snapshot belongs to it.
        unfreezeSendSnapshot()
        return true
    }
}
