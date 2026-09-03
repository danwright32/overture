import Testing
import Foundation

// #3437/#3431: what the Archive reveal does TODAY, written down before the scroll position is moved
// onto a holder, so the extraction is judged against today's behaviour rather than tomorrow's.
//
// THE ORDERING IS THE WHOLE THING. `ArchiveView` sets the persisted scroll position to the reveal's
// target BEFORE asking the proxy to scroll there:
//
//     topKey = key
//     withAnimation { proxy.scrollTo(key, anchor: .center) }
//
// #976 records why: the restore and the jump are two mechanisms aimed at one ScrollView, and pointing the
// persisted position at the target first makes the restore COOPERATE with the jump instead of racing it
// back to a stale row. #1573 is the same collision on the queue, where clearing-and-scrollTo was the bug
// and the row jump was silently dropped, which is why `QueueScrollHolder` drives its position from
// `jumpTarget` and never calls `scrollTo` at all.
//
// So Archive and the Queue solve one problem two ways, deliberately, and an extraction that shares a
// holder between them changes Archive's mechanism rather than moving it. This suite is what says so if
// that happens by accident.
//
// A SOURCE guard for the ordering, and that is a limitation worth stating rather than glossing. The two
// statements sit in a closure handed to `ArchiveReveal.scrollAfterDelay`, and nothing observable
// distinguishes their order from outside: both run, and the difference is a race against SwiftUI's own
// restore that no unit test can lose on purpose. What IS behaviourally testable is the delay and the
// cancellation around them, and `ArchiveRevealCancellationTests` already owns that.
@MainActor
@Suite("The Archive reveal points the position at its target before scrolling (#3437)")
struct ArchiveRevealOrderingGuardTests {
    private var archiveView: String { SourceGuardHelper.source("Overture/UI/ArchiveView.swift") }

    // Read as CODE with comments stripped. The comment above the fix necessarily names both statements,
    // so a raw-text guard would be answered by prose about the thing rather than by the thing (L103, L135).
    private var revealCode: [String] {
        guard let content = SourceGuardHelper.bodyOfFunction(named: "content", in: archiveView) else {
            return []
        }
        return SwiftSource.scannableLines(in: content).map(\.code)
    }

    @Test func theRevealSetsThePositionBeforeItScrolls() {
        let lines = revealCode
        #expect(!lines.isEmpty, "ArchiveView.content could not be read, so this measured nothing")

        let setsPosition = lines.firstIndex { $0.contains("topKey = key") }
        let scrolls = lines.firstIndex { $0.contains("proxy.scrollTo(key") }

        guard let setsPosition, let scrolls else {
            Issue.record(Comment(rawValue: "expected ArchiveView.content to both point the persisted "
                                 + "position at the reveal target and scroll to it. Found the "
                                 + "assignment: \(setsPosition != nil). Found the scroll: \(scrolls != nil)."))
            return
        }
        #expect(setsPosition < scrolls,
                Comment(rawValue: "ArchiveView scrolls to the reveal target at line \(scrolls) BEFORE "
                        + "pointing the persisted position at it at line \(setsPosition). #976: that "
                        + "order is what makes the restore cooperate with the jump instead of racing it "
                        + "back to a stale row."))
    }

    // The positive half, so the guard above cannot be satisfied by a reveal that stopped scrolling.
    @Test func theRevealStillGoesThroughTheCancellableDelay() {
        let lines = revealCode
        #expect(lines.contains { $0.contains("ArchiveReveal.scrollAfterDelay(key:") },
                Comment(rawValue: "the reveal must still run through ArchiveReveal, which is what makes "
                        + "a superseded jump cancellable (#633)"))
    }

    // Archive and the Queue solve one problem two ways ON PURPOSE, and the difference is easy to erase by
    // accident while extracting a shared holder. This is what notices.
    @Test func theQueueHolderStillDrivesItsPositionRatherThanScrolling() {
        let queueView = SourceGuardHelper.source("Overture/UI/QueueView.swift")
        guard let holder = SourceGuardHelper.between("struct QueueScrollHolder", and: "\n}\n",
                                                     in: queueView) else {
            Issue.record("expected to find QueueScrollHolder")
            return
        }
        let code = SwiftSource.scannableLines(in: holder).map(\.code).joined(separator: "\n")
        #expect(code.contains("scrollPosition(id: $topGroup"),
                "QueueScrollHolder must still own the position it was created to own (#1774)")
        #expect(!code.contains("scrollTo"),
                Comment(rawValue: "QueueScrollHolder now calls scrollTo. #1573: clearing-and-scrollTo "
                        + "was the bug there, because the two mechanisms fought over one ScrollView and "
                        + "the row jump was silently dropped. It drives the position from jumpTarget "
                        + "instead, and that is the difference from Archive."))
    }
}
