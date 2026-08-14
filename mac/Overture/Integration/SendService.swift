import Foundation
import SwiftData

@MainActor
enum SendService {
    // A performance's recipients in deterministic send order (SwiftData to-many is unordered).
    nonisolated private static func sendOrdered(_ recipients: [Recipient]) -> [Recipient] {
        recipients.sorted {
            $0.sendOrderRank != $1.sendOrderRank ? $0.sendOrderRank < $1.sendOrderRank : $0.id < $1.id
        }
    }

    // The next recipient a manual or throttled send would target for this performance: the first
    // still-sendable one, or nil when the show is fully sent (or not sendable at all). Shared by
    // sendOne and SendConfirmation so the picker and the actual send can never disagree.
    // #2015: `nonisolated` so the QUEUE CARD can ask the same question the send asks, and the two can
    // never disagree about who is about to be emailed. It reads stored properties and decides; none of
    // the Gmail work the rest of this service does is involved.
    nonisolated static func nextPendingRecipient(for prospect: Prospect) -> Recipient? {
        guard prospect.status == .approved, prospect.draftBody != nil else { return nil }
        return sendOrdered(prospect.recipients).first(where: \.isSendablePending)
    }

    // #2033: what pressing Send does, once. It is the ONE place the together-or-separately choice is
    // acted on, so the card, the confirmation sheet and the send itself cannot disagree about who is
    // about to be emailed.
    // #2017: `to` is the contacts Dan ticked on the send sheet. Nil keeps the behavior every other caller
    // relies on (the show's own pending group), so the picker is an addition rather than a change to the
    // path that already works.
    //
    // Under "email separately" a multi-contact selection goes out as one email EACH, all now. Dan's answer,
    // 2026-08-04: "It should send all three now but also give me the option to put them all on the same
    // email", the second half of which is the together switch he can flip on the same sheet.
    @discardableResult
    static func sendNext(_ prospect: Prospect, to chosen: [Recipient]? = nil,
                         now: Date, sender: MailSender) async -> Bool {
        guard let chosen else {
            let group = SendGroup.pendingGroup(of: prospect)
            guard group.count > 1 else { return await sendOne(prospect, now: now, sender: sender) }
            return await sendJointly(prospect, to: group, now: now, sender: sender)
        }
        // Re-filtered rather than trusted: the ticks were read off a screen, and the guards decide.
        let group = SendGroup.sendableFor(prospect, ids: chosen.map(\.id))
        guard !group.isEmpty else { return false }
        guard group.count > 1 else { return await deliver(group[0], of: prospect, now: now, sender: sender) }
        guard prospect.sendsTogether else {
            // One each. Every one is attempted even if an earlier one fails, so a single bad address cannot
            // silently swallow the rest of what he ticked, and the result says whether ANY got out.
            var anySent = false
            for r in group where await deliver(r, of: prospect, now: now, sender: sender) { anySent = true }
            return anySent
        }
        return await sendJointly(prospect, to: group, now: now, sender: sender)
    }

    // Sends ONE recipient of a performance immediately, bypassing the throttle. This is the manual
    // per-draft "Send" Dan clicks (one click = one email); for a multi-recipient show each click sends
    // the next pending recipient. Manual approval is its own pacing, so no drip needed.
    @discardableResult
    static func sendOne(_ prospect: Prospect, now: Date, sender: MailSender) async -> Bool {
        guard let recipient = nextPendingRecipient(for: prospect) else { return false }
        return await deliver(recipient, of: prospect, now: now, sender: sender)
    }

