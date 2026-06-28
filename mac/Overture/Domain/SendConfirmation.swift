import Foundation

// The exact thing Dan sees before a manual send goes out (#49): the recipient and
// subject of the one email about to send. Built from the performance's NEXT pending
// recipient (same source as SendService.sendOne), so the confirm step can never appear
// for an email that wouldn't actually go, and a fully-sent show yields nil (no
// duplicate send). For a multi-recipient show each click confirms the next address.
struct SendConfirmation: Equatable {
    let recipient: String
    let subject: String

    @MainActor
    init?(prospect: Prospect) {
        guard let next = SendService.nextPendingRecipient(for: prospect),
              let email = next.email, !email.isEmpty,
              let body = prospect.draftBody, !body.isEmpty else { return nil }
        recipient = email
        let trimmed = (prospect.draftSubject ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        subject = trimmed.isEmpty ? "(no subject)" : trimmed
    }
}
