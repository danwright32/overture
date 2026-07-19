import Testing
import Foundation

// Dan (2026-07-18): the "too far" location filter lived in the window's own NSToolbar, which macOS
// keeps visible even while Archive/Sources/Days off/Patterns/Voice guidance are open as sheets over
// the same window, so it read as clutter that showed up "everywhere".
//
// #1134: stage-only navigation removed the QueueFilterBar (and the too-far / discipline / high-fit /
// pending-bookings filters with it) entirely. QueueView is a SwiftUI view and isn't unit-testable in
// isolation, so this guards the source shape: neither the old standalone toolbar filter nor the
// in-queue filter bar may come back.
@Suite("The queue carries no standalone location filter")
struct LocationFilterInQueueOnlyGuardTests {
    private var queueView: String { SourceGuardHelper.source("Overture/UI/QueueView.swift") }

    @Test func thereIsNoStandaloneTooFarToolbarAnymore() {
        #expect(!queueView.contains("tooFarToolbar"))
        #expect(!queueView.contains("location.slash"))
    }

    // #1134: the whole filter bar is gone (stage pills are the only way to choose what shows), so neither
    // it nor the removed filter state may reappear.
    @Test func theFilterBarAndItsStateAreGone() {
        #expect(!queueView.contains("QueueFilterBar"))
        #expect(!queueView.contains("showTooFarOnly"))
        #expect(!queueView.contains("disciplineFilter"))
    }
}
