import Foundation
import AppKit
import Network
import CryptoKit

// Runs the live OAuth desktop flow: opens Google's consent page in the browser,
// catches the redirect on a loopback listener, exchanges the code for tokens, and
// persists them. Also vends a fresh access token (refreshing when stale). Sending
// nothing here; this only obtains permission.

@MainActor
final class GmailAuthManager {
    static let shared = GmailAuthManager()

    enum AuthError: LocalizedError {
        case noClientConfig, notConnected, listenerFailed, listenerUnreachable, stateMismatch, exchangeFailed(String), refreshFailed(String), authExpired, tokenSaveFailed, alreadyConnecting
        var errorDescription: String? {
            switch self {
            case .noClientConfig: return "Gmail client config is missing. Re-run the Google setup."
            case .notConnected: return "Gmail isn't connected. Use Connect Gmail first."
            case .listenerFailed: return "Couldn't open the local login listener."
            case .listenerUnreachable: return "Overture couldn't start the Gmail sign-in on this Mac, so it didn't open your browser."
            case .stateMismatch: return "Login response didn't match the request. Try again."
            case .exchangeFailed(let m): return "Login failed: \(m)"
            case .refreshFailed(let m): return "Gmail couldn't refresh right now (temporary): \(m)"
            case .authExpired: return "Gmail access expired or was revoked. Click Connect Gmail to reconnect."
            case .tokenSaveFailed: return "Couldn't save the Gmail credentials to disk. Check available storage and try Connect Gmail again."
            case .alreadyConnecting: return "A Gmail connection is already in progress. Finish it in the browser."
            }
        }
    }

    private var listener: NWListener?
    private var pendingState: String?
    private var pendingPKCE: PKCE?
    private var codeContinuation: CheckedContinuation<String, Error>?
    private var timeoutTask: Task<Void, Never>?
    // The re-entrancy latch. A live connect binds a loopback listener on a throwaway port; a SECOND
    // connect() cancelling the first's listener on the very port Google is about to redirect to is what
    // produced "Safari can't connect to 127.0.0.1" (a single Connect tap can fire the SwiftUI toolbar
    // action twice). Set/cleared only via begin/endConnectAttempt below, which are the seam the
    // re-entrancy rule is tested through.
    private var isConnecting = false

    // Atomically claims the connect flow. Returns false if one is already in flight (so the caller must
    // NOT proceed, and in particular must not tear down the live listener). @MainActor, and there is no
    // await between the check and the set, so two calls racing on the main actor can never both win.
    func beginConnectAttempt() -> Bool {
        if isConnecting { return false }
        isConnecting = true
        return true
    }

    func endConnectAttempt() { isConnecting = false }

