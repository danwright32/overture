import Foundation

// The exact thing Dan sees before a manual send goes out (#49): the recipient and
// subject of the one email about to send. Built from the performance's NEXT pending
// recipient (same source as SendService.sendOne), so the confirm step can never appear
// for an email that wouldn't actually go, and a fully-sent show yields nil (no
// duplicate send). For a multi-recipient show each click confirms the next address.
// #2017: one contact the pitch could go to, as the send sheet offers it. A held contact is OFFERED but
// never tickable: leaving it out of the list would quietly under-report who is on the show, and letting it
// be ticked would let a guard be clicked past (#2015, #2052).
struct SendCandidate: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let email: String
    let isHeld: Bool
}

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
    // #2017: every contact this show could send to, and the ones currently ticked. The selection starts as
    // exactly what pressing Send would have done anyway, so the picker only ever offers a way OFF the
    // default rather than quietly changing it.
    var candidates: [SendCandidate] = []
    var selected: [String] = []
    // The event's own together-or-separately choice as it stands when the sheet opens, so the sheet's
    // control starts where the card left it rather than at a default of its own.
    var togetherAtOpen: Bool = true

    // The main draft send: the show's next pending recipient over the shared draft body.
    //
    // #2050: `approving` is the one caller that legitimately asks who a draft would reach BEFORE it is
    // approved, because opening this sheet is now the approval. Dan: "as soon as I click approve I should
    // get a confirmation that I want to send it and go straight through that action." It defaults to
    // false, so #2015's guard is untouched for every other caller: a card may still not name the people
    // an unapproved draft would reach. The two groups differ only by that gate (`pendingGroup` IS
    // `previewGroup` plus it), and the approval happens in the same action as the send, so what this sheet
    // names cannot differ from who receives it (L64).
    // #2017: `selecting` names the contacts Dan has ticked, so the To line, the body preview and the
    // promise underneath it all describe THAT selection rather than the default one. Nil means he has not
    // touched the ticks, which is the default the sheet opens on.
    @MainActor
    init?(prospect: Prospect, approving: Bool = false, selecting: [String]? = nil,
          signature: OutboundSignature = GmailSignatureStore.currentSignature()) {
        // #2033: the whole group the next press of Send reaches, from the one definition the send itself
        // reads, so what he approves names everybody it is going to (L64).
        let defaultGroup = approving && prospect.status == .drafted && prospect.draftBody != nil
            ? SendGroup.previewGroup(of: prospect)
            : SendGroup.pendingGroup(of: prospect)
        // A ticked contact must still clear every guard: `sendableFor` filters to the ones that could
        // actually go, so a held contact cannot be talked past by being named here (#2052).
        let group = selecting.map { SendGroup.sendableFor(prospect, ids: $0) } ?? defaultGroup
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
        // #2017: follows the ticks AND the together-or-separately choice, both changeable on this sheet.
        reassurance = SendConfirmCopy.reassurance(chosen: group.count, together: prospect.sendsTogether)
        candidates = SendGroup.candidates(of: prospect)
        selected = group.map(\.id)
        togetherAtOpen = prospect.sendsTogether
    }

    // #2144: a REPLY, which until now was the one consequential send with no confirmation at all. The
    // signature is composed on at the send layer, so a panel showing only Dan's typed words is not showing
    // the artifact that lands in the inbox, and that is precisely the gap that shipped a hard white
    // outline box to every dark-mode recipient for two weeks (#2086, L69).
    //
    // Carries the body and signature as INGREDIENTS like every other confirmation, so the sheet renders
    // the same document the wire builds rather than a second composition that can drift, and takes its
    // audience and subject from the same two helpers the sender asks (L64).
    // #2145: the same reply confirmation, built from what a reply IS (who it reaches, what it is called,
    // what it says) rather than from what kind of thing is being answered. An inquiry has no Prospect
    // anywhere near it and needs this sheet for exactly the reason a show does: the signature is composed
    // at the send layer onto every outgoing mail, so without a confirmation it goes out having been read
    // by nobody (L69, the two weeks of #2086).
    //
    // Takes an audience and a subject already DECIDED, so it cannot hold an opinion that differs from the
    // rule which decided the send was allowed at all (L16, L70).
    @MainActor
    init?(replyTo audience: [String], subject: String, body: String,
          signature: OutboundSignature = GmailSignatureStore.currentSignature()) {
        // Nothing to send is nothing to confirm. The subject is guarded here as well as at the refusal,
        // because the mail itself cannot be built without one, so a sheet promising to send it would be
        // promising something impossible (L67).
        guard !audience.isEmpty,
              !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        from = .danWright
        recipient = audience.joined(separator: ", ")
        self.subject = subject
        bodyBeforeSignOff = body
        self.signature = signature
        title = SendConfirmCopy.replyTitle
        // A reply always goes as ONE email to everybody it mirrors, so the promise counts them rather than
        // offering the together-or-separately choice a first pitch has.
        reassurance = SendConfirmCopy.reassurance(chosen: audience.count, together: true)
    }

    @MainActor
    // #2145: the show's own reply, now only a LOOKUP of the two things the shared initializer above takes.
    // Kept as its own entry point because the lookup is genuinely Prospect-shaped (the subject is derived
    // from the show's draft subject and its merged-concert name), while the composition it feeds is not.
    init?(replyFor recipient: Recipient, of prospect: Prospect, body: String,
          signature: OutboundSignature = GmailSignatureStore.currentSignature()) {
        self.init(replyTo: SendGroup.replyAudience(of: recipient),
                  subject: SendService.replySubject(for: recipient, of: prospect),
                  body: body, signature: signature)
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

    // #2710: `init?(closingNoteFor:of:signature:)` stood here and is gone with the email it confirmed.
    // The last thing Overture sends a contact who has not written back is the final follow-up; after the
    // show there is nothing to approve, only an ending for Dan to record.
}
