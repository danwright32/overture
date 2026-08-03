import Testing
import Foundation
import Observation

// #1930: an answer that has not changed must not tell anybody it has.
//
// @Observable's generated setter notifies on every assignment, not on every CHANGE, so
// `isConnected = load()` announces a mutation even when the answer is the same true it was a moment ago.
// Every surface reading it then re-renders, and one of those surfaces is the queue, whose body derives all
// 724 prospects on its first line. The reply check re-reads the token on every reconcile tick and a send
// re-reads it on every failure, so this fires on a schedule, for no change and no user action.
//
// Writing only on a real change is the whole fix. It is observable for real (Observation reports it), so
// this is exercised rather than pinned as source shape.
@MainActor
@Suite("An unchanged Gmail answer notifies nobody (#1930)")
struct UnchangedRefreshInvalidatesNothingTests {
    // A settable answer the injected loader reads, so a test can change what the source says between
    // refreshes without capturing a mutable local in an escaping closure.
    private final class Source {
        var answer: Bool
        init(_ answer: Bool) { self.answer = answer }
    }

    // Observation's onChange handler is @Sendable, so the "did anybody hear it" flag cannot be a captured
    // local. A lock keeps the write legal from whichever thread the notification arrives on.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func raise() { lock.lock(); value = true; lock.unlock() }
        var raised: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    @Test func refreshingToTheSameAnswerNotifiesNobody() {
        let source = Source(true)
        let connection = GmailConnection(load: { source.answer })
        let notified = Flag()
        withObservationTracking { _ = connection.isConnected } onChange: { notified.raise() }

        connection.refresh()

        #expect(connection.isConnected)
        #expect(!notified.raised, "an unchanged answer must not invalidate the views reading it")
    }

    // The other half, and the one that matters more: a token that has actually gone means every surface
    // reading it has to hear about it. A "don't notify" guard that over-applies would silently leave the
    // queue offering Send with no Gmail behind it.
    @Test func refreshingToADifferentAnswerStillNotifies() {
        let source = Source(true)
        let connection = GmailConnection(load: { source.answer })
        let notified = Flag()
        withObservationTracking { _ = connection.isConnected } onChange: { notified.raise() }

        source.answer = false
        connection.refresh()

        #expect(!connection.isConnected)
        #expect(notified.raised, "a revoked credential must reach every surface reading it")
    }

    // The read-and-answer form takes the same path, so the caller that must not act on a cached value
    // (a failed send, a background check) still gets the fresh answer.
    @Test func theRefreshedReadStillReportsTheCurrentAnswer() {
        let source = Source(false)
        let connection = GmailConnection(load: { source.answer })
        #expect(!connection.refreshedIsConnected())

        source.answer = true
        #expect(connection.refreshedIsConnected())
    }
}
