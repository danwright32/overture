import Foundation

// The exact thing Dan sees before a manual send goes out (#49): the recipient and
// subject of the one email about to send. Built only for a prospect that would
// genuinely send (same guard as SendService.sendOne), so the confirm step can never
// appear for an email that wouldn't actually go. No SendConfirmation => nothing sends.
struct SendConfirmation: Equatable {
    let recipient: String
    let subject: String

    @MainActor
    init?(prospect: Prospect) {
        guard prospect.status == .approved, prospect.sentAt == nil,
              let email = prospect.contactEmail, !email.isEmpty,
              let body = prospect.draftBody, !body.isEmpty else { return nil }
        recipient = email
        let trimmed = (prospect.draftSubject ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        subject = trimmed.isEmpty ? "(no subject)" : trimmed
    }
}
