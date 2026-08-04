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
    // #2053: the message body WITHOUT the sign-off, and the signature it will be composed with, instead
    // of one already-composed string. An outgoing email has TWO parts whenever a styled signature is
    // stored (GmailMessage.rfc822 builds multipart/alternative), and a mail client displays the HTML one,
    // so a preview holding only the plain-text composition can only ever show the fallback. Carrying the
    // ingredients lets the sheet render the same styled document the draft card renders, through the same
    // helper, so the two screens cannot disagree about one email.
    //
    // Dan: "I see my signature here but if I click send it disappears and does a plain text signature?
    // that violates my rule of what I see on screen should be what's sent."
    let bodyBeforeSignOff: String
    let signature: OutboundSignature
    // The text/plain part, still exactly what the send path hands Gmail, composed the one way rather than
    // stored beside its ingredients where the two could drift.
    var body: String { GmailMessage.previewBody(body: bodyBeforeSignOff, signature: signature) }
    let title: String
    let reassurance: String
    // #1219: set when a DIFFERENT show has already been emailed on this performance's date, so the send
    // sheet warns of a self double-booking at the committing moment and Dan confirms past it deliberately
    // (a blank warning means no collision). Set by the caller, which has the whole queue to compare.
    var selfBookingWarning: String? = nil

    // The main draft send: the show's next pending recipient over the shared draft body.
    //
    // #2050: `approving` is the one caller that legitimately asks who a draft would reach BEFORE it is
    // approved, because opening this sheet is now the approval. Dan: "as soon as I click approve I should
    // get a confirmation that I want to send it and go straight through that action." It defaults to
    // false, so #2015's guard is untouched for every other caller: a card may still not name the people
    // an unapproved draft would reach. The two groups differ only by that gate (`pendingGroup` IS
    // `previewGroup` plus it), and the approval happens in the same action as the send, so what this sheet
    // names cannot differ from who receives it (L64).
    @MainActor
    init?(prospect: Prospect, approving: Bool = false,
          signature: OutboundSignature = GmailSignatureStore.currentSignature()) {
        // #2033: the whole group the next press of Send reaches, from the one definition the send itself
        // reads, so what he approves names everybody it is going to (L64).
        let group = approving && prospect.status == .drafted && prospect.draftBody != nil
            ? SendGroup.previewGroup(of: prospect)
            : SendGroup.pendingGroup(of: prospect)
        // #2052: no sheet at all for a draft with no subject line, where this used to render
        // "(no subject)" beside a live Send button. The placeholder was itself the detection that the
        // value was missing, so it had to stop the send rather than label it (L67). Dan, on finding it:
        // "There's no subject shown and if I click send it doesn't create a subject." The show is already
        // unsendable by then (Recipient.isSendablePending), so `group` is empty and this returns nil; the
        // explicit condition is kept so this can never come back by a route that skips the group.
        let subjectLine = (prospect.draftSubject ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !subjectLine.isEmpty,
              let next = group.first,
              let email = next.email, !email.isEmpty,
              let body = prospect.draftBody, !body.isEmpty,
              // #2029: composed by the SAME helper the send path uses, for the SAME recipient, so the
              // preview cannot show a different email from the one that goes out. `nil` here is the same
              // condition that stops a send, so a sheet can still never appear for an email that would not
              // actually leave.
              let pitch = group.count > 1
                ? OutgoingPitch.text(forGroup: group, of: prospect)
                : OutgoingPitch.text(for: next, of: prospect) else { return nil }
        from = .danWright
        recipient = group.compactMap(\.email).filter { !$0.isEmpty }.joined(separator: ", ")
        // #2029: the sign-off rides along for the same reason the email carries it (GmailMessage appends
        // it at the send layer) rather than by being restated here. #2053: as the two ingredients, so the
        // sheet can compose either part of the message it needs.
        bodyBeforeSignOff = pitch
        self.signature = signature
        subject = subjectLine
        title = SendConfirmCopy.title
        // The reassurance is a promise about what this press does. "To this recipient only" is a false
        // promise on an email reaching two people, so a group gets its own, naming how many.
        reassurance = group.count > 1
            ? SendConfirmCopy.reassuranceForSeveral(group.count)
            : SendConfirmCopy.reassurance
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
        bodyBeforeSignOff = content.body                                       // #2029, #2053
        self.signature = signature
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
        bodyBeforeSignOff = content.body                                       // #2029, #2053
        self.signature = signature
        title = SendConfirmCopy.noteTitle
        reassurance = content.isClosing ? SendConfirmCopy.noteReassuranceClosing : SendConfirmCopy.noteReassurance
    }
}
