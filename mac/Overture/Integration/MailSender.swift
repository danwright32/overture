import Foundation

// The seam between Overture and actually sending mail. A real implementation calls
// the Gmail API for dan@danwrightphotography.com (which requires authorizing that
// account, the one external step only Dan can do). Until then, NotConfiguredSender
// makes the whole send pipeline build, test, and run without sending anything.

struct OutgoingMail: Equatable, Sendable {
    var to: String
    var subject: String
    var body: String
    // Threading (#74): on the first send, `messageID` stamps the message so a follow-up can
    // reference it. On a follow-up, `inReplyTo` + `threadId` reply onto the original thread.
    var messageID: String? = nil
    var inReplyTo: String? = nil
    var threadId: String? = nil
}

struct SentReceipt: Equatable, Sendable {
    var threadId: String
    var messageID: String? = nil   // the Message-ID stamped on the sent message, for threading (#74)
}

protocol MailSender: Sendable {
    func send(_ mail: OutgoingMail) async throws -> SentReceipt
}

enum MailSenderError: LocalizedError {
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Gmail isn't connected yet. Authorize the photography account to enable sending."
        }
    }
}

// Default until Gmail is authorized: refuses to send, so nothing leaves by accident.
struct NotConfiguredSender: MailSender {
    func send(_ mail: OutgoingMail) async throws -> SentReceipt {
        throw MailSenderError.notConfigured
    }
}
