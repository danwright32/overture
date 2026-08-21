import Foundation

// #2128: everything the reply panel decides, out of the view where nothing could test it.
//
// Dan answers a reply from the Reached out queue now, not the Archive: "archive is only for things that
// are done and that I can't pitch/respond to anymore" (2026-08-05). He types the words himself; the AI
// drafter is a control he may press, never the default.
enum ReplyPanel {
    // Whether this row can open the panel at all. Asked of the row the LIST stands on, which may be a
    // colleague who never wrote, so it resolves to the peer who did before answering.
    // #2711: and only where there is somewhere to answer TO. A reply Dan recorded by hand can sit on a DM
    // contact that has no address at all, and this panel's only outcome is an email: `sendReplyDraft`
    // guards on `recipient.email` and would refuse, so the button would open a compose box that can never
    // send (L109). The conversation is still live and the row still says so; it is answered inside
    // whatever app it arrived in.
    static func isOffered(for recipient: Recipient, in prospect: Prospect) -> Bool {
        let answerer = ReplyIdentity.answering(for: recipient, in: prospect)
        guard answerer.email?.isEmpty == false else { return false }
        return answerer.hasUnhandledReply
    }

    // What they actually wrote, or nil when nothing was captured: a reply detected before the words were
    // stored, or one written by somebody nobody was emailed at, whose text is deliberately not filed
    // under a contact who did not say it. The panel says so rather than showing an empty quote (L10).
    // #2145: over the seam both entities already conform to, so one screen can answer either. Reads only
    // protocol members, which is why it generalises at all.
    static func theirWords(_ recipient: any ReplyWatchableRecipient) -> String? {
        guard let text = recipient.lastReplyText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    // #2143: what the compose box opens holding, which is the draft already sitting on this contact.
    // The panel used to open on a hard-coded empty string, so a draft Dan had asked for was invisible on
    // the only surface he uses, and typing over it and sending threw it away (L5).
    //
    // Hand-written stays the default: a contact with nothing drafted still opens on an empty box.
    static func openingBody(_ recipient: Recipient) -> String {
        guard let draft = recipient.replyDraftBody,
              !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        return draft
    }

    // #2143: whether an AI draft is on its way for THIS reply, so the panel can show a live run rather
    // than closing itself and leaving the button's effect nowhere on screen.
    //
    // Guarded against a stale stamp: recordAnswerSent consumes the draft body and leaves
    // replyDraftRequestedAt standing, so a request belonging to an exchange already answered would
    // otherwise read as a run that is drafting right now (L68).
    //
    // #2966: that guard was written HERE and nowhere else, and the same question was asked in two other
    // bodies without it (`Recipient.isReplyDraftStalled`, `RecipientSnapshot.isDraftingReply`). The
    // conditions now live in `ReplyDraftRequest` and all three read them, so a guard added to one of them
    // again cannot leave the others behind (L16, L30).
    static func isDrafting(_ recipient: Recipient) -> Bool {
        recipient.awaitedReplyDraftRequestedAt != nil
    }

    // #2143: a draft landing while the panel is open. Three outcomes, because Dan's own words and an
    // empty box are not the same situation and neither is nothing having arrived.
    enum ArrivingDraft: Equatable {
        case ignore
        // Nothing of his would be lost, so the draft he pressed for simply appears.
        case adopt(String)
        // He has typed since. Offered, never imposed: overwriting what somebody is in the middle of
        // writing is the one outcome that cannot be undone by reading the screen.
        case offer(String)
    }

    // #2143: the compose box's whole state, so what a landing draft does to it is decided here and the
    // view only assigns.
    struct ComposeState: Equatable {
        var typed: String
        // The last text the box was GIVEN, which is how a later draft tells his words from words it
        // handed him and he left alone.
        var seeded: String
        var offered: String?
    }

    static func applying(_ arrival: ArrivingDraft, to state: ComposeState) -> ComposeState {
        switch arrival {
        case .ignore:
            // Including an offer already standing: it waits for his answer rather than being withdrawn
            // by an unrelated write to the contact.
            return state
        case .adopt(let draft):
            return ComposeState(typed: draft, seeded: draft, offered: nil)
        case .offer(let draft):
            // His words are untouched. Only the offer beside them is new.
            return ComposeState(typed: state.typed, seeded: state.seeded, offered: draft)
        }
    }

    // He pressed the offer, which is the only thing that may replace what he wrote.
    static func taking(_ state: ComposeState) -> ComposeState {
        guard let draft = state.offered else { return state }
        return ComposeState(typed: draft, seeded: draft, offered: nil)
    }

    // #2177: whose words are in the compose box, when saying so adds something.
    //
    // Since #2143 the panel opens on the draft already waiting on the contact. Pressing "Draft with AI"
    // himself is unambiguous: he asked for it and here it is. A draft from the unattended classify run is
    // not: he opens the panel and finds text in a box he left empty, with nothing saying who wrote it. The
    // panel is where he decides what to send, and words he takes for his own get read differently from
    // words he knows a model wrote, which is the whole reason the reply lint exists.
    //
    // Said in exactly ONE state, because the panel is already dense (audience rows, their reply, the box, a
    // refusal line, a drafting line) and another always-on line is the restatement #843 was about. "Written
    // by you" over words he just typed tells him nothing.
    //
    // `typed == seeded` is what makes it withdraw itself as he types: `seeded` is the last text the box was
    // GIVEN, so the moment he changes anything the box is no longer holding the model's words.
    static func draftAuthorNote(typed: String, seeded: String,
                                writtenByDan: Bool, editedByDan: Bool) -> String? {
        guard !writtenByDan, !editedByDan else { return nil }
        guard !seeded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard typed == seeded else { return nil }
        return ReplyPanelCopy.aiWroteThisDraft
    }

    static func arriving(draft: String?, typed: String, seeded: String) -> ArrivingDraft {
        guard let draft, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .ignore }
        guard draft != typed else { return .ignore }   // already what the box holds; nothing to say
        // Whitespace is not words to protect, and neither is text he has not touched since it was put
        // there for him.
        let untouched = typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || typed == seeded
        return untouched ? .adopt(draft) : .offer(draft)
    }