    // Deliver to one recipient over the shared, salutation-free body (#393), composing that recipient's
    // own greeting at send. Stamps the recipient's send receipt/state, rolls the first send up to the
    // lead level (write-once), freezes the voice pair once (#395), and flips the show to `.contacted`
    // only when no sendable recipient remains. Records the error on the recipient for retry on failure.
    @discardableResult
    private static func deliver(_ recipient: Recipient, of prospect: Prospect,
                                now: Date, sender: MailSender) async -> Bool {
        guard let email = recipient.email, !email.isEmpty, prospect.draftBody != nil else { return false }
        // #641 (#634 Phase C): a directly-addressed performer's own second-person draft wins over the
        // shared third-person body, for BOTH the actual outgoing mail and the voice-learning snapshot
        // below (freezeSentCopy). Recipient.effectiveBody owns that choice now (#789), so the text the
        // draft lint judges is by construction the same text this sends.
        guard let effectiveBody = recipient.effectiveBody else { return false }

        // #1630: composed by OutgoingPitch, which the copy-to-a-contact-form path also reads, so the
        // text Dan pastes into a form is by construction the text this sends.
        //
        // #2030: composed BEFORE the claim below, deliberately. Both of these can refuse, and refusing
        // after the claim would leave the contact stuck at `.sending` with nothing ever sent, needing
        // Dan to resolve by hand. Nothing here writes or awaits, so there is no cost to doing it first.
        guard let pitch = OutgoingPitch.text(for: recipient, of: prospect),
              let mail = OutgoingMail(to: [email], subject: prospect.draftSubject ?? "", body: pitch)
        else { return false }

        // Claim this recipient before the network await (#475/#476). Nothing here awaits, so on the
        // MainActor this check-then-claim-then-persist is atomic with respect to any other call
        // racing the same recipient: whichever call's synchronous prefix runs first flips the state,
        // and any other call's guard sees anything but .pending and backs off immediately. Persisting
        // the claim (not just mutating in memory) before the network call means a crash between here
        // and the outcome leaves the recipient at .sending, surfaced for Dan to check Gmail and
        // resolve by hand (Recipient.isSendStuck), never silently re-queued as still-pending.
        guard recipient.sendState == .pending else { return false }
        recipient.sendState = .sending
        recipient.sendClaimedAt = now
        guard (try? recipient.modelContext?.save()) != nil else {
            // Couldn't even persist the claim: bail rather than race ahead uncertain whether a
            // concurrent caller can see it.
            recipient.sendState = .pending
            recipient.sendClaimedAt = nil
            return false
        }

        do {
            let receipt = try await sender.send(mail)
            recipient.sentAt = now
            recipient.sendState = .sent
            recipient.sendClaimedAt = nil
            recipient.gmailThreadId = receipt.threadId
            recipient.gmailMessageId = receipt.messageID
            recipient.replyTrackingDegraded = receipt.threadIdDegraded
            recipient.threadingDegraded = receipt.messageIDDegraded   // #2647
            recipient.sendError = nil
            // Lead-level first-send rollup (#389 Phase 1): set once, never overwritten, so the ~20
            // "was this performance contacted at all" readers keep working unchanged. The thread/
            // message ids also roll up from the first send so follow-up threading (#74) and reply
            // detection keep working until Phase 4 moves them to per-recipient threads.
            if prospect.sentAt == nil {
                prospect.sentAt = now
                prospect.priorRelationshipAtSend = prospect.priorRelationship
                // #4: the rest of the ranking features, frozen for the same reason and at the same
                // moment. Without this, a feedback loop would score this pitch against whatever the
                // newest scout has since written over the row.
                prospect.freezeFeaturesAtSend()
                prospect.gmailThreadId = receipt.threadId
                prospect.gmailMessageId = receipt.messageID
            }
            prospect.freezeSentCopy(subject: mail.subject, body: effectiveBody)
            prospect.sendError = nil
            // Per-click only (no autonomous drip): the show stays approved while any recipient is still
            // sendable, so the Send button persists for the next one. Once the last one goes, it is
            // contacted.
            if !prospect.recipients.contains(where: \.isSendablePending) {
                prospect.status = .contacted
            }
            return true
        } catch {
            recipient.sendState = .pending
            recipient.sendClaimedAt = nil
            recipient.sendError = error.localizedDescription
            prospect.sendError = error.localizedDescription
            return false
        }
    }

    // #468 (SUP-005): the same claim-before-await pattern deliver() uses for the primary send
    // (sendState/sendClaimedAt below), generalized over a claim field so it can guard a secondary
    // send too. The check-then-set-then-persist is synchronous (no await in between), so on the
    // MainActor a second concurrent call against the SAME claim field sees it already set and
    // backs off before ever reaching the network, instead of double-sending.
    // #2033: the same claim over a whole GROUP. A shared thread has one conversation, so a second click
    // on a different member of it is the same double-tap the single claim already refuses, and must be
    // refused for the same reason: it would put two nudges on one thread.
    private static func claimSecondarySend(_ group: [Recipient],
                                           _ claim: ReferenceWritableKeyPath<Recipient, Date?>,
                                           now: Date) -> Bool {
        guard group.allSatisfy({ $0[keyPath: claim] == nil }) else { return false }
        for r in group { r[keyPath: claim] = now }
        guard (try? group.first?.modelContext?.save()) != nil else {
            for r in group { r[keyPath: claim] = nil }
            return false
        }
        return true
    }

