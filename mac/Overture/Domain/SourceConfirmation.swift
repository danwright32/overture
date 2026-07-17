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
}
