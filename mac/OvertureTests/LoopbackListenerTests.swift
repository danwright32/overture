import Testing
import Foundation
import Network
@testable import Overture

// Regression guard for #51: the OAuth loopback listener must report the OS-assigned
// port only after it is actually bound. Reading it too early returned 0, which made
// the redirect_uri http://127.0.0.1:0 — an un-connectable address that left Google's
// consent page hanging forever.
@Suite("Loopback OAuth listener")
struct LoopbackListenerTests {
    @Test func bindsToARealNonZeroPort() async throws {
        let (listener, port) = try await LoopbackListener.start(queue: .global()) { conn in
            conn.cancel()
        }
        defer { listener.cancel() }
        #expect(port != 0)
    }

    @Test func theReportedPortAcceptsAnIPv4LoopbackConnection() async throws {
        let (listener, port) = try await LoopbackListener.start(queue: .global()) { conn in
            conn.cancel()
        }
        defer { listener.cancel() }

        // Proves the port we hand Google is real and reachable over IPv4 loopback —
        // exactly the connection the browser makes when Google redirects back.
        let conn = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        defer { conn.cancel() }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.stateUpdateHandler = nil
                    cont.resume(returning: ())
                case .failed(let error):
                    conn.stateUpdateHandler = nil
                    cont.resume(throwing: error)
                default:
                    break
                }
            }
            conn.start(queue: .global())
        }
    }
}
