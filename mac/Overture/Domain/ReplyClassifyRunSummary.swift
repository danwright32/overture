import Foundation

// What a finished reply-classify run TELLS Dan about the replies it never came back with, derived purely
// from its outcome (#1018). Sibling to PrepRunSummary (#876): the copy lives in a pure type a test can
// read, not inside RootView's SwiftUI body where #863 warns a rule computed in a view will drift unseen.
//
// Scoped to the shortfall on purpose. The one other thing a completion can report, a save failure, is a
// static sentence RootView shows directly (there is no rule to drift). This type exists for the sentence
// that IS a rule: how many replies were dropped, and the promise that they will be retried.
enum ReplyClassifyRunSummary {

    static func notes(for outcome: ReplyClassifyImporter.Outcome) -> [String] {
        var notes: [String] = []
        // #1018: replies the run was given and never came back with. Left silent, a reply Dan needs
        // answered sits unclassified and un-drafted run after run with no signal it was ever missed. The
        // promise is real: a reply still without a draft is re-queued by ReplyClassifyService next run.
        if !outcome.missingKeys.isEmpty {
            notes.append(HandoffShortfall.retryNote(count: outcome.missingKeys.count))
        }
        return notes
    }

    // #2873: what Dan is told when the results file is THERE and cannot be read. This is the sentence
    // whose absence cost a day: the throw was discarded, so a finished run whose drafts were dropped
    // looked exactly like a run with nothing to do, and the reply sheet went on showing a spinner.
    //
    // It names the file and the reason (HandoffDecodeFailure names the field), and it deliberately does
    // NOT suggest waiting or trying again: the same run would write the same unreadable shape, so
    // advising a retry would be advice that changes nothing (L111).
    // One literal, not a concatenation: the inventory lists each literal separately, so a sentence built
    // from two pieces reaches the cold read as two fragments and cannot be read as the thing Dan sees.
    static func unreadableMessage(reason: String) -> String {
        "A reply drafting run finished, but Overture couldn't read what it wrote, so no draft was saved (\(reason)). The file it wrote is still on disk, as overture-reply-classify-results.json."
    }

    // The whole line, or nothing at all. A run with nothing to report says nothing rather than showing an
    // empty "Replies:" with a blank after it.
    static func statusMessage(for outcome: ReplyClassifyImporter.Outcome) -> String? {
        let notes = notes(for: outcome)
        guard !notes.isEmpty else { return nil }
        return "Replies: " + notes.joined(separator: " · ")
    }
}
