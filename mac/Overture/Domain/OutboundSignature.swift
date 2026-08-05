import Foundation

// #1144: the ONE source of the sign-off appended to every outbound email (cold drafts, follow-ups,
// reminders), so no surface bakes its own copy (they did: the same plain-text literal was pasted across
// FollowUp and ConversationReminder, and cold drafts had none at all). `html` is Dan's styled Gmail
// signature when Overture has it (live-fetched from Gmail settings, #1144); `plainText` is always present,
// serving both as the text/plain part's sign-off and as the whole message's fallback when the HTML is
// unavailable. The send layer (GmailMessage) appends it, so a body producer never carries a sign-off.
struct OutboundSignature: Equatable, Sendable {
    var html: String?
    var plainText: String

    // #2086: the signature as it goes ON THE WIRE, with the near-invisible borders removed. `html` stays
    // the faithful copy of what Gmail holds; this is what Overture actually sends, and therefore also
    // what every preview renders and what the dark-background warning is judged against. One definition
    // rather than a strip at each call site, so the wire and the card cannot come to differ about the
    // message Dan approved (L64).
    var sendableHTML: String? {
        guard let html, !html.isEmpty else { return nil }
        return GmailSignatureHealth.strippingInvisibleBorders(html)
    }

    // No sign-off at all: the neutral default, so an existing GmailMessage caller that passes nothing is
    // byte-for-byte unchanged. The real send path always passes a populated signature.
    static let none = OutboundSignature(html: nil, plainText: "")

    // copy-inventory:ignore-start  outbound email sign-off, not Overture's own voice to Dan (#915)
    // The plain-text fallback Overture appends when it has no HTML signature (the fetch failed, or it has
    // not fetched yet). One definition, replacing the literal that was copied across FollowUp and
    // ConversationReminder.
    static let plainFallback = OutboundSignature(html: nil, plainText: "Best,\nDan Wright\nDan Wright Photography")
    // copy-inventory:ignore-end
}
