import Foundation

// The exact thing Dan sees before a manual send goes out (#49): the recipient and
// subject of the one email about to send. Built from the performance's NEXT pending
// recipient (same source as SendService.sendOne), so the confirm step can never appear
// for an email that wouldn't actually go, and a fully-sent show yields nil (no
// duplicate send). For a multi-recipient show each click confirms the next address.
struct SendConfirmation: Equatable {
    // #360: the confirmation is now a branded sheet that shows From / To / Subject and a preview of
    // the exact body. `from` is the one true sending identity (SendIdentity.danWright), the same one
    // the live sender uses, so what Dan confirms cannot differ from what actually goes out.
    // #948: generalized so the SAME sheet presents all three consequential sends (a draft, a follow-up
    // nudge, a conversation note). The three differ only in their heading and their reassurance, which
    // ride along here rather than being hardcoded in the sheet, so each says the true thing (a closing
    // note also closes the lead out, and only the draft can claim "nothing else goes out").
    let from: SendIdentity
    let recipient: String
    let subject: String
    let body: String
    let title: String
    let reassurance: String
    // #1219: set when a DIFFERENT show has already been emailed on this performance's date, so the send
    // sheet warns of a self double-booking at the committing moment and Dan confirms past it deliberately
    // (a blank warning means no collision). Set by the caller, which has the whole queue to compare.
    var selfBookingWarning: String? = nil

    // The main draft send: the show's next pending recipient over the shared draft body.
    @MainActor
    init?(prospect: Prospect, signature: OutboundSignature = GmailSignatureStore.currentSignature()) {
        guard let next = SendService.nextPendingRecipient(for: prospect),
              let email = next.email, !email.isEmpty,
              let body = prospect.draftBody, !body.isEmpty,
              // #2029: composed by the SAME helper the send path uses, for the SAME recipient, so the
              // preview cannot show a different email from the one that goes out. `nil` here is the same
              // condition that stops a send, so a sheet can still never appear for an email that would not
              // actually leave.
              let pitch = OutgoingPitch.text(for: next, of: prospect) else { return nil }
        from = .danWright
        recipient = email
        // #2029: and through previewBody, which is where GmailMessage.rfc822 appends the sign-off, so the
        // preview carries it for the same reason the email does rather than by restating it here.
        self.body = GmailMessage.previewBody(body: pitch, signature: signature)
        let trimmed = (prospect.draftSubject ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        subject = trimmed.isEmpty ? "(no subject)" : trimmed
        title = SendConfirmCopy.title
        reassurance = SendConfirmCopy.reassurance
    }

    // #948: a follow-up nudge to one contact. Subject and body come from FollowUp.nudgeContent, the same
    // source SendService.sendFollowUp sends, so the sheet shows exactly what will go out.
    @MainActor
    init?(followUpFor recipient: Recipient, of prospect: Prospect,
          signature: OutboundSignature = GmailSignatureStore.currentSignature()) {
        guard let email = recipient.email, !email.isEmpty else { return nil }
        let content = FollowUp.nudgeContent(originalSubject: prospect.draftSubject, groupName: prospect.groupName,
                                            isMerged: prospect.isMergedConcert,
                                            contactName: recipient.name, venue: prospect.venue,
                                            followUpCount: recipient.followUpCount)
        from = .danWright
        self.recipient = email
        subject = content.subject
        body = GmailMessage.previewBody(body: content.body, signature: signature)   // #2029
        title = SendConfirmCopy.followUpTitle
        reassurance = SendConfirmCopy.followUpReassurance
    }

    // #948: a conversation note (an active re-touch or a closing note) to one contact. Nil for the kinds
    // that are a prompt, not a sendable email. A closing note carries the extra reassurance clause,
    // because it does a second thing Dan must be told about.
    @MainActor
    init?(conversationNudgeFor recipient: Recipient, of prospect: Prospect, kind: ConversationReminder.Kind,
          signature: OutboundSignature = GmailSignatureStore.currentSignature()) {
        guard let email = recipient.email, !email.isEmpty,
              let content = ConversationReminder.nudgeContent(kind: kind, originalSubject: prospect.draftSubject,
                                                              groupName: prospect.groupName,
                                                              isMerged: prospect.isMergedConcert,
                                                              contactName: recipient.name, venue: prospect.venue)
        else { return nil }
        from = .danWright
        self.recipient = email
        subject = content.subject
        body = GmailMessage.previewBody(body: content.body, signature: signature)   // #2029
        title = SendConfirmCopy.noteTitle
        reassurance = content.isClosing ? SendConfirmCopy.noteReassuranceClosing : SendConfirmCopy.noteReassurance
    }
}
