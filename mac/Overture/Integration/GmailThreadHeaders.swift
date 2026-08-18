import Foundation

// #2928: WHICH headers a `format=metadata` thread read asks Gmail for, in ONE place.
//
// Gmail's `format=metadata` returns only the headers named in `metadataHeaders`. Everything else on the
// message is dropped: a reader that goes looking for a header nobody asked for gets an empty string, and
// an empty string is exactly what a header that is genuinely absent looks like. So the request and the
// readers are one contract, and it was being maintained by hand at three separate call sites, each with a
// different list, derived from nothing (L41, L96).
//
// Two live readers were on the wrong side of that when this was written, and both had passing tests,
// because every fixture in the suite handed back whatever headers it felt like regardless of what the
// request asked for:
//
//   - #2653's `latestReplyMessageID`, which is how Dan's answer threads onto THEIR message rather than
//     onto his own earlier one. `ReplyService.recordWriter` reads it off the metadata thread, and
//     `GmailReplyChecker` asked for `From` and `Subject` only. So `inboundReplyMessageId` was nil on every
//     row the ordinary reply watch ever recorded, `ReplyThreading.inReplyTo` fell back to Overture's own
//     last message, and #2653's defect was still shipping under #2653's fix.
//
//   - #2865's `isAutomatedSend`, the one thing standing between an out of office autoreply from Dan's own
//     mailbox and a row being cleared as answered. It reads `Auto-Submitted`, `X-Autoreply`,
//     `X-Autorespond` and `Precedence`, none of which were ever requested, so it could only ever answer
//     false and `AnsweredElsewhere` would have stamped `replyHandledAt` off a holiday autoresponder. That
//     is the same permanent silencing #2918 had just fixed by another route (L42).
//
// The list is deliberately the UNION of what every thread reader reads, not a per-caller subset. A caller
// asking for less is the defect above, and asking for more costs nothing: the headers ride the response
// that is already being fetched, and `format=metadata` still returns no bodies.
//
// `GmailThreadHeaderContractTests` derives the required set from the source of `ReplyDetection` and
// `BounceDetection` and fails when a reader starts reading a header this list does not request, so the
// pair cannot drift again by anybody forgetting.
enum GmailThreadHeaders {

    // copy-inventory:ignore-start  RFC822 header names in a Google API URL, not sentences Overture says (#915)
    // Every header any reader of a thread message reads, in the spelling Gmail wants in the query.
    static let metadata = [
        "From",
        "To",
        "Cc",
        "Subject",
        "Message-ID",
        "Auto-Submitted",
        "X-Autoreply",
        "X-Autorespond",
        "Precedence",
    ]

    // The `format=metadata&metadataHeaders=...` query every thread read uses.
    static var metadataQuery: String {
        (["format=metadata"] + metadata.map { "metadataHeaders=\($0)" }).joined(separator: "&")
    }
    // copy-inventory:ignore-end
}
