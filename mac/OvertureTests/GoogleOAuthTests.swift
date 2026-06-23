import Testing
import Foundation
import CryptoKit
@testable import Overture

@Suite("Google OAuth requests")
struct GoogleOAuthTests {
    private let config = OAuthConfig(
        clientId: "cid.apps.googleusercontent.com",
        clientSecret: "secret",
        redirectURI: "http://127.0.0.1:7711",
        scopes: OAuthConfig.gmailScopes)

    @Test func pkceChallengeIsSha256OfVerifierBase64url() {
        let bytes = Data((0..<32).map { UInt8($0) })
        let pkce = GoogleOAuth.makePKCE(verifierBytes: bytes)
        // Recompute the expected challenge independently.
        let expected = GoogleOAuth.base64url(Data(SHA256.hash(data: Data(pkce.verifier.utf8))))
        #expect(pkce.challenge == expected)
        #expect(!pkce.verifier.contains("="))
        #expect(!pkce.challenge.contains("+"))
    }

    @Test func authorizationURLHasPkceAndOfflineAccess() {
        let pkce = PKCE(verifier: "v", challenge: "chal")
        let url = GoogleOAuth.authorizationURL(config: config, pkce: pkce, state: "xyz")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        func val(_ n: String) -> String? { items.first { $0.name == n }?.value }
        #expect(url.absoluteString.hasPrefix("https://accounts.google.com/o/oauth2/v2/auth"))
        #expect(val("code_challenge") == "chal")
        #expect(val("code_challenge_method") == "S256")
        #expect(val("access_type") == "offline")
        #expect(val("prompt") == "consent")
        #expect(val("scope") == OAuthConfig.gmailScopes.joined(separator: " "))
        #expect(val("redirect_uri") == "http://127.0.0.1:7711")
    }

    @Test func tokenExchangeIncludesCodeAndVerifier() {
        let req = GoogleOAuth.tokenExchangeRequest(config: config, code: "authcode", pkce: PKCE(verifier: "ver", challenge: "c"))
        #expect(req.httpMethod == "POST")
        #expect(req.url?.absoluteString == GoogleOAuth.tokenEndpoint)
        let body = String(data: req.httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("grant_type=authorization_code"))
        #expect(body.contains("code=authcode"))
        #expect(body.contains("code_verifier=ver"))
    }

    @Test func refreshRequestUsesRefreshGrant() {
        let req = GoogleOAuth.refreshRequest(config: config, refreshToken: "r-token")
        let body = String(data: req.httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("grant_type=refresh_token"))
        #expect(body.contains("refresh_token=r-token"))
    }

    @Test func decodesGoogleTokenResponse() throws {
        let json = #"{"access_token":"at","refresh_token":"rt","expires_in":3599}"#
        let tokens = try JSONDecoder().decode(OAuthTokens.self, from: Data(json.utf8))
        #expect(tokens.accessToken == "at")
        #expect(tokens.refreshToken == "rt")
        #expect(tokens.expiresIn == 3599)
    }
}