    private static func claimSecondarySend(_ recipient: Recipient,
                                           _ claim: ReferenceWritableKeyPath<Recipient, Date?>,
                                           now: Date) -> Bool {
        guard recipient[keyPath: claim] == nil else { return false }
        recipient[keyPath: claim] = now
        guard (try? recipient.modelContext?.save()) != nil else {
            recipient[keyPath: claim] = nil
            return false
        }
        return true
    }

    // #2575: which words actually go out. An edit REPLACES the composed body; an edit that is nothing but
    // whitespace is not a message at all and returns nil, so both send paths refuse it in one place rather
    // than each deciding what an empty box means. `SendConfirmEditing.bodyIsSendable` is the same
    // predicate the Send button is disabled by, so the button and the send cannot disagree (L109).
    private static func editedOrComposed(_ edited: String?, composed: String) -> String? {
        guard let edited else { return composed }
        return SendConfirmEditing.bodyIsSendable(edited) ? edited : nil
    }

    // Sends ONE follow-up nudge for a prospect Dan explicitly chose to re-touch (#45):
    // a short templated message to the same contact. Records the follow-up (count +
    // timestamp) on success so the sequencer paces and caps it. Never resets sentAt or
    // the original outcome; one click = one nudge, never autonomous.
    @discardableResult
    // #2575: `body`, when given, is what Dan had in the text box at the moment he pressed Send. It
    // REPLACES the composed body and nothing else: the subject still comes from the shared helper,
    // because that is what threads the message onto the conversation Gmail is watching (#74). Nil is an
    // unedited send, which composes exactly as before.
    static func sendFollowUp(_ recipient: Recipient, of prospect: Prospect, now: Date, sender: MailSender,
                             body: String? = nil,
                             config: FollowUpConfig = .init()) async -> Bool {
        // #1740: the same predicate the row and the Due count read, so a contact Dan stood down cannot be
        // nudged from any surface, including one that never asks the Due list.
        // #2033: the nudge belongs to the CONVERSATION, so it is addressed to everyone on the thread and
        // spends the cap once. The cap is read from the highest count in the group, because a cap that
        // each member counts separately can be spent twice over by clicking the other row.
        let group = SendGroup.peers(of: recipient, in: prospect)
        let spent = group.map(\.followUpCount).max() ?? recipient.followUpCount
        guard FollowUp.isAwaitingNudge(recipient, in: prospect, now: now), spent < config.maxFollowUps,
              let email = recipient.email, !email.isEmpty else { return false }
        let addresses = group.compactMap(\.email).filter { !$0.isEmpty }
        // Reply on THIS contact's conversation (#74, per-recipient #418 D): same threadId, In-Reply-To
        // the contact's last Message-ID, and a "Re:" subject, so a reply to the nudge lands on the
        // thread reply detection already watches for this contact.
        // #948: subject and body come from the one shared helper the confirmation sheet also reads, so
        // what Dan confirmed is exactly what sends.
        // #2030: built BEFORE the claim below, so a message that cannot be built never leaves the claim
        // held on a nudge that was never sent.
        let content = FollowUp.nudgeContent(originalSubject: prospect.draftSubject, groupName: prospect.groupName,
                                            isMerged: prospect.isMergedConcert,
                                            contactName: recipient.name, venue: prospect.venue,
                                            followUpCount: recipient.followUpCount)
        // #2575: an emptied box is not a message, and refusing it HERE (rather than only at the button)
        // means no other caller can mail a signature with nothing above it under Dan's name.
        guard let outgoing = editedOrComposed(body, composed: content.body) else { return false }
        // #2648: the whole ancestry, not the parent restated. Built through the one shared helper the
        // closing note and the reply draft also use, so the three reply paths cannot disagree about what
        // the chain is.
        let chain = MailThreading.references(parentReferences: recipient.gmailReferences,
                                             parentMessageID: recipient.gmailMessageId)
        guard let mail = OutgoingMail(
            to: addresses,
            subject: content.subject,
            body: outgoing,
            inReplyTo: recipient.gmailMessageId,
            references: chain,
            threadId: recipient.gmailThreadId) else { return false }
        // #468: shared with sendConversationNudge's claim below (mutually exclusive by domain
        // state, see the field's doc comment on Recipient), so a fast double-tap on either one
        // is refused rather than reaching the network twice. #2033: over the whole group.
        guard claimSecondarySend(group, \.nudgeSendClaimedAt, now: now) else { return false }
        do {
            let receipt = try await sender.send(mail)
            // Every member records the nudge, so the cap reads the same from whichever row Dan clicks
            // next and no member looks un-nudged on a thread that was nudged.
            for r in group {
                r.followUpCount = spent + 1
                r.lastFollowUpAt = now
                // #2648: the id and the chain move TOGETHER or not at all. The chain is the ancestry of
                // whichever message `gmailMessageId` names, so advancing one without the other would emit
                // a References that skips a generation.
                if let m = receipt.messageID {
                    r.gmailMessageId = m           // thread the next reply off the nudge
                    r.gmailReferences = chain
                }
                // #2647: when the nudge's own Message-ID could not be read back, the PRIOR id above is
                // kept rather than blanked. It is a real ancestor of the conversation, so referencing it
                // still threads in every client; blanking it would turn the next message into an
                // unthreaded one, which is a worse defect than a stale reference (L5).
                r.threadingDegraded = receipt.messageIDDegraded
                r.sendError = nil
                r.nudgeSendClaimedAt = nil
            }
            return true
        } catch {
            for r in group {
                r.sendError = error.localizedDescription
                r.nudgeSendClaimedAt = nil   // retryable, never stuck claimed
            }
            return false
        }
    }

