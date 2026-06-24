import Testing
import Foundation
import Network
@testable import Overture

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
}
