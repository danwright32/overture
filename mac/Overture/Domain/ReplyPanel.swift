import Foundation

// #2128: everything the reply panel decides, out of the view where nothing could test it.
//
// Dan answers a reply from the Reached out queue now, not the Archive: "archive is only for things that
// are done and that I can't pitch/respond to anymore" (2026-08-05). He types the words himself; the AI
// drafter is a control he may press, never the default.
enum ReplyPanel {
    // Whether this row can open the panel at all. Asked of the row the LIST stands on, which may be a
    // colleague who never wrote, so it resolves to the peer who did before answering.
    static func isOffered(for recipient: Recipient, in prospect: Prospect) -> Bool {
        ReplyIdentity.answering(for: recipient, in: prospect).hasUnhandledReply
    }

    // What they actually wrote, or nil when nothing was captured: a reply detected before the words were
    // stored, or one written by somebody nobody was emailed at, whose text is deliberately not filed
    // under a contact who did not say it. The panel says so rather than showing an empty quote (L10).
    static func theirWords(_ recipient: Recipient) -> String? {
        guard let text = recipient.lastReplyText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    // #2152: WHY the send is refused, as a value. The disabled button and the sentence beside it are then
    // one decision asked once, so they cannot drift into a dead button sitting next to a line claiming
    // everything is fine (L16, L70).
    enum SendRefusal: Equatable {
        case gmailDisconnected
        case noAudience
        // The address that wrote, and the addresses the answer would actually reach, carried together
        // because the mismatch BETWEEN them is the reason and neither half states it alone.
        case writerNotReached(writer: String, audience: [String])
        case nothingTyped
    }

    // The send is refused, never merely discouraged, on each of the four things that make it impossible:
    // no Gmail, nobody to send to, an answer that would miss whoever wrote, nothing typed. Refusing here
    // means the button is honest at rest, instead of failing at the network and reporting an error Dan
    // can do nothing about (L67).
    // #2147: `writer` is the address that actually wrote, when it is known. If the answer would not reach
    // them, the send is REFUSED rather than delivered to whoever the row happens to stand on. Substituting
    // a nearby contact looks exactly like success and emails somebody else (L75). A row with no recorded
    // writer is not blocked: answering the contact it was sent to is the best that is known about it.
    //
    // Order is what Dan needs to hear first, not what is cheapest to check: the writer mismatch outranks
    // an empty box, because the empty box is the one thing on this panel he can already see for himself.
    static func refusal(body: String, audience: [String], gmailConnected: Bool,
                        writer: String?) -> SendRefusal? {
        guard gmailConnected else { return .gmailDisconnected }
        guard !audience.isEmpty else { return .noAudience }
        if let writer, !writer.isEmpty,
           !audience.contains(where: { ReplyDetection.isSameAddress($0, writer) }) {
            return .writerNotReached(writer: writer, audience: audience)
        }
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .nothingTyped }
        return nil
    }

    static func canSend(body: String, audience: [String], gmailConnected: Bool, writer: String?) -> Bool {
        refusal(body: body, audience: audience, gmailConnected: gmailConnected, writer: writer) == nil
    }

    // The panel's send, out of the view so the sequence and its failure path can be tested.
    //
    // Dan's words are written to the recipient BEFORE the send, deliberately: a send that fails then
    // leaves them stored rather than only in a text box the panel is about to redraw, so "your reply is
    // still here" is true of the data and not just of the screen (L5). Returns whether it actually went,
    // never true on a failure, so the panel cannot show success over a send that did not happen (L12).
    @MainActor
    static func commit(body: String, on recipient: Recipient, of prospect: Prospect,
                       now: Date, sender: MailSender) async -> Bool {
        recipient.applyReplyDraftEdit(body)
        return await SendService.sendReplyDraft(recipient, of: prospect, now: now, sender: sender)
    }

    // L64: what Dan approves has to include WHO it reaches. The panel lists the audience in full rather
    // than only naming the extras the way a card does, because this is the surface the send is approved
    // from and the audience of a reply is routinely not the audience of the original email.
    //
    // #2155, Dan on the live Pumpkin Singalong panel: "it's also not clear which email sent the message
    // I'm reading". Three addresses ran together in one sentence, so the approval surface said LESS about
    // who he was answering than the queue row he opened it from, which has marked the writer since #2113.
    struct AudienceEntry: Equatable, Identifiable {
        let address: String
        // The one who actually wrote. Marked rather than reordered: the audience mirrors how the message
        // was addressed, and shuffling it would misrepresent the reply Dan is answering.
        let wrote: Bool
        // False only for the last one standing. An empty audience is not "send to nobody": SendGroup
        // falls back to the contact's own address, so emptying it would quietly deliver the reply to
        // somebody Dan had just taken off it, which looks exactly like success (L75).
        let canRemove: Bool
        var id: String { address }
    }

