import Foundation

// #2760: which run's takeover is on screen, and how far each launch's listing read has got.
//
// This was three single `@State` values on RootView (`prepSheetShown`, `listingReadProgress`,
// `listingReadStartedAt`), shared by both launches because there was only ever one run. The first run to
// finish set `prepSheetShown = false` and dismissed the takeover out from under the second, and the
// `defer { listingReadProgress = nil }` at the end of one launch wiped the other's live count while it was
// still advancing.
//
// It lives here rather than in the view for the reason #863 states: a rule written inside a SwiftUI body is
// unreachable by any test, which is how "hide only the run that ended" comes to be written once and then
// quietly broken by an unrelated edit.
//
// A value type held in one `@State`, not an observable object: it is small, it changes only on real events
// (a launch, a listing tick, a run ending), and one `@State` mutation per event is what the view already
// paid for.
struct RunTakeover: Equatable {
    // In the order they went up. There is one sheet, so one of them is on screen, and it is the one that
    // got there FIRST: a rule of "whichever started last" would swap the content Dan is reading out from
    // under him, which is the same defect as dismissing it.
    private var order: [RunSlot] = []
    private var listing: [RunSlot: RunProgressView.Snapshot] = [:]
    private var listingStarts: [RunSlot: Date] = [:]

    var presented: RunSlot? { order.first }

    func isShown(_ slot: RunSlot) -> Bool { order.contains(slot) }

    // Idempotent: a run that announces itself twice (the launch, then the watcher noticing it) is one
    // takeover, not two, or one hide could not close it.
    mutating func show(_ slot: RunSlot) {
        guard !order.contains(slot) else { return }
        order.append(slot)
    }

    // Only this slot. THIS is the fix: the other run's screen survives its neighbour ending.
    //
    // The listing read goes with it, because that phase belongs to the screen: a stamp left behind would
    // make the next run's first tick read as having been going since the last one.
    mutating func hide(_ slot: RunSlot) {
        order.removeAll { $0 == slot }
        listing[slot] = nil
        listingStarts[slot] = nil
    }

    // What the sheet's own dismissal means: close the one on screen, and leave any other alone.
    mutating func hidePresented() {
        guard let slot = presented else { return }
        hide(slot)
    }

    // MARK: - The listing read

    // The launch's own first phase, the app rendering each show's listing page. It runs in process and has
    // no marker file, so its COUNT is its still-alive evidence, which is exactly why two launches cannot
    // share one.
    mutating func startListingRead(_ slot: RunSlot, at date: Date) {
        listingStarts[slot] = date
        listing[slot] = .init(completed: 0, total: 0, advancedAt: date)
    }

    mutating func recordListingProgress(_ slot: RunSlot, completed: Int, total: Int, at date: Date) {
        listing[slot] = .init(completed: completed, total: total, advancedAt: date)
    }

    // Both halves, together. The count is what the takeover renders and the stamp is what its elapsed
    // clock counts from, so a stamp left behind would make the NEXT run's first tick read as having been
    // going since the last one (L74: an age anchored to a stale instant).
    mutating func finishListingRead(_ slot: RunSlot) {
        listing[slot] = nil
        listingStarts[slot] = nil
    }

    func listingProgress(_ slot: RunSlot) -> RunProgressView.Snapshot? { listing[slot] }

    func listingStartedAt(_ slot: RunSlot) -> Date? { listingStarts[slot] }
}
