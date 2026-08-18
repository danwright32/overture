import Foundation

// #2966: whether a reply draft is still AWAITED, defined once.
//
// Three places asked this, and only one of them carried the guard that makes the answer true.
//
// `Recipient.recordAnswerSent` nils `replyDraftBody`, stamps `replyHandledAt`, and leaves
// `replyDraftRequestedAt` standing, which is deliberate: `Recipient.wasWrittenTo` reads that stamp as
// evidence a real exchange happened, and it guards a delete path, so clearing it could turn a real
// outreach record into one that reads as never having gone out (L5). Every reader therefore has to allow
// for a request belonging to an exchange already answered (L68), and one of the three did:
//
//   * `ReplyPanel.isDrafting` guarded it, with a comment naming exactly this.
//   * `Recipient.isReplyDraftStalled` did not, so every conversation Dan answered through Overture after
//     asking for an AI draft read as permanently stalled. That was invisible while nothing rendered it;
//     #2878 wires it into `DueWork`, where it would have become a gold Follow-ups pill, a toolbar badge, a
//     Dock tile count and a menu bar count that no action could clear.
//   * `RecipientSnapshot.isDraftingReply` did not either, and it decides whether
//     `ReplyConversationView` draws "Drafting a reply..." with a Retry, so the same answered conversation
//     showed a run that had finished hours earlier and offered to restart it.
//
// So it is one rule, and the two readings that differ (is it awaited AT ALL, and has it been awaited too
// long) are spelled as two questions asked of the same answer rather than as two predicates.
//
// Pure and over primitives, deliberately, because one of the three callers is a view-model snapshot rather
// than the model itself, and a rule living on `Recipient` alone could not be shared with it.
enum ReplyDraftRequest {
    // WHEN the awaited request was made, or nil when nothing is awaited. It answers with the instant
    // rather than a Bool because every caller needs the instant next: to measure the wait against a
    // timeout, or to date the label it draws (L125's shape, the other way round).
    //
    // `answeredAt` is `Recipient.replyHandledAt`. `<=` rather than `<`: an answer stamped at the same
    // instant as the request is still an answer, and the two can share an instant in a test or a fast
    // sequence of writes.
    static func awaited(requestedAt: Date?, draftBody: String?, answeredAt: Date?) -> Date? {
        guard let requestedAt else { return nil }
        // Something arrived, so nothing is awaited. Written as "not non-empty" rather than `== nil` because
        // SwiftData hands back whatever was stored and an empty string is not a draft.
        guard draftBody?.isEmpty != false else { return nil }
        if let answeredAt, requestedAt <= answeredAt { return nil }
        return requestedAt
    }
}
