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
    @discardableResult
    static func sendFirstReply(_ inquiry: Inquiry, subject: String, body: String, now: Date,
                               sender: MailSender) async -> Bool {
        guard let to = inquiry.inquirerEmail, !to.isEmpty else { return false }
        let mail = OutgoingMail(to: to, subject: subject, body: body)
        do {
            let receipt = try await sender.send(mail)
            inquiry.sentAt = now
            inquiry.gmailThreadId = receipt.threadId.isEmpty ? nil : receipt.threadId
            inquiry.gmailMessageId = receipt.messageID
            inquiry.threadIdDegraded = receipt.threadIdDegraded
            return true
        } catch {
            return false
        }
    }
}
