import Foundation

// Loads the OAuth client config (gmail-oauth.json, written outside git) and persists
// the tokens. Tokens live in a 0600 file in Application Support rather than the
// Keychain because the app is ad-hoc signed during development (its code signature
// changes every build, which makes Keychain item ACLs churn and prompt). On a
// single-user Mac a 0600 file is read-only to Dan's account; hardening to the
// Keychain for a stably-signed build is a tracked follow-up.

struct GmailClient: Codable, Equatable, Sendable {
    var clientId: String
    var clientSecret: String
}

struct StoredTokens: Codable, Equatable, Sendable {
    var refreshToken: String
    var accessToken: String?
    var accessTokenExpiry: Date?

    func isFresh(now: Date, skew: TimeInterval = 120) -> Bool {
        guard let accessToken, !accessToken.isEmpty, let exp = accessTokenExpiry else { return false }
        return now.addingTimeInterval(skew) < exp
    }
}

enum GmailCredentials {
    static var supportDir: URL {
        StoreLocation.handoffDirectory
    }
    static var clientConfigURL: URL { supportDir.appendingPathComponent("gmail-oauth.json") }
    static var tokenURL: URL { supportDir.appendingPathComponent("gmail-tokens.json") }

    static func loadClient(from url: URL = clientConfigURL) -> GmailClient? {
        // #2879: an unreadable credentials file is not an absent one. Read as absent it says Gmail was
        // never connected, which is a state Dan can act on; what it really means is that the connection
        // he made is unusable, and nothing said so.
        return HandoffFile.read(at: url) { try JSONDecoder().decode(GmailClient.self, from: $0) }.value
    }

    static func loadTokens(from url: URL = tokenURL) -> StoredTokens? {
        return HandoffFile.read(at: url) { try JSONDecoder().decode(StoredTokens.self, from: $0) }.value
    }

    // Goes through SecureFileWrite (#524) so the file is never briefly world-default-readable the
    // way a plain atomic write followed by a separate best-effort chmod would leave it (#486).
    @discardableResult
    static func saveTokens(_ tokens: StoredTokens, to url: URL = tokenURL) -> Bool {
        guard let data = try? JSONEncoder().encode(tokens) else { return false }
        return SecureFileWrite.writeOwnerOnly(data, to: url)
    }

    static func clearTokens(at url: URL = tokenURL) {
        try? FileManager.default.removeItem(at: url)
    }

    static var isConnected: Bool { loadTokens()?.refreshToken.isEmpty == false }
}