    // #2149: WHY there are no words, which is two different states and needs two different sentences.
    // Overture has read the thread and found nothing it could decode (an image or an attachment), or it
    // has not looked yet. Saying "didn't capture" of a message it read and could not understand claims
    // something its own check never measured (L11). Nil when the words are there and nothing needs saying.
    // #2145: and a THIRD state, which only exists once an inquiry uses this surface. Dan answers a hire
    // inquiry he logged by hand before anything has been sent or received, so there is no inbound message
    // and no Gmail thread to point at. Both sentences above would claim a message exists, and one of them
    // would name a place it is not (L11). Nothing is missing here, so nothing is said.
    // #2711: and a FOURTH, which is the one this sentence set exists to keep honest. Dan told Overture a
    // reply arrived on a channel it cannot watch, so there is no message anywhere: both sentences above
    // would claim one exists and send him hunting in Gmail for something that was never there (L11).
    // #2715: this conversation was LINKED by hand, not started by Overture.
    //
    // Without saying so the panel reads exactly as it does on a row Overture emailed, and the difference
    // matters: Overture has sent nothing here, so it has no message to thread a new one off and the
    // follow-up and closing-note paths refuse (`AttachedConversation`). Nil on a row Overture did email,
    // so an ordinary conversation gains no sentence it does not need (#843).
    //
    // Reads `conversationAttachedAt` rather than `replyWatchConversationIsAttached`, and that is the
    // point of the two being separate: the predicate is deliberately self-healing and stops being true
    // the moment Overture's own reply lands on the thread, while the fact that a person made this link
    // by hand is permanent and is what this line is about.
    static func linkedByHandLine(for recipient: Recipient) -> String? {
        guard recipient.conversationAttachedAt != nil else { return nil }
        return AttachConversationWriteCopy.linkedByHand
    }

    static func missingWordsReason(_ recipient: any ReplyWatchableRecipient) -> String? {
        guard theirWords(recipient) == nil else { return nil }
        guard hasReceivedAnything(recipient) else { return nil }
        if (recipient as? Recipient)?.replyMarkedByHandAt != nil {
            return ReplyPanelCopy.markedByHandHasNoWords
        }
        return recipient.replyTextCheckedAt == nil
            ? ReplyPanelCopy.noCapturedWords
            : ReplyPanelCopy.unreadableWords
    }

