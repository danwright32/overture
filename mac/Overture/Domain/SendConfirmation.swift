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
    let from: SendIdentity
    let recipient: String
    let subject: String
    let body: String

    @MainActor
    init?(prospect: Prospect) {
        guard let next = SendService.nextPendingRecipient(for: prospect),
              let email = next.email, !email.isEmpty,
              let body = prospect.draftBody, !body.isEmpty else { return nil }
        from = .danWright
        recipient = email
        self.body = body
        let trimmed = (prospect.draftSubject ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        subject = trimmed.isEmpty ? "(no subject)" : trimmed
    }
}
