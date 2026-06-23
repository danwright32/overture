import Testing
import Foundation
@testable import Overture

// #55: the behavior that makes a dead Gmail login recoverable — clear the stored token and
// surface authExpired on a revoked/expired refresh — is now testable via injected file
// locations and a fake HTTP fetch.
@MainActor
@Suite("Gmail auth expiry handling")
struct GmailAuthExpiryTests {
    private func tmp() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
    }

    private func writeClient(_ url: URL) throws {
        try Data(#"{"clientId":"cid","clientSecret":"sec"}"#.utf8).write(to: url)
    }

    private func fetch(_ status: Int, _ body: String) -> (URLRequest) async throws -> (Data, URLResponse) {
        { _ in
            (Data(body.utf8),
             HTTPURLResponse(url: URL(string: "https://oauth2.googleapis.com/token")!,
                             statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    @Test func invalidGrantClearsTheTokenAndThrowsAuthExpired() async throws {
        let clientURL = tmp(), tokenURL = tmp()
        defer { try? FileManager.default.removeItem(at: clientURL); try? FileManager.default.removeItem(at: tokenURL) }
        try writeClient(clientURL)
        let now = Date(timeIntervalSince1970: 1_000_000)
        // A stale access token forces a refresh attempt.
        GmailCredentials.saveTokens(StoredTokens(refreshToken: "r", accessToken: "old",
                                                 accessTokenExpiry: now.addingTimeInterval(-60)), to: tokenURL)

        await #expect(throws: GmailAuthManager.AuthError.self) {
            _ = try await GmailAuthManager.shared.validAccessToken(
                now: now, clientURL: clientURL, tokenURL: tokenURL,
                fetch: self.fetch(400, #"{"error":"invalid_grant"}"#))
        }
        #expect(GmailCredentials.loadTokens(from: tokenURL) == nil)   // dead token cleared
    }

    @Test func aSuccessfulRefreshKeepsTheConnectionAndStoresTheNewToken() async throws {
        let clientURL = tmp(), tokenURL = tmp()
        defer { try? FileManager.default.removeItem(at: clientURL); try? FileManager.default.removeItem(at: tokenURL) }
        try writeClient(clientURL)
        let now = Date(timeIntervalSince1970: 1_000_000)
        GmailCredentials.saveTokens(StoredTokens(refreshToken: "r", accessToken: "old",
                                                 accessTokenExpiry: now.addingTimeInterval(-60)), to: tokenURL)

        let token = try await GmailAuthManager.shared.validAccessToken(
            now: now, clientURL: clientURL, tokenURL: tokenURL,
            fetch: fetch(200, #"{"access_token":"fresh","expires_in":3600}"#))
        #expect(token == "fresh")
        #expect(GmailCredentials.loadTokens(from: tokenURL)?.accessToken == "fresh")
    }

    @Test func aTransientServerErrorKeepsTheStoredTokenForRetry() async throws {
        let clientURL = tmp(), tokenURL = tmp()
        defer { try? FileManager.default.removeItem(at: clientURL); try? FileManager.default.removeItem(at: tokenURL) }
        try writeClient(clientURL)
        let now = Date(timeIntervalSince1970: 1_000_000)
        GmailCredentials.saveTokens(StoredTokens(refreshToken: "r", accessToken: "old",
                                                 accessTokenExpiry: now.addingTimeInterval(-60)), to: tokenURL)

        await #expect(throws: GmailAuthManager.AuthError.self) {
            _ = try await GmailAuthManager.shared.validAccessToken(
                now: now, clientURL: clientURL, tokenURL: tokenURL, fetch: self.fetch(503, "upstream down"))
        }
        #expect(GmailCredentials.loadTokens(from: tokenURL) != nil)   // kept for retry, not cleared
    }
}