    // copy-inventory:ignore-start  developer diagnostic log to a file, not the app's own voice (#915)
    // Traces the connect flow to ~/Library/Logs/Overture/gmail-connect-debug.log. The app runs resident
    // via a LaunchAgent whose stdout/stderr are separate, and NSLog did not surface in `log show`, so a
    // dedicated file is the reliable way to see exactly how far a failing connect got.
    nonisolated static func connectDebugLog(_ line: String) {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Overture", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("gmail-connect-debug.log")
        let entry = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(Data(entry.utf8)); try? handle.close()
        } else {
            try? entry.data(using: .utf8)?.write(to: url)
        }
    }
    // copy-inventory:ignore-end

    var isConnected: Bool { GmailCredentials.isConnected }

    // Begin the consent flow: open the browser, await the loopback redirect, exchange
    // the code, and store tokens. Throws on any failure; sends nothing.
    // clientURL / openBrowser / probe / hardTimeout are injected (defaulting to the real ones) so the
    // health-check-before-browser behavior (#1163) is unit-testable without a live browser or network.
    func connect(
        clientURL: URL = GmailCredentials.clientConfigURL,
        openBrowser: (URL) -> Void = { NSWorkspace.shared.open($0) },
        probe: (UInt16) async -> Bool = { await GmailAuthManager.probeListenerReachable(port: $0) },
        hardTimeout: TimeInterval = 90
    ) async throws {
        // Refuse a second attempt while one is in flight: the old code cancelled the prior attempt's
        // listener at the top of every connect(), and a double-fired Connect tap then killed the live
        // listener on the exact port Google was redirecting to. Claimed synchronously before any await.
        guard beginConnectAttempt() else { throw AuthError.alreadyConnecting }
        defer { endConnectAttempt() }
        // copy-inventory:ignore-start  developer diagnostic + a system activity reason, not the app's voice (#915)
        Self.connectDebugLog("connect() begin")

        // Hold an activity assertion for the whole flow so macOS App Nap does NOT suspend Overture while
        // it waits in the BACKGROUND (Safari is frontmost during consent) for the loopback redirect. A
        // napped app stops servicing its main dispatch queue, so the loopback listener silently stops
        // accepting connections and Google's redirect hits a dead port ("Safari can't connect to
        // 127.0.0.1"), instantly and every time. Ended when connect() returns or throws.
        let napBlocker = ProcessInfo.processInfo.beginActivity(options: [.userInitiated],
                                                               reason: "Connecting Gmail")
        // copy-inventory:ignore-end
        defer { ProcessInfo.processInfo.endActivity(napBlocker) }

        guard let client = GmailCredentials.loadClient(from: clientURL) else { throw AuthError.noClientConfig }

        // Cancel any half-finished PRIOR attempt (one that already ended and cleared the latch but left a
        // dead listener/tab). The latch above guarantees this never runs against a still-live attempt.
        cancelInFlight()

        let port = try await startListener()
        // copy-inventory:ignore-start  developer diagnostic log, not the app's voice (#915)
        Self.connectDebugLog("listener ready on 127.0.0.1:\(port)")
        // copy-inventory:ignore-end

        // #1163: confirm the just-bound listener actually accepts a connection BEFORE opening the browser.
        // A listener that reported .ready but holds no accepting socket would otherwise send Dan to a dead
        // "can't connect to 127.0.0.1" tab and leave connect() waiting the whole give-up window with no
        // actionable failure. Catching it here fails in ~2s with a specific, retryable error and no dead
        // tab. Safe against the live flow: no codeContinuation exists yet, so the probe's own throwaway
        // connection resolves nothing when the listener handles it.
        guard await probe(UInt16(port)) else {
            // copy-inventory:ignore-start  developer diagnostic log, not the app's voice (#915)
            Self.connectDebugLog("listener probe failed on 127.0.0.1:\(port); aborting before opening the browser")
            // copy-inventory:ignore-end
            stopListener()
            throw AuthError.listenerUnreachable
        }

        let redirect = "http://127.0.0.1:\(port)"
        let pkce = GoogleOAuth.makePKCE(verifierBytes: Self.randomBytes(32))
        let state = Self.randomURLSafe(16)
        pendingState = state
        pendingPKCE = pkce

        let config = OAuthConfig(clientId: client.clientId, clientSecret: client.clientSecret,
                                 redirectURI: redirect, scopes: OAuthConfig.gmailScopes)
        let authURL = GoogleOAuth.authorizationURL(config: config, pkce: pkce, state: state,
                                                   loginHint: SendIdentity.danWright.email)
        openBrowser(authURL)
        // copy-inventory:ignore-start  developer diagnostic log, not the app's voice (#915)
        Self.connectDebugLog("opened browser to Google; awaiting redirect on port \(port)")
        // copy-inventory:ignore-end

        // Auto-give-up so the UI can never deadlock on "Connecting…" if the redirect
        // never arrives (stale tab, Google-side hang, etc.).
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(hardTimeout * 1_000_000_000))
            await MainActor.run { self?.failTimeout() }
        }

        let code = try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, Error>) in
            codeContinuation = c
        }
        timeoutTask?.cancel()
        stopListener()

        let tokens = try await exchange(config: config, code: code, pkce: pkce)
        try persistExchangedTokens(tokens)
        // #1144: Dan just granted consent (including the settings scope), so fetch and cache his styled
        // Gmail signature now. Best-effort: a failure here leaves any stored signature intact and never
        // blocks the connect from succeeding.
        await GmailSignatureService.refresh()
    }

    // Split from connect() so a failed save after a real consent grant is testable without the
    // live browser/network round trip (#484): a save failure here must throw, not disappear,
    // since Dan has already seen Google's consent screen and has no other signal something
    // went wrong.
    func persistExchangedTokens(_ tokens: OAuthTokens, to url: URL = GmailCredentials.tokenURL) throws {
        guard let refresh = tokens.refreshToken else {
            throw AuthError.exchangeFailed("Google did not return a refresh token. Revoke prior access and retry.")
        }
        let stored = StoredTokens(refreshToken: refresh, accessToken: tokens.accessToken,
                                  accessTokenExpiry: tokens.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) })
        guard GmailCredentials.saveTokens(stored, to: url) else { throw AuthError.tokenSaveFailed }
    }

    // A valid access token, refreshing via the stored refresh token if stale.
    // URLs and the HTTP fetch are injectable so the refresh + auth-expiry handling (clear
    // the dead token, surface authExpired) is unit-testable without the network (#55).
    func validAccessToken(now: Date = Date(),
                          clientURL: URL = GmailCredentials.clientConfigURL,
                          tokenURL: URL = GmailCredentials.tokenURL,
                          fetch: (URLRequest) async throws -> (Data, URLResponse) = { try await GmailNetworking.session.data(for: $0) }
    ) async throws -> String {
        guard let client = GmailCredentials.loadClient(from: clientURL) else { throw AuthError.noClientConfig }
        guard var stored = GmailCredentials.loadTokens(from: tokenURL) else { throw AuthError.notConnected }
        if stored.isFresh(now: now), let token = stored.accessToken { return token }

        let config = OAuthConfig(clientId: client.clientId, clientSecret: client.clientSecret,
                                 redirectURI: "http://127.0.0.1", scopes: OAuthConfig.gmailScopes)
        let req = GoogleOAuth.refreshRequest(config: config, refreshToken: stored.refreshToken)
        let (data, resp) = try await fetch(req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        switch GoogleOAuth.interpretRefreshResponse(status: status, data: data) {
        case .success(let tokens):
            stored.accessToken = tokens.accessToken
            stored.accessTokenExpiry = tokens.expiresIn.map { now.addingTimeInterval(TimeInterval($0)) }
            guard GmailCredentials.saveTokens(stored, to: tokenURL) else { throw AuthError.tokenSaveFailed }
            return tokens.accessToken
        case .failure(.authExpired):
            // The refresh token is dead (revoked/expired). Clear it so the app shows as
            // disconnected and Dan is prompted to reconnect, instead of failing opaquely.
            GmailCredentials.clearTokens(at: tokenURL)
            throw AuthError.authExpired
        case .failure(.transient):
            throw AuthError.refreshFailed(String(data: data, encoding: .utf8) ?? "unknown")
        }
    }

    func disconnect() { GmailCredentials.clearTokens() }

    // Called when a live API call rejects the token (revoked/expired mid-session): drop
    // the stored token so the app shows as disconnected and prompts a reconnect (#50).
    func signalAuthExpired() { GmailCredentials.clearTokens() }

    // MARK: - token exchange

    private func exchange(config: OAuthConfig, code: String, pkce: PKCE) async throws -> OAuthTokens {
        let req = GoogleOAuth.tokenExchangeRequest(config: config, code: code, pkce: pkce)
        // #468: not covered by connect()'s own 120s browser-redirect timeout (that timer is
        // cancelled right before this call runs), so this genuinely had no bound before.
        let (data, resp) = try await GmailNetworking.session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let tokens = try? JSONDecoder().decode(OAuthTokens.self, from: data) else {
            throw AuthError.exchangeFailed(String(data: data, encoding: .utf8) ?? "unknown")
        }
        return tokens
    }

    // MARK: - loopback listener

    // The loopback listener runs on its OWN dedicated queue, NOT the app's main queue. When Overture
    // opens the browser it goes to the background, and a listener bound to the main queue could have its
    // socket torn down while the main thread is throttled, so it reported .ready and then silently held no
    // socket (the redirect hit a dead port). A private serial queue is always serviced.
    nonisolated private static let listenerQueue = DispatchQueue(label: "com.danwright.overture.gmail-loopback")

    // #1163: a fast health check on the just-bound listener, BEFORE opening the browser. Opens a throwaway
    // loopback connection to the port and reports whether it can actually establish; the real Google
    // redirect will hit that same port from the browser. A dead listener (reported .ready but holds no
    // accepting socket) fails this in ~2s, so connect() can abort with an actionable error instead of
    // stranding Dan on a "can't connect to 127.0.0.1" tab through the whole give-up window. A same-process
    // probe cannot reproduce a listener that only dies AFTER the app backgrounds (documented false
    // negative), so it never wrongly reports a healthy listener as dead: a false negative just falls
    // through to the shorter give-up + retry backstop, it never aborts a working sign-in.
    nonisolated static func probeListenerReachable(port: UInt16, timeout: TimeInterval = 2) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        let conn = NWConnection(host: "127.0.0.1", port: nwPort, using: .tcp)
        let once = ProbeLatch()
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.fire() { cont.resume(returning: true) }
                    conn.cancel()
                case .failed, .cancelled:
                    if once.fire() { cont.resume(returning: false) }
                default:
                    break
                }
            }
            conn.start(queue: Self.listenerQueue)
            // Bound the probe so a wedged connect attempt can't hang the whole connect flow.
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if once.fire() { cont.resume(returning: false); conn.cancel() }
            }
        }
    }

    private func startListener() async throws -> Int {
        // The port is only real once the listener is bound and .ready; reading it
        // earlier returned 0, which made redirect_uri=http://127.0.0.1:0 and hung
        // Google's consent page (#51). LoopbackListener waits for .ready and forces IPv4.
        let (listener, port) = try await LoopbackListener.start(
            queue: Self.listenerQueue,
            log: { Self.connectDebugLog($0) }
        ) { [weak self] conn in
            conn.start(queue: Self.listenerQueue)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                Task { @MainActor in self?.handleRedirect(request: request, conn: conn) }
            }
        }
        self.listener = listener
        return Int(port)
    }

    private func handleRedirect(request: String, conn: NWConnection) {
        // copy-inventory:ignore-start  developer diagnostic log, not the app's voice (#915)
        Self.connectDebugLog("redirect received by the listener")
        // copy-inventory:ignore-end
        // First line: "GET /?code=...&state=... HTTP/1.1"
        let firstLine = request.split(separator: "\r\n").first.map(String.init) ?? ""
        let path = firstLine.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        let comps = URLComponents(string: "http://127.0.0.1\(path)")
        let code = comps?.queryItems?.first { $0.name == "code" }?.value
        let state = comps?.queryItems?.first { $0.name == "state" }?.value

        // #1163: only a genuine OAuth redirect resolves the waiting sign-in. A connection carrying neither a
        // code nor a state is not the redirect: it is the pre-browser health-check probe, a port scan, or a
        // browser prefetch. Resolving the waiter from one of those (a real Google redirect always carries
        // state) would fail a healthy connect with a bogus state mismatch, which is exactly how the probe
        // could corrupt the flow. Drop it without touching codeContinuation.
        guard code != nil || state != nil else { conn.cancel(); return }

        let body = "<html><body style='font-family:-apple-system;padding:40px'>Overture is connected to Gmail. You can close this tab.</body></html>"
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in conn.cancel() })

        let cont = codeContinuation
        codeContinuation = nil
        guard state == pendingState else { cont?.resume(throwing: AuthError.stateMismatch); return }
        guard let code else { cont?.resume(throwing: AuthError.exchangeFailed("no code in redirect")); return }
        cont?.resume(returning: code)
    }

    private func stopListener() { listener?.cancel(); listener = nil }

    // Tears down any in-flight flow: cancels the listener and fails a pending wait.
    private func cancelInFlight() {
        // copy-inventory:ignore-start  developer diagnostic log, not the app's own voice (#915)
        if codeContinuation != nil {
            NSLog("[Overture] Gmail connect: tearing down an attempt that was still waiting for the redirect.")
        }
        // copy-inventory:ignore-end
        timeoutTask?.cancel(); timeoutTask = nil
        stopListener()
        let cont = codeContinuation
        codeContinuation = nil
        pendingState = nil
        pendingPKCE = nil
        cont?.resume(throwing: CancellationError())
    }

    private func failTimeout() {
        guard codeContinuation != nil else { return }
        // copy-inventory:ignore-start  developer diagnostic log, not the app's voice (#915)
        Self.connectDebugLog("timed out waiting for the redirect (120s)")
        // copy-inventory:ignore-end
        stopListener()
        let cont = codeContinuation
        codeContinuation = nil
        pendingState = nil
        pendingPKCE = nil
        cont?.resume(throwing: AuthError.exchangeFailed("Timed out waiting for Google. Close any old browser tabs and try Connect Gmail again."))
    }

    // MARK: - randomness

    private static func randomBytes(_ n: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &bytes)
        return Data(bytes)
    }
    private static func randomURLSafe(_ n: Int) -> String { GoogleOAuth.base64url(randomBytes(n)) }
}

// One-shot resume guard for the reachability probe: the NWConnection state handler and the timeout Task
// race to resolve the continuation, but a CheckedContinuation must resume exactly once.
private final class ProbeLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func fire() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}
