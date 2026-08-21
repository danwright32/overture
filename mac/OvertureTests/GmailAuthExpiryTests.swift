import Testing
import Foundation

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

    // #2947: the fake ANSWERS THE REQUEST rather than the same blob whatever it was handed.
    //
    // There is no field selection to narrow here, so what there is to honour is that the refresh really
    // is a refresh: the right endpoint, a POST, and a `grant_type=refresh_token` body. A fake that answers
    // any request identically cannot tell a correct refresh from a call aimed somewhere else, and every
    // test below would go on passing (L52, L143).
    private func fetch(_ status: Int, _ body: String) -> (URLRequest) async throws -> (Data, URLResponse) {
        { req in
            #expect(req.url?.absoluteString == GoogleOAuth.tokenEndpoint,
                    "the refresh has to go to Google's token endpoint")
            #expect(req.httpMethod == "POST")
            let sent = String(data: req.httpBody ?? Data(), encoding: .utf8) ?? ""
            // copy-inventory:ignore-start  the OAuth form field Google reads, not a sentence (#915)
            #expect(sent.contains("grant_type=refresh_token"),
                    "a refresh that is not a refresh would be answered here regardless")
            // copy-inventory:ignore-end
            return (Data(body.utf8),
                    HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
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

    // #484: a refresh that succeeds over the network but then fails to persist must not be
    // reported as a success, or the app looks connected while running on a token it never saved.
    @Test func aSuccessfulRefreshThatCannotBeSavedThrowsInsteadOfSilentlySucceeding() async throws {
        let clientURL = tmp()
        defer { try? FileManager.default.removeItem(at: clientURL) }
        try writeClient(clientURL)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let tokenURL = dir.appendingPathComponent("gmail-tokens.json")
        let now = Date(timeIntervalSince1970: 1_000_000)
        GmailCredentials.saveTokens(StoredTokens(refreshToken: "r", accessToken: "old",
                                                 accessTokenExpiry: now.addingTimeInterval(-60)), to: tokenURL)
        // Remove write access on the directory only after seeding it, so the refresh can still
        // load the stale token but the write-back of the refreshed one cannot land.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)

        await #expect(throws: GmailAuthManager.AuthError.self) {
            _ = try await GmailAuthManager.shared.validAccessToken(
                now: now, clientURL: clientURL, tokenURL: tokenURL,
                fetch: self.fetch(200, #"{"access_token":"fresh","expires_in":3600}"#))
        }
    }

    // #484: the same save-failure handling applies to the fresh-consent path in connect(), split
    // into persistExchangedTokens so it is testable without a live browser/network round trip.
    @Test func persistExchangedTokensThrowsWhenTheSaveFails() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        let tokenURL = dir.appendingPathComponent("gmail-tokens.json")

        let tokens = OAuthTokens(accessToken: "a", refreshToken: "r", expiresIn: 3600)
        #expect(throws: GmailAuthManager.AuthError.self) {
            try GmailAuthManager.shared.persistExchangedTokens(tokens, to: tokenURL)
        }
    }
}
