import Testing
import Foundation
@testable import Overture

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
}
