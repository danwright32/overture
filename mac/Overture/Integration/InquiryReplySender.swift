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
        guard let mail = OutgoingMail(to: [to], subject: subject, body: body) else { return false }
        do {
            let receipt = try await sender.send(mail)
            inquiry.sentAt = now
            inquiry.gmailThreadId = receipt.threadId.isEmpty ? nil : receipt.threadId
            inquiry.gmailMessageId = receipt.messageID
            inquiry.threadIdDegraded = receipt.threadIdDegraded
            if inquiry.replied {
                inquiry.dismissedReplyId = inquiry.lastReplyId
                inquiry.replied = false
            }
            return true
        } catch {
            return false
        }
    }
}