    // Whether anybody has ever written TO Dan here. Every piece of evidence counts, deliberately, because
    // each one alone is enough to prove a message arrived and no single one is present on every row:
    //   replied              the flag detection raises, which is set without a stamp on some rows
    //   repliedAt            when it arrived; survives an answer, which CLEARS the flag above
    //                        (InquiryReplySender.sendReply), so the flag alone would forget a conversation
    //                        Dan has already answered
    //   inboundReplySentAt   when they sent it, captured with the text
    //   replyTextCheckedAt   the repair pass looked, and it only ever looks at a thread holding a message
    // A hire inquiry Dan logged by hand and has not answered carries none of them, which is the one state
    // this exists to name.
    static func hasReceivedAnything(_ recipient: any ReplyWatchableRecipient) -> Bool {
        recipient.replied
            || recipient.repliedAt != nil
            || recipient.inboundReplySentAt != nil
            || recipient.replyTextCheckedAt != nil
    }

    // #2145: what the screen is doing, and since when.
    //
    // The instant is carried BY the phase rather than read at render time. An elapsed counter anchored on
    // "now" restarts on every redraw, so it measures the time since the last thing changed on screen
    // instead of the time since the work began, and the stall timeout it feeds can never be reached: a
    // send that hung forever reads as one that just started (L74).
    enum SendPhase: Equatable {
        case composing
        // Building what Dan is about to approve (fetching the signature the send will compose on).
        // Nothing has left, and he has not yet seen what he would be approving.
        case preparing(since: Date)
        // He approved it and the mail is going.
        case sending(since: Date)
        case failed(String)

        var startedAt: Date? {
            switch self {
            case .preparing(let since), .sending(let since): return since
            case .composing, .failed: return nil
            }
        }

        // Each running state says what IT is doing. Two different acts under one word would tell him a
        // message had gone while it was still being assembled (L11, L12).
        var runningLabel: String? {
            switch self {
            case .preparing: return ReplyPanelCopy.preparing
            case .sending: return ReplyPanelCopy.sending
            case .composing, .failed: return nil
            }
        }

        // Cancel is refused only once the mail is actually going. Dismissing then would take the screen
        // down with the outcome still to come, so a send that failed would look exactly like one that
        // worked, and the words he typed would go with it (L12, L44).
        var allowsCancel: Bool {
            if case .sending = self { return false }
            return true
        }

        // His words stay on screen in every state. The failure sentence promises his reply is still here,
        // and that has to be true of the screen and not only of a variable (L11).
        var showsComposeBox: Bool { true }

        // Frozen only while the mail is going, so an edit cannot land on words already handed to Gmail.
        // A failure is the state he is meant to fix and retry from, so it stays editable.
        var freezesComposeBox: Bool {
            if case .sending = self { return true }
            return false
        }

        var failure: String? {
            if case .failed(let message) = self { return message }
            return nil
        }
    }

