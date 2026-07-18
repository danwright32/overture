import Foundation

// #1054: when Dan cancels a scout mid-read, the detached reader may already have written some shows
// before it stopped. The old behavior imported them silently, so shows appeared in the queue after he
// hit Cancel. His call: neither always-keep nor always-discard, but ask, showing how many were read.
//
// The rule lives here as a pure function, not inside RootView, so it can be tested: a rule computed in a
// SwiftUI view has drifted under a green suite before (#863). RootView only wires the choice to the UI.
enum CancelledReadDisposition: Equatable {
    // Not a cancel: a run that finished on its own imports its results the normal way.
    case ingest
    // Cancelled with partial shows worth keeping: ask Dan, naming the count.
    case promptKeepOrDiscard(readCount: Int)
    // Cancelled but the reader wrote nothing usable: there is nothing to keep, so close quietly.
    case discardSilently

    static func decide(cancelled: Bool, readCount: Int) -> CancelledReadDisposition {
        guard cancelled else { return .ingest }
        return readCount > 0 ? .promptKeepOrDiscard(readCount: readCount) : .discardSilently
    }
}

// The exact words of the cancel prompt, kept as complete literal templates per case (not joined
// fragments, #copy-inventory) and pluralized so "1 show" never reads as "1 shows". "Read" is deliberate:
// it states what the reader took off the pages, not a promise of how many rows Keep will add (dedup
// against existing prospects can add fewer), so the number never over-promises the queue.
enum CancelledReadCopy {
    static let title = "Scout stopped"
    static let discardLabel = "Discard"

    static func message(readCount n: Int) -> String {
        n == 1 ? "Read 1 show before you cancelled." : "Read \(n) shows before you cancelled."
    }

    static func keepLabel(readCount n: Int) -> String {
        n == 1 ? "Keep 1 show" : "Keep \(n) shows"
    }
}
