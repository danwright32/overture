import Testing
import Foundation
@testable import Overture

// #633: ArchiveView's reveal mechanism used `.task(id: highlightedKey)` with `try? await
// Task.sleep(...)` to scroll to a newly revealed row. Because `try?` swallows CancellationError,
// picking two search results in quick succession let the first (superseded) task's scrollTo still
// fire with its stale captured key before the `highlightedKey == key` guard could suppress it.
// ArchiveReveal.scrollAfterDelay extracts that timing so the fix (an explicit cancellation check
// before scrollTo) can be proven directly, without waiting out the real UI timings.
@Suite("Archive reveal cancellation")
struct ArchiveRevealCancellationTests {
    @Test @MainActor func aCancelledRevealNeverScrolls() async {
        var scrolledTo: String?
        let task = Task { @MainActor in
            await ArchiveReveal.scrollAfterDelay(key: "stale") { scrolledTo = $0 }
        }
        task.cancel()
        await task.value
        #expect(scrolledTo == nil,
                "A superseded reveal task scrolled anyway: the cancellation check before scrollTo was removed or bypassed.")
    }

    @Test @MainActor func anUncancelledRevealScrollsToItsKey() async {
        var scrolledTo: String?
        await ArchiveReveal.scrollAfterDelay(key: "k", sleep: { _ in }) { scrolledTo = $0 }
        #expect(scrolledTo == "k")
    }
}
