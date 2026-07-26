import Foundation

// #1027: the one rule that decides whether a no_dated_content page Dan confirmed as "right but quiet"
// should stay silent this run. Pure, so both the ingest suppression and any test read the same answer.
//
// It is deliberately a hash EQUALITY check and nothing looser: a content hash can never false-match, so
// a confirmed page that has since changed (new bytes, new hash) fails the test and nags again, which is
// exactly the "until its content changes" the confirm promised. A nil on either side is never a match:
// nothing confirmed, or nothing read to compare.
enum SourceConfirmation {
    static func isConfirmedQuiet(verdict: PageVerdict, readHash: String?,
                                 confirmedEmptyHash: String?) -> Bool {
        guard verdict == .noDatedContent,
              let readHash, let confirmedEmptyHash else { return false }
        return readHash == confirmedEmptyHash
    }

    // #1048: the mirror question, asked BEFORE Dan confirms rather than at the next ingest. A confirm
    // anchors confirmedEmptyHash to the bytes last READ (`anchorHash`: pendingContentHash, or the last
    // ingested hash). `lastSeenHash` is the newest bytes any fetch has seen, which the free daily
    // watch-only pass keeps current without re-reading. When the two have diverged, the page has moved on
    // since the read, so the anchor is stale: confirming now would set confirmedEmptyHash to bytes the
    // next real read cannot match, and isConfirmedQuiet would return false, so the source would nag again.
    //
    // A nil on either side is never stale: no bytes to anchor to (confirmEmpty returns .noHash on its
    // own), or a row from before this field was recorded, where over-warning would be worse than silence.
    static func readIsStaleForConfirm(anchorHash: String?, lastSeenHash: String?) -> Bool {
        pageMovedSinceRead(readHash: anchorHash, lastSeenHash: lastSeenHash)
    }

    // #1546: the same question with the confirm taken out of it. Has the live page moved past the bytes we
    // last READ? Two callers now ask it for different reasons (a confirm that would not stick above, and
    // telling a retry owed from real unread listings in WatchedSource), so it is stated once rather than
    // compared by hand in two places that could drift on the nil rule.
    //
    // A nil on either side is never a move: nothing read to compare against, or a row from before these
    // fields were recorded. Both callers want the same conservative answer there.
    static func pageMovedSinceRead(readHash: String?, lastSeenHash: String?) -> Bool {
        guard let readHash, let lastSeenHash else { return false }
        return readHash != lastSeenHash
    }
}
