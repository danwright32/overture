import Foundation

// #2417: what a screen reader says about a row that is on its way out of the queue.
//
// Beside the data rather than inside the row, because a sentence computed in a view is a sentence no
// test can reach (#885). It carries more than usual here: the visible row says it is leaving by going
// dim and then sliding away, and neither of those is a word, so this label is the only thing that
// tells a screen reader that anything happened to the show Dan just acted on.
//
// Only the close-out has a spelling. A send's departure is drawn by SendDelightRow, which says what it
// is in its own words, and giving that a second wording here is two sentences for one fact (#843).
enum DepartureCopy {
    static func spokenClosedOut(showName: String) -> String { "\(showName), closed out" }
}
