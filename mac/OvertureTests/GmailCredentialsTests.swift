import Testing
import Foundation

@Suite("Gmail credentials store")
struct GmailCredentialsTests {
    @Test func tokensRoundTripThroughTheFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tok-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let tokens = StoredTokens(refreshToken: "r-1", accessToken: "a-1",
                                  accessTokenExpiry: Date(timeIntervalSince1970: 5_000_000))
        #expect(GmailCredentials.saveTokens(tokens, to: url) == true)
        #expect(GmailCredentials.loadTokens(from: url) == tokens)
    }

    @Test func freshnessAccountsForExpiryAndSkew() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let valid = StoredTokens(refreshToken: "r", accessToken: "a", accessTokenExpiry: now.addingTimeInterval(600))
        #expect(valid.isFresh(now: now) == true)

        let aboutToExpire = StoredTokens(refreshToken: "r", accessToken: "a", accessTokenExpiry: now.addingTimeInterval(60))
        #expect(aboutToExpire.isFresh(now: now) == false) // within the 120s skew

        let noAccess = StoredTokens(refreshToken: "r", accessToken: nil, accessTokenExpiry: now.addingTimeInterval(600))
        #expect(noAccess.isFresh(now: now) == false)
    }

    @Test func loadClientDecodesConfig() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cfg-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"clientId":"cid","clientSecret":"sec"}"#.utf8).write(to: url)
        let client = GmailCredentials.loadClient(from: url)
        #expect(client?.clientId == "cid")
        #expect(client?.clientSecret == "sec")
    }

    // #486: the file must never be observable wider than 0600, not briefly wide-open before a
    // separate narrowing step catches up.
    @Test func saveTokensCreatesTheFileAtOwnerOnlyPermissions() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tok-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let tokens = StoredTokens(refreshToken: "r-1", accessToken: "a-1",
                                  accessTokenExpiry: Date(timeIntervalSince1970: 5_000_000))
        #expect(GmailCredentials.saveTokens(tokens, to: url) == true)

        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }

    // #484: a genuine write failure must be reported, not swallowed, so a caller that checks
    // the return value can surface it instead of assuming success.
    @Test func saveTokensReturnsFalseWhenTheDestinationDirectoryIsNotWritable() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        let url = dir.appendingPathComponent("gmail-tokens.json")

        let tokens = StoredTokens(refreshToken: "r-1", accessToken: "a-1", accessTokenExpiry: nil)
        #expect(GmailCredentials.saveTokens(tokens, to: url) == false)
    }
}
