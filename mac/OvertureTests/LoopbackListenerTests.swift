import Testing
import Foundation
import Network

// Regression guard for #51: the OAuth loopback listener must report the OS-assigned
// port only after it is actually bound. Reading it too early returned 0, which made
// the redirect_uri http://127.0.0.1:0 — an un-connectable address that left Google's
// consent page hanging forever.
//
// Coverage note (#88): these assert the listener reaches `.ready` and hands back a real,
// non-zero port bound to the 127.0.0.1 (IPv4) endpoint it was pinned to — which is exactly
// what #51 needs (a connectable IPv4 redirect address, never :0). An earlier test opened a
// live TCP round-trip to that port; on this loopback setup the client routinely never reached
// `.ready` (it sat retrying), which froze the whole `xcodebuild test` run for minutes. A live
// socket round-trip is the wrong thing to assert in a unit test, so it was removed in favor of
// these fast, deterministic bind checks.
@Suite("Loopback OAuth listener")
struct LoopbackListenerTests {
    @Test func bindsToARealNonZeroPort() async throws {
        let (listener, port) = try await LoopbackListener.start(queue: .global()) { conn in
            conn.cancel()
        }
        defer { listener.cancel() }
        #expect(port != 0)
    }

    @Test func bindsSuccessfullyWithinAnExplicitTimeout() async throws {
        // The bind timeout (#54) must not interfere with the normal, fast happy path.
        let (listener, port) = try await LoopbackListener.start(queue: .global(), timeout: 5) { $0.cancel() }
        defer { listener.cancel() }
        #expect(port != 0)
    }

    // A one-shot latch so a connection's state handler resolves the round-trip exactly once.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func fire() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
    }

    // The live round-trip the header notes was removed for "routinely never reaching .ready": that WAS
    // the bug. The bind-timeout task did `try? await Task.sleep` then `listener.cancel()`; when .ready
    // fired and cancelled that task, the swallowed cancellation fell through to cancel the just-ready
    // listener, so a client could never connect (and Google's redirect hit a dead port). With the sleep's
    // cancellation propagated, a ready listener stays alive and accepts. A 3s ceiling keeps this from ever
    // freezing the suite the way the old version did.
    @Test func aReadyListenerStaysAliveAndAcceptsAConnection() async throws {
        let queue = DispatchQueue(label: "test-loopback-roundtrip")
        let (listener, port) = try await LoopbackListener.start(queue: queue) { conn in
            conn.start(queue: queue)
            conn.send(content: Data("hi".utf8), completion: .contentProcessed { _ in conn.cancel() })
        }
        defer { listener.cancel() }

        let connected: Bool = await withCheckedContinuation { cont in
            let once = Once()
            let client = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            client.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.fire() { cont.resume(returning: true) }; client.cancel()
                case .failed, .cancelled: if once.fire() { cont.resume(returning: false) }
                default: break
                }
            }
            client.start(queue: queue)
            Task { try? await Task.sleep(nanoseconds: 3_000_000_000); if once.fire() { cont.resume(returning: false) } }
        }
        #expect(connected)
    }
}