    // Sends ONE conversation re-touch or closing note for a specific recipient's ACTIVE conversation
    // (#651/#652), not the lead-level rollup: threads on recipient.gmailMessageId/gmailThreadId (that
    // contact's own conversation), same as sendReplyDraft, so a multi-recipient show's nudge lands on
    // the RIGHT contact instead of whichever recipient sent first. The closing variant resolves ONLY
    // this recipient (markOutcomeManually, mirroring what resolveEngagedContacts does per engaged
    // contact) with no cascade to a sibling recipient or the show's own outcome (Dan's 2026-07-08
    // decision, already locked in on Recipient.setConversationState). Re-anchors this recipient's own
    // reminder clock. One click = one nudge, never autonomous.
    @discardableResult
    // #2575: `body` is Dan's edit, as above. It replaces the composed body only.
    static func sendClosingNote(_ recipient: Recipient, of prospect: Prospect,
                                now: Date, sender: MailSender, body: String? = nil) async -> Bool {
        guard let email = recipient.email, !email.isEmpty, recipient.sentAt != nil else { return false }
        // #2033: the note lands on a thread the whole group is reading, so it is addressed to all of them.
        let group = SendGroup.peers(of: recipient, in: prospect)
        let addresses = group.compactMap(\.email).filter { !$0.isEmpty }
        // #948: subject and body from the one shared helper the confirmation sheet also reads. It returns
        // nil for a kind that is a prompt, not a sendable email, exactly the .needsState/.suggested case.
        //
        // #2030: both refusals now happen BEFORE the claim, so neither can leave it held on a note that
        // was never sent. That is what the explicit claim release here used to be for.
        guard let content = PostEventPrompt.nudgeContent(kind: .closingNote, originalSubject: prospect.draftSubject,
                                                        groupName: prospect.groupName,
                                                        isMerged: prospect.isMergedConcert,
                                                        contactName: recipient.name,
                                                        performanceDate: prospect.performanceDate,
                                                        venue: prospect.venue),
              let outgoing = editedOrComposed(body, composed: content.body),
              let mail = OutgoingMail(
                to: addresses,
                subject: content.subject,
                body: outgoing,
                inReplyTo: recipient.gmailMessageId,
                references: MailThreading.references(parentReferences: recipient.gmailReferences,
                                                     parentMessageID: recipient.gmailMessageId),
                threadId: recipient.gmailThreadId) else { return false }
        // #468: shared with sendFollowUp's claim above. #2033: over the whole group.
        guard claimSecondarySend(group, \.nudgeSendClaimedAt, now: now) else { return false }
        do {
            _ = try await sender.send(mail)
            for r in group {
                r.conversationRemindedAt = now   // re-anchor so it steps forward, not nags
                r.sendError = nil
                r.nudgeSendClaimedAt = nil
            }
            // #2397: sending the closing note records the SHOW as never heard back, which is what the note
            // has always MEANT and what this path did not say. It resolved the lead to a soft decline in
            // every case, claiming somebody had turned Dan down when nobody had written back at all.
            //
            // At the show level, not on the contact, because that is where an ending lives now (#2394) and
            // because the note is only ever offered when NOBODY on the show replied: there is no per-person
            // judgement here to keep apart, which is what Dan's 2026-07-08 decision was protecting.
            prospect.showOutcome = .neverHeardBack
            return true
        } catch {
            for r in group {
                r.sendError = error.localizedDescription
                r.nudgeSendClaimedAt = nil   // retryable, never stuck claimed
            }
            return false
        }
    }

