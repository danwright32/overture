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
        StoreLocation.dataDirectory
            .appendingPathComponent("Overture", isDirectory: true)
    }
    static var clientConfigURL: URL { supportDir.appendingPathComponent("gmail-oauth.json") }
    static var tokenURL: URL { supportDir.appendingPathComponent("gmail-tokens.json") }

    static func loadClient(from url: URL = clientConfigURL) -> GmailClient? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(GmailClient.self, from: data)
    }

    static func loadTokens(from url: URL = tokenURL) -> StoredTokens? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(StoredTokens.self, from: data)
    }

    @discardableResult
    static func saveTokens(_ tokens: StoredTokens, to url: URL = tokenURL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(tokens)
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }

    static func clearTokens(at url: URL = tokenURL) {
        try? FileManager.default.removeItem(at: url)
    }

    static var isConnected: Bool { loadTokens()?.refreshToken.isEmpty == false }
}
