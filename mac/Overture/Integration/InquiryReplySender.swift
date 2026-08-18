import Foundation

// Sends Dan's own first reply to a hire inquiry (#1435). Deliberately NOT SendService: that path is
// Prospect-only, AI-drafted, and drip-managed, with no concept of a one-shot reply Dan typed himself.
// This is a thin, direct send on the same `MailSender` primitive, so the resulting thread is watched
// by the shared reply-detection pipeline exactly like a prospect's.
@MainActor
enum InquiryReplySender {
    // Returns whether the send succeeded, so the caller surfaces a failure instead of it failing
    // silently (#499 idiom). On success the inquiry records its thread and send time; on failure it is
    // left untouched, so nothing looks sent that was not.
    // #1513: this now sends ANY reply Dan writes, not only the first. Answering again is the same act
    // (he types it, it goes on the same thread), so it is the same path rather than a second copy.
    //
    // What differs is the waiting state. After he answers, he is waiting on THEM again, and the nudge
    // clock restarts from this send.
    //
    // #2943: that is recorded by STAMPING the answer, not by clearing `replied`. Clearing it destroyed the
    // evidence a reply ever arrived: the row went back to "Sent, waiting to hear back", identical to an
    // inquiry nobody ever wrote back to, and #16's funnel counted a real conversation as silence (L163).
    // `hasUnhandledReply` compares the answer against when their message arrived, so the reply he just
    // answered stops asking while a NEWER one still re-opens the row, which is the rule
    // `Recipient.recordAnswerSent` has followed since #2170.
    @discardableResult
    static func sendReply(_ inquiry: Inquiry, subject: String, body: String, now: Date,
                          sender: MailSender) async -> Bool {
        guard let to = inquiry.inquirerEmail, !to.isEmpty else { return false }
        // #2796: the same refusal the prospect reply path carries, on the entity #2795 gave a second
        // writer of `gmailThreadId`. An inquiry whose conversation was ATTACHED (#2712) has no message of
        // Overture's, so when detection also read no `Message-ID` of theirs there is nothing for this
        // answer to hang off and it would arrive unparented in a conversation Overture never sent on.
        // Every other attached inquiry is answered exactly as before, which is what #2712 is for.
        //
        // A guard of its own rather than a shared call site: this is not `SendService`, deliberately (see
        // the note above), so a refusal written there says nothing about this path. It is stated on the
        // panel too, from the same function, so the Send button and the reason cannot disagree (L109).
        guard AttachedConversation.refusalToContinue(inquiry,
                                                     displayName: inquiry.replyWatchDisplayName) == nil
        else { return false }
        // #2063: addressed the way the reply being answered was addressed, falling back to the inquirer
        // alone when there is nothing to mirror. Through the same helper as the prospect reply path, so the
        // two cannot answer "who does this reach" differently.
        let addresses = SendGroup.replyAudience(of: inquiry)
        // #2661: threaded onto the conversation it is answering, through the same three pieces the
        // prospect reply path uses (`SendService.sendReplyDraft`) rather than a second implementation of
        // the same idea. It used to send with none of them, so Dan's answer arrived as a brand new
        // conversation in every client including Gmail, and #1513 made this path send ANY reply he
        // writes, so a second answer started a third unrelated thread.
        //
        // It matters beyond tidiness: reply detection watches `gmailThreadId`, so an answer sent
        // off-thread means the inquirer's next message lands on the new thread Gmail just created, which
        // is not the one being watched, and a reply to Dan's own answer can go unnoticed.
        //
        // All three are nil on an inquiry Dan logged by hand and has never emailed about, which is
        // correct: an empty `References` is honest, a fabricated one points at nothing.
        // #2653: THEIR message is the parent when it is known, through the same `ReplyThreading` the
        // prospect path uses, so which message an answer threads onto is one rule rather than two.
        let chain = ReplyThreading.references(for: inquiry)
        guard let mail = OutgoingMail(to: addresses.isEmpty ? [to] : addresses,
                                      subject: subject, body: body,
                                      inReplyTo: ReplyThreading.inReplyTo(for: inquiry),
                                      references: chain,
                                      threadId: inquiry.gmailThreadId) else { return false }
        do {
            let receipt = try await sender.send(mail)
            inquiry.sentAt = now
            inquiry.gmailThreadId = receipt.threadId.isEmpty ? nil : receipt.threadId
            // #2647: keep a prior real id rather than blanking it when the read back failed, on the same
            // reasoning as the prospect reply path: a real ancestor still threads, nothing does not (L5).
            // #2661: the chain moves WITH the message it is the ancestry of, and only when there is a
            // message to move it to. Assigning either unconditionally would blank a good id the moment a
            // read back failed, leaving the next message on this conversation nothing to reference (L5).
            if let m = receipt.messageID {
                inquiry.gmailMessageId = m
                inquiry.gmailReferences = chain
            }
            inquiry.threadIdDegraded = receipt.threadIdDegraded
            inquiry.threadingDegraded = receipt.messageIDDegraded
            // #2675: cleared on success, or a failure Dan has since recovered from would sit on the row
            // for good. A guard that fails closed forever is still a defect.
            inquiry.sendError = nil
            // #2943: only when there was something to answer. Unlike the prospect reply path, this same
            // function sends the FIRST reply to an inquiry too (#1513), and stamping that would record an
            // answer to a message nobody sent (L11).
            //
            // `dismissedReplyId` is deliberately no longer written here. It was standing in for the
            // answered fact: with `replied` cleared, detection would have met their same message as a
            // brand new one, so it had to be struck as a wrong reply. With the answer recorded, detection
            // skips it on the id it already holds, and striking a real reply as never having happened is
            // the destruction this issue is about.
            if inquiry.replied { inquiry.markReplyAnswered(now: now) }
            return true
        } catch {
            // #2675: recorded, not merely returned. The caller's `.sendFailed` notice clears, and after it
            // does the inquiry looked exactly like one nobody had answered yet. Same field, same words and
            // same reader as a prospect's failed send.
            inquiry.sendError = error.localizedDescription
            return false
        }
    }
}