    // Sends Dan's approved AI-drafted reply to ONE recipient, on THAT recipient's own Gmail thread
    // (#421): threads on recipient.gmailMessageId/gmailThreadId, NOT the lead rollup (the rollup is the
    // first contact's thread, so replying to a second contact on it would land on the wrong
    // conversation). On success it consumes the draft and re-anchors that contact's clock. One of the
    // two locked send paths (d); the other is copy-out (recordAnswerSent), handled in the UI.
    @discardableResult
    // #2144: what a reply is CALLED, in one place. The confirmation sheet Dan approves and the message
    // that leaves both ask this, so the subject line he reads cannot differ from the one on the email. Two
    // expressions of the same rule would drift the first time either changed.
    static func replySubject(for recipient: Recipient, of prospect: Prospect) -> String {
        recipient.replyDraftSubject
            ?? FollowUp.replySubject(originalSubject: prospect.draftSubject,
                                     groupName: FollowUp.safeDisplayName(prospect.groupName,
                                                                          isMerged: prospect.isMergedConcert))
    }

    static func sendReplyDraft(_ recipient: Recipient, of prospect: Prospect,
                               now: Date, sender: MailSender) async -> Bool {
        guard let email = recipient.email, !email.isEmpty,
              let body = recipient.replyDraftBody, !body.isEmpty else { return false }
        // #2063: addressed the way the reply being answered was addressed, which is what any mail client
        // does. #2033 sent this to everyone who received the ORIGINAL email instead, on the reasoning that
        // replying to one person on a shared thread goes behind the others' backs. That is true when the
        // writer used reply-all, and exactly wrong when they wrote to Dan alone: it answers a message
        // somebody chose to send privately in front of everybody else. The original send cannot tell those
        // apart, because it happened before the choice was made. Dan's rule, 2026-08-04: "if they reply
        // all, i should reply all. if they respond directly to me I should reply directly to them."
        let addresses = SendGroup.replyAudience(of: recipient)
        // #468: on its own claim field, not shared with sendFollowUp/sendConversationNudge's
        // (see the field's doc comment on Recipient), since a replied recipient can legitimately
        // be due for a conversation nudge at the same time.
        let subject = replySubject(for: recipient, of: prospect)
        // #2030: built before the claim, for the same reason as the two nudges above.
        // #2653: THEIR message is the parent, not ours. This used to pass `recipient.gmailMessageId`,
        // which is Overture's own last outgoing message, so the contact's reply became a sibling of Dan's
        // answer rather than its parent. Through `ReplyThreading` so the inquiry path answers identically.
        let chain = ReplyThreading.references(for: recipient)
        guard let mail = OutgoingMail(to: addresses, subject: subject, body: body,
                                      inReplyTo: ReplyThreading.inReplyTo(for: recipient),
                                      references: chain,
                                      threadId: recipient.gmailThreadId) else { return false }
        guard claimSecondarySend(recipient, \.replySendClaimedAt, now: now) else { return false }
        do {
            let receipt = try await sender.send(mail)
            // #2647: only when there IS one. This used to assign unconditionally, which after the read
            // back landed would have BLANKED a good id whenever the read back failed, leaving the next
            // message on this conversation with nothing to reference at all (L5).
            if let m = receipt.messageID {
                recipient.gmailMessageId = m       // thread their next reply off ours
                recipient.gmailReferences = chain  // #2648: the ancestry of that message, moved with it
            }
            recipient.threadingDegraded = receipt.messageIDDegraded
            if !receipt.threadId.isEmpty { recipient.gmailThreadId = receipt.threadId }
            // #2170: the same routine the copy-out path runs, rather than the four lines it used to
            // repeat here. They had drifted into two copies of one idea, and the fact neither of them
            // recorded (that Dan had ANSWERED) is why the Answer button kept offering itself afterwards.
            // #2191: through AnsweredReply, so the peers detection put this same reply on stop asking
            // too. Calling recordAnswerSent directly here is what left a colleague reading as waiting
            // after the answer had gone.
            AnsweredReply.record(on: recipient, in: prospect, now: now)
            recipient.sendError = nil
            recipient.replySendClaimedAt = nil
            return true
        } catch {
            recipient.sendError = error.localizedDescription
            recipient.replySendClaimedAt = nil   // retryable, never stuck claimed
            return false
        }
    }

