import Testing
import Foundation

// #1917: the queue's reply-run line refreshes on a one-second timer, which is right (a finished run's
// line has to disappear promptly, and a live one has to count up). What was not right is what it paid
// for on each tick: the progress file was opened and JSON-decoded every second, on the main thread,
// forever, including while Dan scrolls and including when no reply-classify run has ever started.
//
// `runningLabel` already refuses on its first line when nothing is running, but an argument is evaluated
// before the call, so that guard could not protect against the read. Same shape as #1916, same fix: the
// progress arrives as something the function can decline to look at. The cheap liveness check still runs
// every second, because that is what notices a run STARTING.
@Suite("An idle queue reads no progress file on its timer tick (#1917)")
struct IdleQueueReadsNoProgressFileTests {
    private final class ProgressSource {
        private(set) var reads = 0
        private let progress: ReplyClassifyProgress?
        init(_ progress: ReplyClassifyProgress?) { self.progress = progress }
        func load() -> ReplyClassifyProgress? {
            reads += 1
            return progress
        }
    }

    // The state Overture sits in essentially all the time.
    @Test func nothingRunningMeansTheFileIsNotRead() {
        let source = ProgressSource(ReplyClassifyProgress(version: 1, total: 8, completed: 3))

        let label = ReplyClassifyProgressDecoder.runningLabel(running: false, progress: source.load())

        #expect(label == nil)
        #expect(source.reads == 0)
    }

    // A live run still reads it, once per tick, and still says what it is doing. Without this the suite
    // above would be satisfied by a line that never reads the file at all and so never counts up.
    @Test func aLiveRunStillReadsItOnceAndReportsProgress() {
        let source = ProgressSource(ReplyClassifyProgress(version: 1, total: 8, completed: 3))

        let label = ReplyClassifyProgressDecoder.runningLabel(running: true, progress: source.load())

        #expect(label == "Drafting replies 3 of 8")
        #expect(source.reads == 1)
    }

    // A run that is alive but has not written its total yet reads the file (it has to, to find that out)
    // and still shows nothing, which is the existing contract this must not change.
    @Test func aLiveRunWithNoCountYetReadsTheFileAndShowsNothing() {
        let source = ProgressSource(nil)

        let label = ReplyClassifyProgressDecoder.runningLabel(running: true, progress: source.load())

        #expect(label == nil)
        #expect(source.reads == 1)
    }
}
