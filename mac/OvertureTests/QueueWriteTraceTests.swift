import Testing
import Foundation
@testable import Overture

// #1930: the queue's own fingerprint reports which of the inputs it READS moved before a derivation, and
// its most common answer is "nothing this view reads". That answer is trusted to mean the invalidation
// arrived from the screen above, but the screen above holds five live objects the fingerprint deliberately
// cannot look at (#1922: reading one to report it would create the dependency being measured), so
// "nothing" has always meant "nothing I can see".
//
// These are the blind spot. Each object counts its own writes WHERE THEY HAPPEN, which creates no
// dependency on anything, and the screen's fingerprint reads the counts. A render that follows a write
// then names the object that moved instead of reporting silence.
@Suite("A live object counts its writes where they happen (#1930)")
struct QueueWriteTraceTests {
    @Test func writesAreCountedPerObjectAndClearedOnReset() {
        QueueRenderCounter.reset()
        QueueWriteTrace.note(QueueWriteTrace.feedback)
        QueueWriteTrace.note(QueueWriteTrace.feedback)
        QueueWriteTrace.note(QueueWriteTrace.undoStack)

        #expect(QueueRenderCounter.writes(QueueWriteTrace.feedback) == 2)
        #expect(QueueRenderCounter.writes(QueueWriteTrace.undoStack) == 1)
        // An object nothing has touched reads as zero, never as absent, so the fingerprint reports the
        // same shape on every render rather than an input appearing out of nowhere mid-session.
        #expect(QueueRenderCounter.writes(QueueWriteTrace.addLead) == 0)

        QueueRenderCounter.reset()
        #expect(QueueRenderCounter.writes(QueueWriteTrace.feedback) == 0)
    }

    // A count that moved is what the fingerprint turns into a named cause, so the two have to meet: a
    // render taken after a write must report that object rather than silence.
    @Test func aRenderAfterAWriteNamesTheObjectThatMoved() {
        QueueRenderCounter.reset()
        let before = ["writes.feedback": "\(QueueRenderCounter.writes(QueueWriteTrace.feedback))"]
        QueueWriteTrace.note(QueueWriteTrace.feedback)
        let after = ["writes.feedback": "\(QueueRenderCounter.writes(QueueWriteTrace.feedback))"]

        #expect(QueueRenderCounter.reason(for: after, since: before) == "writes.feedback")
    }

    @MainActor @Test func acknowledgingAnActionCountsAsAFeedbackWrite() {
        QueueRenderCounter.reset()
        let feedback = ActionFeedback()
        feedback.acknowledge("Sent")
        #expect(QueueRenderCounter.writes(QueueWriteTrace.feedback) == 1)
        feedback.clear()
        #expect(QueueRenderCounter.writes(QueueWriteTrace.feedback) == 2)
    }

    // A banner mounting and unmounting writes to the shared object too, which is the kind of write nobody
    // thinks of as one: it happens while a sheet opens, with Dan touching nothing that concerns the queue.
    @MainActor @Test func mountingABannerCountsAsAFeedbackWrite() {
        QueueRenderCounter.reset()
        let feedback = ActionFeedback()
        let token = feedback.registerBanner()
        #expect(QueueRenderCounter.writes(QueueWriteTrace.feedback) == 1)
        feedback.releaseBanner(token)
        #expect(QueueRenderCounter.writes(QueueWriteTrace.feedback) == 2)
    }

    @MainActor @Test func askingForTheDayOffPickerCountsAsAWrite() {
        QueueRenderCounter.reset()
        let request = DayOffOfferRequest()
        request.request(key: "k", org: "Org", start: "2026-08-02", end: "2026-08-02")
        #expect(QueueRenderCounter.writes(QueueWriteTrace.dayOffOffer) == 1)
        request.clear()
        #expect(QueueRenderCounter.writes(QueueWriteTrace.dayOffOffer) == 2)
    }

    // Taking and clearing are counted on an EMPTY stack deliberately: a write that changed nothing still
    // invalidated every view holding the object, which is exactly the kind of write this hunts.
    @MainActor @Test func everyUndoStackChangeCountsAsAWrite() {
        QueueRenderCounter.reset()
        let stack = QueueUndoStack()
        _ = stack.takeTop()
        #expect(QueueRenderCounter.writes(QueueWriteTrace.undoStack) == 1)
        stack.clear()
        #expect(QueueRenderCounter.writes(QueueWriteTrace.undoStack) == 2)
    }

    @MainActor @Test func askingForAnUndoCountsAsAWrite() {
        QueueRenderCounter.reset()
        let request = QueueUndoRequest()
        request.request()
        #expect(QueueRenderCounter.writes(QueueWriteTrace.undoRequest) == 1)
    }
}