    static func audienceEntries(_ addresses: [String], writer: String?) -> [AudienceEntry] {
        addresses.map { address in
            AudienceEntry(address: address,
                          // Compared the way reply detection compares, so a difference in casing between
                          // the thread and the stored writer cannot unmark the one person this identifies.
                          wrote: writer.map { ReplyDetection.isSameAddress(address, $0) } ?? false,
                          canRemove: addresses.count > 1)
        }
    }

    // The audience with one address taken off, or unchanged when it is the last one. The refusal to empty
    // it lives HERE rather than only in the control, so a caller reaching this another way cannot do what
    // the button is hidden to prevent.
    static func removing(_ address: String, from addresses: [String]) -> [String] {
        guard addresses.count > 1 else { return addresses }
        return addresses.filter { !ReplyDetection.isSameAddress($0, address) }
    }

    // Taking somebody off a reply, Dan's way (2026-08-05): "drop it entirely. just like it would in a real
    // email client. if they want to add it back they can." So it comes off THIS reply and the show stops
    // using that contact, in one action, with no dialog.
    //
    // The contact half goes through Prospect.removeOrSuppressRecipient, the same call the card's own
    // Remove makes, rather than a second implementation of what removing a contact means. That is also
    // what makes this safe to do without a confirmation: a contact who has been emailed is SUPPRESSED
    // there, never deleted, so the pitch it received survives and re-adding the address resumes it.
    //
    // An address belonging to no contact (the writer's own, on the row that started all of this) narrows
    // the reply and touches no contact record.
    //
    // The two outcomes are distinct because they differ in a way Dan cannot see afterwards, and the banner
    // may only claim what actually happened (L11): a removal that touched no contact must not report that
    // the show stopped emailing anyone.
    enum Removal: Equatable {
        case notRemoved
        case fromReply
        case fromReplyAndShow
    }

    // #2151: the address that wrote, when this show has no contact holding it. Dan noticed the gap only
    // because the card named the wrong person; nothing said the address was new, so she stayed a stranger
    // and every future reply from her would be handled the same way again.
    //
    // Returns nil when there is nothing to say: no writer recorded (an unknown fact, not a new address),
    // or a writer who is already one of the show's contacts, which is the ordinary case.
    static func unknownWriter(on recipient: Recipient, of prospect: Prospect) -> String? {
        guard let writer = recipient.replyFromAddress, !writer.isEmpty else { return nil }
        return contact(holding: writer, of: prospect) == nil ? writer : nil
    }

    // One place that answers "does this show have a contact at this address", shared by the offer above
    // and the removal below, so the two can never disagree about what counts as a contact.
    static func contact(holding address: String, of prospect: Prospect) -> Recipient? {
        prospect.recipients.first { ReplyDetection.isSameAddress($0.email ?? "", address) }
    }

    // Saving her. A judgement only Dan can make, since the writer may genuinely be somebody else answering
    // on a colleague's behalf, so it is offered and never done for him.
    //
    // She joins the send group, which is what makes her recognised: ReplyIdentity.answering resolves a
    // writer through the group's peers, so without that the next reply from this address lands on
    // whichever contact sorts first all over again.
    //
    // And she is SUPPRESSED, deliberately. A pending contact on a show already in conversation becomes
    // sendable again the moment Dan triages the reply (resumePausedRecipients), which would put a cold
    // first-contact pitch in front of the person he is already talking to. joinedFromReply says why she is
    // here without claiming she declined or that Dan removed her.
    @MainActor
    @discardableResult
    static func saveWriterAsContact(on recipient: Recipient, of prospect: Prospect) -> Bool {
        guard let writer = unknownWriter(on: recipient, of: prospect) else { return false }
        let saved = Recipient(id: ReplyDetection.email(from: writer), email: writer,
                              name: recipient.replyFromName?.isEmpty == false ? recipient.replyFromName : nil,
                              provenance: .manual)
        saved.sendGroupId = SendGroup.groupKey(recipient)
        saved.sendState = .suppressed
        saved.suppressionReason = .joinedFromReply
        prospect.addRecipient(saved)
        return true
    }

