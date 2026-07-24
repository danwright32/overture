import Foundation

// #1418: the "Why lost?" note's save rule, pulled out of DraftReviewView so it is testable. The note used
// to run a full ProspectMutations.setLostReason + SwiftData save on every keystroke; it now commits only on
// submit and focus loss, and only when the text differs from what was last saved, so leaving an untouched
// field writes nothing.
enum LostReasonCommit {
    static func shouldSave(current: String, lastSaved: String) -> Bool {
        current != lastSaved
    }
}
