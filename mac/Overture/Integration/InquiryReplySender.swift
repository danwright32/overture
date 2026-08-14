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
    // What differs is the waiting state. After he answers, he is waiting on THEM again, so `replied`
    // clears and the nudge clock restarts from this send. The reply he just answered is marked handled,
    // because reply detection keys off the last reply id: leave it and the very next check re-flags the
    // row as needing him, and it could never leave the "they replied" state.
    @discardableResult
    static func sendReply(_ inquiry: Inquiry, subject: String, body: String, now: Date,
                          sender: MailSender) async -> Bool {
        guard let to = inquiry.inquirerEmail, !to.isEmpty else { return false }
        // #2063: addressed the way the reply being answered was addressed, falling back to the inquirer
        // alone when there is nothing to mirror. Through the same helper as the prospect reply path, so the
        // two cannot answer "who does this reach" differently.
        let addresses = SendGroup.replyAudience(of: inquiry)
        guard let mail = OutgoingMail(to: addresses.isEmpty ? [to] : addresses,
                                      subject: subject, body: body) else { return false }
        do {
            let receipt = try await sender.send(mail)
            inquiry.sentAt = now
            inquiry.gmailThreadId = receipt.threadId.isEmpty ? nil : receipt.threadId
            // #2647: keep a prior real id rather than blanking it when the read back failed, on the same
            // reasoning as the prospect reply path: a real ancestor still threads, nothing does not (L5).
            if let m = receipt.messageID { inquiry.gmailMessageId = m }
            inquiry.threadIdDegraded = receipt.threadIdDegraded
            inquiry.threadingDegraded = receipt.messageIDDegraded
            // #2675: cleared on success, or a failure Dan has since recovered from would sit on the row
            // for good. A guard that fails closed forever is still a defect.
            inquiry.sendError = nil
            if inquiry.replied {
                inquiry.dismissedReplyId = inquiry.lastReplyId
                inquiry.replied = false
            }
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
