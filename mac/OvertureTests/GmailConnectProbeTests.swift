import Testing
import Foundation
import Network
@testable import Overture

// #1163: the live Gmail connect used to open the browser and then wait the full internal timeout for a
// loopback redirect that, when the handoff was broken (the listener reports .ready but holds no accepting
// socket), never arrived. That left Dan on a dead browser tab and a silent "Connecting…" for the whole
// give-up window before any actionable failure. connect() now health-checks the just-bound listener BEFORE
// opening the browser: if a throwaway loopback connection can't reach it, connect() aborts at once with a
// specific, actionable error and never sends Dan to the browser, instead of a long silent wait.
@MainActor
@Suite("Gmail connect health-checks the loopback listener before opening the browser")
struct GmailConnectProbeTests {
    private func tmpClient() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try Data(#"{"clientId":"cid","clientSecret":"sec"}"#.utf8).write(to: url)
        return url
    }

    @Test func anUnreachableListenerAbortsBeforeOpeningTheBrowser() async throws {
        let manager = GmailAuthManager()
        let clientURL = try tmpClient()
        defer { try? FileManager.default.removeItem(at: clientURL) }

        var browserOpened = false
        do {
            try await manager.connect(
                clientURL: clientURL,
                openBrowser: { _ in browserOpened = true },
                probe: { _ in false },
                hardTimeout: 0.4)
            Issue.record("expected connect() to throw when the listener probe fails")
        } catch let error as GmailAuthManager.AuthError {
            guard case .listenerUnreachable = error else {
                Issue.record("expected .listenerUnreachable, got \(error)")
                return
            }
        }
        // The whole point: a dead handoff must fail fast and NOT strand Dan on a browser tab.
        #expect(browserOpened == false)
    }

    @Test func aReachableListenerProceedsToOpenTheBrowser() async throws {
        let manager = GmailAuthManager()
        let clientURL = try tmpClient()
        defer { try? FileManager.default.removeItem(at: clientURL) }

        var browserOpened = false
        // A reachable probe lets the flow proceed to the browser; a short hard timeout keeps the test fast
        // (no real redirect ever arrives, so connect() gives up quickly instead of hanging).
        _ = try? await manager.connect(
            clientURL: clientURL,
            openBrowser: { _ in browserOpened = true },
            probe: { _ in true },
            hardTimeout: 0.4)
        #expect(browserOpened == true)
    }

    // The REAL health check opens its own throwaway connection to the live listener. That connection fires
    // the listener's newConnectionHandler, so the probe must NOT be mistaken for the OAuth redirect: a
    // stray connection carrying no code and no state has to be dropped, or it would resolve the waiting
    // sign-in with a bogus state mismatch and fail a perfectly healthy connect. Here we run the DEFAULT
    // (real) probe against the real listener and give up fast: a healthy listener must pass the probe and
    // then fail by TIMING OUT (the redirect never arrives in a test), never by the probe corrupting it.
    @Test func theRealHealthCheckDoesNotCorruptAHealthyListener() async throws {
        let manager = GmailAuthManager()
        let clientURL = try tmpClient()
        defer { try? FileManager.default.removeItem(at: clientURL) }

        var thrown: GmailAuthManager.AuthError?
        do {
            try await manager.connect(clientURL: clientURL, openBrowser: { _ in }, hardTimeout: 0.6)
            Issue.record("expected connect() to fail (no redirect ever arrives in a test)")
        } catch let error as GmailAuthManager.AuthError {
            thrown = error
        }
        // It must be the timeout, not a .stateMismatch or .listenerUnreachable caused by the probe itself.
        guard case .exchangeFailed = thrown else {
            Issue.record("expected a timeout (.exchangeFailed), got \(String(describing: thrown))")
            return
        }
    }

    // The probe reaches a genuinely-bound loopback listener, the same way the browser's redirect will.
    @Test func theProbeReachesALiveListener() async throws {
        let (listener, port) = try await LoopbackListener.start(queue: .global()) { $0.cancel() }
        defer { listener.cancel() }
        let reachable = await GmailAuthManager.probeListenerReachable(port: port)
        #expect(reachable == true)
    }
}