    @MainActor
    @discardableResult
    static func removeFromReply(_ address: String, on recipient: Recipient,
                                of prospect: Prospect) -> Removal {
        let current = SendGroup.replyAudience(of: recipient)
        let left = removing(address, from: current)
        guard left != current else { return .notRemoved }
        recipient.replyAudience = left
        guard let contact = contact(holding: address, of: prospect) else { return .fromReply }
        prospect.removeOrSuppressRecipient(id: contact.id)
        return .fromReplyAndShow
    }
}

// #2128: the panel's own sentences, in a pure type so the view composes none of them (ViewCopyGuardTests)
// and so every one of them appears in the copy inventory for a cold read.
enum ReplyPanelCopy {
    static let answer = "Answer"
    static let noCapturedWords = "Overture didn't capture what they wrote. Their message is in Gmail."
    static let draftWithAI = "Draft with AI"
    static let draftWithAIHelp = "Write a first draft of this one reply, which you can then edit"
    static let send = "Send reply"
    static let sending = "Sending"
    static let cancel = "Cancel"
    static let sendHelp = "Send this reply on the thread they wrote on"

    // #2155: the audience, now one address per row so each can be marked and taken off.
    static let audienceHeading = "Your reply goes to"
    static let noAddress = "No address to reply to"
    // What this address DID, not who they are, because that is the question Dan asked of the panel: which
    // of these three sent the message he is reading.
    static let wroteThis = "wrote this"
    // Icon-only control, so the label carries the whole action and states BOTH halves of it. Saying only
    // "remove from this reply" would understate what the button does; a person cannot consent to an effect
    // the label hides (L21).
    static func removeFromReply(_ address: String) -> String {
        "Take \(address) off this reply and stop this show emailing it"
    }

    // #2151: the address that wrote is on no contact of this show. States the fact plainly; it does not
    // guess at WHY, because the two possible reasons (the same person from a second mailbox, or a
    // colleague answering on their behalf) are exactly what Dan is being asked to judge.
    static func writerNotAContact(_ address: String) -> String {
        "\(address) isn't saved as a contact on this show."
    }

    // The offer. Short, because the address it acts on is named in the line directly above it.
    static let saveWriter = "Save this address"
    static let saveWriterHelp =
        "Add this address to this show so a reply from it is recognised. It won't be pitched."
    static func savedWriter(_ address: String) -> String {
        "Saved \(address) to this show. Replies from it are recognised now, and it won't be pitched."
    }

    // What actually happened, said afterwards. The row simply vanishing left the wider half of the action
    // (the show no longer emailing that contact) with no evidence it had occurred at all, on a control
    // whose only statement of it was a tooltip nobody has to read. Each outcome gets its own sentence, so
    // the banner never claims an effect this particular removal did not have (L11), and a removal that was
    // refused says nothing rather than announcing a no-op (L12).
    static func removed(_ removal: ReplyPanel.Removal, address: String) -> String? {
        switch removal {
        case .notRemoved: return nil
        case .fromReply: return "Took \(address) off this reply."
        case .fromReplyAndShow: return "Took \(address) off this reply. This show won't email them again."
        }
    }
    // Names what happened and leaves the button available, rather than a dead spinner or a cheerful
    // pretence that it went (L12). The words stay in the box: nothing Dan typed is thrown away.
    static let sendFailed = "That didn't send. Your reply is still here, so you can try again."

    // #2152: the sentence beside a disabled Send button. A control that refuses without saying why reads
    // as broken rather than as a refusal (L11, L67), and this one fires exactly where Dan is least able
    // to work it out: a reply from an address that matches no contact on the show.
    //
    // Two of the four refusals deliberately say NOTHING here, because the panel already tells him:
    //   nothing typed  he is looking straight at his own empty box
    //   no audience    the header two lines above reads "No address to reply to", in the same red
    // Repeating either beside the button is the restatement #843 was about, and a line that is always on
    // screen stops being read at all.
    static func refusalLine(_ refusal: ReplyPanel.SendRefusal?) -> String? {
        switch refusal {
        case nil, .nothingTyped, .noAudience:
            return nil
        case .gmailDisconnected:
            // Said on screen and not only in the button's tooltip, which is invisible at rest (L49).
            return GmailCopy.notConnected
        case .writerNotReached(let writer, let audience):
            // Names both sides, since the mismatch between them is the reason. It points at Gmail rather
            // than at a control Overture does not have yet: #2151 is where adding the address to the
            // contact becomes an offer here, and promising it before then would be copy that lies (L21).
            return "\(writer) wrote, and this reply would go to \(Plural.list(audience)) instead, "
                + "so Overture won't send it. Answer this one in Gmail."
        }
    }
}
