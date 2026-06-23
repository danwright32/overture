import Foundation
import CryptoKit

// Constructs the OAuth 2.0 desktop-app flow for Gmail (loopback redirect + PKCE, the
// path Google recommends for native apps). Pure request/URL construction so it is
// testable without the network; the live browser+loopback dance and token storage
// live in GmailAuthManager (built once Dan provides credentials).

struct OAuthConfig: Equatable, Sendable {
    var clientId: String
    var clientSecret: String
    var redirectURI: String   // http://127.0.0.1:<port> (loopback)
    var scopes: [String]

    static let gmailScopes = [
        "https://www.googleapis.com/auth/gmail.send",
        "https://www.googleapis.com/auth/gmail.readonly",
    ]
}

struct PKCE: Equatable, Sendable {
    var verifier: String
    var challenge: String   // S256(verifier)
}

enum GoogleOAuth {
    static let authEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    static let tokenEndpoint = "https://oauth2.googleapis.com/token"

    // PKCE: a random verifier and its SHA-256 challenge, both base64url (no padding).
    static func makePKCE(verifierBytes: Data) -> PKCE {
        let verifier = base64url(verifierBytes)
        let challenge = base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        return PKCE(verifier: verifier, challenge: challenge)
    }

    // The consent URL the app opens in the browser. `access_type=offline` +
    // `prompt=consent` so Google returns a refresh token.
    static func authorizationURL(config: OAuthConfig, pkce: PKCE, state: String, loginHint: String? = nil) -> URL {
        var c = URLComponents(string: authEndpoint)!
        var items: [URLQueryItem] = [
            .init(name: "client_id", value: config.clientId),
            .init(name: "redirect_uri", value: config.redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: config.scopes.joined(separator: " ")),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
        ]
        // Pin the account so a browser signed into multiple Google accounts doesn't
        // stall the consent (the authuser=N confusion).
        if let loginHint { items.append(.init(name: "login_hint", value: loginHint)) }
        c.queryItems = items
        return c.url!
    }

    // Exchanges the authorization code for tokens (includes the verifier for PKCE).
    static func tokenExchangeRequest(config: OAuthConfig, code: String, pkce: PKCE) -> URLRequest {
        formPost(to: tokenEndpoint, fields: [
            "client_id": config.clientId,
            "client_secret": config.clientSecret,
            "code": code,
            "code_verifier": pkce.verifier,
            "grant_type": "authorization_code",
            "redirect_uri": config.redirectURI,
        ])
    }

    // Trades the long-lived refresh token for a fresh access token.
    static func refreshRequest(config: OAuthConfig, refreshToken: String) -> URLRequest {
        formPost(to: tokenEndpoint, fields: [
            "client_id": config.clientId,
            "client_secret": config.clientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ])
    }

    // Why a refresh failed: a dead login Dan must fix vs. a passing blip to retry (#50).
    enum RefreshFailure: Error, Equatable, Sendable { case authExpired, transient }

    // Reads a token-refresh response. invalid_grant (revoked/expired refresh token) or
    // 401 means reconnect; any other non-success, or a 200 we can't parse, is transient
    // so a still-valid saved login is never thrown away over a blip.
    static func interpretRefreshResponse(status: Int, data: Data) -> Result<OAuthTokens, RefreshFailure> {
        if status == 200, let tokens = try? JSONDecoder().decode(OAuthTokens.self, from: data) {
            return .success(tokens)
        }
        let body = String(data: data, encoding: .utf8) ?? ""
        if status == 401 || (status == 400 && body.contains("invalid_grant")) {
            return .failure(.authExpired)
        }
        return .failure(.transient)
    }

    // MARK: - helpers

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formPost(to endpoint: String, fields: [String: String]) -> URLRequest {
        var req = URLRequest(url: URL(string: endpoint)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var comps = URLComponents()
        comps.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        req.httpBody = comps.percentEncodedQuery?.data(using: .utf8)
        return req
    }
}

// Decoded token response from Google.
struct OAuthTokens: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}