    // #2152: WHY the send is refused, as a value. The disabled button and the sentence beside it are then
    // one decision asked once, so they cannot drift into a dead button sitting next to a line claiming
    // everything is fine (L16, L70).
    enum SendRefusal: Equatable {
        // #2796: the conversation was LINKED by hand and Overture has nothing to hang a message off, so
        // anything it sent would arrive in a stranger's thread with no parent. It carries its sentence
        // rather than being spelled again here, because the sentence and the predicate come from one
        // function in `AttachedConversation` and naming the show is what makes it actionable (L80, L109).
        case cannotContinue(String)
        case gmailDisconnected
        case noAudience
        // The address that wrote, and the addresses the answer would actually reach, carried together
        // because the mismatch BETWEEN them is the reason and neither half states it alone.
        case writerNotReached(writer: String, audience: [String])
        // #2145: an entity whose subject Dan types (an inquiry) can have it emptied. A show answers into a
        // Gmail thread that already has a subject, so this can never fire for one.
        case noSubject
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
    // #2145: `subject` is nil for an entity with no editable subject (a show answers into a Gmail thread
    // that already has one), which is a different thing from an empty subject somebody can fix. Refusing
    // on it HERE rather than in the view is what stops an inquiry losing the check it has today: the mail
    // cannot be built without a subject, so without this the send would be allowed, fail at the wire, and
    // report a failure for something the app knew was impossible before he pressed (L67).
    //
    // It sits below the writer mismatch and above the empty body, following the screen: the subject field
    // is above the box, and both are things Dan can see for himself.
    static func refusal(body: String, subject: String?, audience: [String], gmailConnected: Bool,
                        writer: String?) -> SendRefusal? {
        guard gmailConnected else { return .gmailDisconnected }
        guard !audience.isEmpty else { return .noAudience }
        if let writer, !writer.isEmpty,
           !audience.contains(where: { ReplyDetection.isSameAddress($0, writer) }) {
            return .writerNotReached(writer: writer, audience: audience)
        }
        if let subject, subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .noSubject
        }
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .nothingTyped }
        return nil
    }

    static func canSend(body: String, subject: String?, audience: [String], gmailConnected: Bool,
                        writer: String?) -> Bool {
        refusal(body: body, subject: subject, audience: audience, gmailConnected: gmailConnected, writer: writer) == nil
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
    // #2149: a message Overture DID read and could not decode, which is a different thing and gets
    // different words. It names the likely cause, because that is what tells Dan the answer is in Gmail
    // rather than that something is broken, and Overture will not keep trying this one.
    static let unreadableWords =
        "Overture couldn't read this message, which usually means it's an image or an attachment. Open it in Gmail."
    // #2711: a reply Dan recorded by hand, which arrived somewhere Overture cannot see. Points at nothing,
    // because there is nothing to point at: naming Gmail here would send him looking for a message that
    // never existed.
    static let markedByHandHasNoWords =
        "You told Overture they replied. Their message isn't here, because it didn't come by email."
    // #2145: getting the message ready for him to approve, which is NOT sending it. Nothing has left at
    // this point and he has not yet seen what he would be approving, so calling it "Sending" would claim
    // an act that has not happened (L12).
    static let preparing = "Getting your reply ready"
    // #2154: the two things Dan can do about Overture's guess, beside the message it was read from. The
    // same words the queue row has always used for them, since they are the same two acts.
    static let confirmGuess = "Confirm"
    static let changeGuess = "Change"
    static let draftWithAI = "Draft with AI"
    // #2177: whose words are in the compose box, said only in the state where it adds something. The
    // Archive card names the same three states through `RecipientSnapshot.replyAuthorLabel` ("Written by
    // you", "Edited", and nothing at all for a draft straight from the drafter), and this is the third one
    // said out loud, in that vocabulary rather than a second one. The card can stay silent on it because
    // its drafting trace sits beside it; the panel is where Dan decides what to send, and a box he left
    // empty that now holds text needs to say who filled it. The other two stay unsaid here: "Written by
    // you" on words he just typed tells him nothing (#843).
    static let aiWroteThisDraft = "Written by AI"
    // #2143: the run the button starts, named where Dan is watching for it. The same words the Archive
    // card's own drafting line uses, shared rather than spelled twice, so the two surfaces cannot drift.
    static let drafting = "Drafting a reply"
    static let draftWithAIHelp = "Write a first draft of this one reply, which you can then edit"
    // #2143: a draft came back while Dan was writing his own. States what happened and nothing else: what
    // it would do to his words is the button's job to say, not this line's.
    static let draftArrivedWhileWriting = "An AI draft came back while you were writing."
    static let useTheDraft = "Use it instead"
    static let useTheDraftHelp = "Replace what you've written here with the AI's draft"

    // #2876: shared with the other two surfaces that open the send review, rather than a fourth copy of
    // the same rule about what that button may claim.
    static let send = SendConfirmCopy.openReview
    static let sending = "Sending"
    static let cancel = "Cancel"
    static let sendHelp = SendConfirmCopy.openReviewHelp("reply")

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
    // #2145: the promise that his words survived is now the SCREEN's job, not this sentence's. The box
    // stays visible through a failure with his reply in it, so a clause saying so restates what he is
    // looking at, and a line that only repeats the screen stops being read (#843).
    static let sendFailed = "That didn't send. You can try again."
    // #2145: the step BEFORE the send could not be completed, so nothing was ever put in front of him to
    // approve. Named as its own failure rather than dropping back to the compose box unchanged, which is
    // a button that does nothing and says nothing (L67).
    static let couldNotPrepare = "Overture couldn't get this reply ready to send."

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
        // #2145: an empty subject joins them, for exactly the reason an empty box is on this list. The
        // field is on screen directly above, and he is looking at it.
        case nil, .nothingTyped, .noAudience, .noSubject:
            return nil
        // #2796: said on screen, because this is the one refusal on this panel Dan cannot work out by
        // looking at it. Nothing about a linked conversation is visible from the compose box, and the
        // remedy is somewhere else entirely, so a silent disabled button would leave him pressing it.
        case .cannotContinue(let reason):
            return reason
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