    // #2031: why these contacts cannot share one email, in the words Dan reads, or nil when they can.
    //
    // Only one reason exists, and it is the one the app must never decide on his behalf: the members would
    // not receive the same words. A directly-addressed performer carries their own second-person letter
    // (#641/#789), so putting them on one message with somebody reading a different letter means one of
    // the two gets text written for the other, greeted by the other's name.
    nonisolated static func jointSendRefusal(_ recipients: [Recipient], of prospect: Prospect) -> String? {
        guard Set(recipients.map { $0.effectiveBody ?? "" }).count > 1 else { return nil }
        return ActionAck.jointSendMixedLetters
    }

    // #2031: ONE email to several contacts of a performance, and every one of them recorded as having
    // received THAT email.
    //
    // The group forms from the still-sendable contacts among those passed, so a contact who already had
    // their own email is never written to twice, and a contact held by a guard is never quietly included
    // in somebody else's message.
    @discardableResult
    static func sendJointly(_ prospect: Prospect, to recipients: [Recipient],
                            now: Date, sender: MailSender) async -> Bool {
        // #2033: the show-level gate too, not only the per-contact one. `isSendablePending` says this
        // CONTACT is ready; it does not say the show is approved, and a send that skipped that would put
        // out a draft Dan never approved. Caught by #2015's own card guard, which noticed an unapproved
        // draft naming contacts it was about to email.
        guard prospect.status == .approved else { return false }
        let group = sendOrdered(recipients.filter(\.isSendablePending))
        guard !group.isEmpty, jointSendRefusal(group, of: prospect) == nil,
              let pitch = OutgoingPitch.text(forGroup: group, of: prospect),
              let sharedBody = group.first?.effectiveBody,
              let mail = OutgoingMail(to: group.compactMap(\.email),
                                      subject: prospect.draftSubject ?? "", body: pitch)
        else { return false }

        // Claim ALL of them or none, before the network call, on the same reasoning as `deliver`'s single
        // claim (#475/#476). Nothing between the check and the save awaits, so on the MainActor the whole
        // prefix is atomic: a second call racing this group sees them already claimed and backs off. One
        // save, because `modelContext.save()` persists the whole context, so claiming N costs no more
        // round trips than claiming one.
        guard group.allSatisfy({ $0.sendState == .pending }) else { return false }
        for r in group {
            r.sendState = .sending
            r.sendClaimedAt = now
        }
        guard (try? prospect.modelContext?.save()) != nil else {
            for r in group {
                r.sendState = .pending
                r.sendClaimedAt = nil
            }
            return false
        }

        let groupId = UUID().uuidString
        do {
            let receipt = try await sender.send(mail)
            for r in group {
                r.sentAt = now
                r.sendState = .sent
                r.sendClaimedAt = nil
                r.gmailThreadId = receipt.threadId
                r.gmailMessageId = receipt.messageID
                r.replyTrackingDegraded = receipt.threadIdDegraded
                r.threadingDegraded = receipt.messageIDDegraded   // #2647
                r.sendGroupId = groupId
                r.sendError = nil
            }
            // The lead-level first-send rollup, written once, exactly as `deliver` does it.
            if prospect.sentAt == nil {
                prospect.sentAt = now
                prospect.priorRelationshipAtSend = prospect.priorRelationship
                prospect.freezeFeaturesAtSend()
                prospect.gmailThreadId = receipt.threadId
                prospect.gmailMessageId = receipt.messageID
            }
            prospect.freezeSentCopy(subject: mail.subject, body: sharedBody)
            prospect.sendError = nil
            if !prospect.recipients.contains(where: \.isSendablePending) {
                prospect.status = .contacted
            }
            return true
        } catch {
            // Every member carries the failure, not just the first. A contact left with no trace of the
            // attempt is indistinguishable from one never tried (L47), and this send was attempted on
            // behalf of all of them at once.
            for r in group {
                r.sendState = .pending
                r.sendClaimedAt = nil
                r.sendError = error.localizedDescription
            }
            prospect.sendError = error.localizedDescription
            return false
        }
    }
}
