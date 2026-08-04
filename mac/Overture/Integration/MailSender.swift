import Foundation

// The seam between Overture and actually sending mail. A real implementation calls
// the Gmail API for dan@danwrightphotography.com (which requires authorizing that
// account, the one external step only Dan can do). Until then, NotConfiguredSender
// makes the whole send pipeline build, test, and run without sending anything.

struct OutgoingMail: Equatable, Sendable {
    // #2030: a list, because one message can name several people (milestone "One email to several
    // contacts"). Private(set) with a failable init below, so a mail with nobody to send to cannot be
    // constructed at all rather than reaching Gmail with an empty addressee.
    private(set) var to: [String]
    var subject: String
    var body: String
    // Threading (#74): on the first send, `messageID` stamps the message so a follow-up can
    // reference it. On a follow-up, `inReplyTo` + `threadId` reply onto the original thread.
    var messageID: String? = nil
    var inReplyTo: String? = nil
    var threadId: String? = nil

    // Nil when there is nobody to send to. A mail with no addressee is not a mail, and the alternative
    // (constructing one and finding out at the Gmail API, or worse not finding out) puts the discovery
    // after the point where a caller has already recorded that something went out.
    //
    // A blank ALONGSIDE a real address is dropped rather than refused: the person named still gets their
    // email, and nothing empty reaches the header.
    //
    // #2052: nil for a blank SUBJECT too, on the same reasoning. This is the boundary every send path
    // passes through (a pitch, a joint pitch, a follow-up, a conversation note, a reply), so it is the one
    // place that can promise no email leaves under Dan's name with an empty `Subject:` header, whatever
    // the screen above it did. The subject is kept verbatim rather than trimmed here: what he approved is
    // what sends, and this only decides whether there is one at all.
    init?(to: [String], subject: String, body: String,
          messageID: String? = nil, inReplyTo: String? = nil, threadId: String? = nil) {
        let addresses = to.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !addresses.isEmpty,
              !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        self.to = addresses
        self.subject = subject
        self.body = body
        self.messageID = messageID
        self.inReplyTo = inReplyTo
        self.threadId = threadId
    }
}

struct SentReceipt: Equatable, Sendable {
    var threadId: String
    var messageID: String? = nil   // the Message-ID stamped on the sent message, for threading (#74)
    // True when the send succeeded (2xx) but the response body had no parseable threadId (#483):
    // threadId is "" in this case, never a guess, so the caller can flag it instead of leaving
    // reply watching silently and permanently broken for that recipient.
    var threadIdDegraded: Bool = false
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
