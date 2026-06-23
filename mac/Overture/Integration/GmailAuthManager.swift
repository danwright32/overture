import Foundation
import AppKit
import Network
import CryptoKit

// Runs the live OAuth desktop flow: opens Google's consent page in the browser,
// catches the redirect on a loopback listener, exchanges the code for tokens, and
// persists them. Also vends a fresh access token (refreshing when stale). Sending
// nothing here — this only obtains permission.

@MainActor
final class GmailAuthManager {
    static let shared = GmailAuthManager()

    enum AuthError: LocalizedError {
        case noClientConfig, notConnected, listenerFailed, stateMismatch, exchangeFailed(String), refreshFailed(String), authExpired
        var errorDescription: String? {
            switch self {
            case .noClientConfig: return "Gmail client config is missing. Re-run the Google setup."
            case .notConnected: return "Gmail isn't connected. Use Connect Gmail first."
            case .listenerFailed: return "Couldn't open the local login listener."
            case .stateMismatch: return "Login response didn't match the request. Try again."
            case .exchangeFailed(let m): return "Login failed: \(m)"
            case .refreshFailed(let m): return "Gmail couldn't refresh right now (temporary): \(m)"
            case .authExpired: return "Gmail access expired or was revoked. Click Connect Gmail to reconnect."
            }
        }
    }

    private var listener: NWListener?
    private var pendingState: String?
    private var pendingPKCE: PKCE?
    private var codeContinuation: CheckedContinuation<String, Error>?
    private var timeoutTask: Task<Void, Never>?

    var isConnected: Bool { GmailCredentials.isConnected }

    // Begin the consent flow: open the browser, await the loopback redirect, exchange
    // the code, and store tokens. Throws on any failure; sends nothing.
    func connect() async throws {
        guard let client = GmailCredentials.loadClient() else { throw AuthError.noClientConfig }

        // Cancel any half-finished prior attempt so a fresh click always starts clean
        // (avoids stale listeners on dead ports that leave old browser tabs hanging).
        cancelInFlight()

        let port = try await startListener()
        let redirect = "http://127.0.0.1:\(port)"
        let pkce = GoogleOAuth.makePKCE(verifierBytes: Self.randomBytes(32))
        let state = Self.randomURLSafe(16)
        pendingState = state
        pendingPKCE = pkce

        let config = OAuthConfig(clientId: client.clientId, clientSecret: client.clientSecret,
                                 redirectURI: redirect, scopes: OAuthConfig.gmailScopes)
        let authURL = GoogleOAuth.authorizationURL(config: config, pkce: pkce, state: state,
                                                   loginHint: "dan@danwrightphotography.com")
        NSWorkspace.shared.open(authURL)

        // Auto-give-up so the UI can never deadlock on "Connecting…" if the redirect
        // never arrives (stale tab, Google-side hang, etc.).
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120 * 1_000_000_000)
            await MainActor.run { self?.failTimeout() }
        }

        let code = try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, Error>) in
            codeContinuation = c
        }
        timeoutTask?.cancel()
        stopListener()

        let tokens = try await exchange(config: config, code: code, pkce: pkce)
        guard let refresh = tokens.refreshToken else {
            throw AuthError.exchangeFailed("Google did not return a refresh token. Revoke prior access and retry.")
        }
        GmailCredentials.saveTokens(StoredTokens(
            refreshToken: refresh, accessToken: tokens.accessToken,
            accessTokenExpiry: tokens.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }))
    }

    // A valid access token, refreshing via the stored refresh token if stale.
    // URLs and the HTTP fetch are injectable so the refresh + auth-expiry handling (clear
    // the dead token, surface authExpired) is unit-testable without the network (#55).
    func validAccessToken(now: Date = Date(),
                          clientURL: URL = GmailCredentials.clientConfigURL,
                          tokenURL: URL = GmailCredentials.tokenURL,
                          fetch: (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }
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
            GmailCredentials.saveTokens(stored, to: tokenURL)
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
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let tokens = try? JSONDecoder().decode(OAuthTokens.self, from: data) else {
            throw AuthError.exchangeFailed(String(data: data, encoding: .utf8) ?? "unknown")
        }
        return tokens
    }

    // MARK: - loopback listener

    private func startListener() async throws -> Int {
        // The port is only real once the listener is bound and .ready; reading it
        // earlier returned 0, which made redirect_uri=http://127.0.0.1:0 and hung
        // Google's consent page (#51). LoopbackListener waits for .ready and forces IPv4.
        let (listener, port) = try await LoopbackListener.start(queue: .main) { [weak self] conn in
            conn.start(queue: .main)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                Task { @MainActor in self?.handleRedirect(request: request, conn: conn) }
            }
        }
        self.listener = listener
        return Int(port)
    }

    private func handleRedirect(request: String, conn: NWConnection) {
        // First line: "GET /?code=...&state=... HTTP/1.1"
        let firstLine = request.split(separator: "\r\n").first.map(String.init) ?? ""
        let path = firstLine.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        let comps = URLComponents(string: "http://127.0.0.1\(path)")
        let code = comps?.queryItems?.first { $0.name == "code" }?.value
        let state = comps?.queryItems?.first { $0.name == "state" }?.value

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
