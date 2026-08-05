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

    // The send is refused, never merely discouraged, on each of the three things that make it impossible:
    // nothing typed, nobody to send to, no Gmail. Refusing here means the button is honest at rest,
    // instead of failing at the network and reporting an error Dan can do nothing about (L67).
    static func canSend(body: String, audience: [String], gmailConnected: Bool) -> Bool {
        guard gmailConnected, !audience.isEmpty else { return false }
        return !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

    // L64: what Dan approves has to include WHO it reaches. The panel states the audience in full rather
    // than only naming the extras the way a card does, because this is the surface the send is approved
    // from and the audience of a reply is routinely not the audience of the original email.
    static func audienceLine(_ addresses: [String]) -> String {
        guard !addresses.isEmpty else { return "No address to reply to" }
        return "Goes to \(Plural.list(addresses))"
    }
}

// #2128: the panel's own sentences, in a pure type so the view composes none of them (ViewCopyGuardTests)
// and so every one of them appears in the copy inventory for a cold read.
enum ReplyPanelCopy {
    static let answer = "Answer"
    static let noCapturedWords = "Overture didn't capture what they wrote. Their message is in Gmail."
    static let send = "Send reply"
    static let sending = "Sending"
    static let cancel = "Cancel"
    static let sendHelp = "Send this reply on the thread they wrote on"
    // Names what happened and leaves the button available, rather than a dead spinner or a cheerful
    // pretence that it went (L12). The words stay in the box: nothing Dan typed is thrown away.
    static let sendFailed = "That didn't send. Your reply is still here, so you can try again."
}
