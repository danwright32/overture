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

    // #1167: the pre-browser probe cannot catch a listener that only dies AFTER Overture backgrounds while
    // Dan is on Google's consent screen. A heartbeat re-probes partway through the wait: if the listener has
    // gone unreachable and no redirect has arrived, connect() fails fast with the same retryable error
    // instead of waiting out the full give-up clock. Here the probe passes once (pre-browser) then reports
    // dead (heartbeat), and the long hardTimeout proves the failure came from the heartbeat, not the clock.
    @Test func aListenerThatDiesMidWaitFailsFastNotAtTheTimeout() async throws {
        let manager = GmailAuthManager()
        let clientURL = try tmpClient()
        defer { try? FileManager.default.removeItem(at: clientURL) }

        let calls = CallCounter()
        var thrown: GmailAuthManager.AuthError?
        do {
            try await manager.connect(
                clientURL: clientURL,
                openBrowser: { _ in },
                probe: { _ in await calls.tick() == 1 },   // alive pre-browser, dead on the heartbeat
                hardTimeout: 30,                            // long: a pass here proves we did NOT wait it out
                heartbeatInterval: 0.1)
            Issue.record("expected connect() to fail fast when the listener dies mid-wait")
        } catch let error as GmailAuthManager.AuthError {
            thrown = error
        }
        guard case .listenerUnreachable = thrown else {
            Issue.record("expected .listenerUnreachable from the heartbeat, got \(String(describing: thrown))")
            return
        }
    }

    // The heartbeat must NOT false-fire on a healthy listener. Running the REAL probe against a genuinely
    // live listener mid-wait, connect() must still fail only by TIMING OUT (no redirect arrives in a test),
    // never by the heartbeat wrongly reporting the live listener dead or its throwaway connection corrupting
    // the waiter.
    @Test func aHealthyListenerSurvivesTheHeartbeatAndTimesOutInstead() async throws {
        let manager = GmailAuthManager()
        let clientURL = try tmpClient()
        defer { try? FileManager.default.removeItem(at: clientURL) }

        var thrown: GmailAuthManager.AuthError?
        do {
            try await manager.connect(clientURL: clientURL, openBrowser: { _ in },
                                      hardTimeout: 0.8, heartbeatInterval: 0.2)
            Issue.record("expected a timeout (no redirect ever arrives in a test)")
        } catch let error as GmailAuthManager.AuthError {
            thrown = error
        }
        guard case .exchangeFailed = thrown else {
            Issue.record("expected a timeout (.exchangeFailed), got \(String(describing: thrown))")
            return
        }
    }
}

// Counts probe calls across suspension points so a test probe can answer differently on the pre-browser
// check (call 1) than on the heartbeat (call 2+).
private actor CallCounter {
    private var n = 0
    func tick() -> Int { n += 1; return n }
}
