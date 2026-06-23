import Testing
import Foundation
@testable import Overture

// #50: a refresh response must be read three ways so a dead login is handled, not
// mistaken for a blip. invalid_grant / 401 => the refresh token is revoked or expired
// and Dan must reconnect; 5xx / 429 / unparseable => transient, keep the saved login
// and let the caller retry; 200 with tokens => success.
@Suite("Refresh response interpretation")
struct RefreshResponseTests {
    private func data(_ s: String) -> Data { Data(s.utf8) }

    @Test func successReturnsTheNewAccessToken() {
        let body = #"{"access_token":"fresh-123","expires_in":3600}"#
        switch GoogleOAuth.interpretRefreshResponse(status: 200, data: data(body)) {
        case .success(let tokens): #expect(tokens.accessToken == "fresh-123")
        case .failure: Issue.record("expected success")
        }
    }

    @Test func invalidGrantMeansReconnect() {
        let body = #"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#
        #expect(GoogleOAuth.interpretRefreshResponse(status: 400, data: data(body)) == .failure(.authExpired))
    }

    @Test func unauthorizedMeansReconnect() {
        #expect(GoogleOAuth.interpretRefreshResponse(status: 401, data: data("{}")) == .failure(.authExpired))
    }

    @Test func serverErrorsAndRateLimitsAreTransient() {
        #expect(GoogleOAuth.interpretRefreshResponse(status: 500, data: data("oops")) == .failure(.transient))
        #expect(GoogleOAuth.interpretRefreshResponse(status: 503, data: data("")) == .failure(.transient))
        #expect(GoogleOAuth.interpretRefreshResponse(status: 429, data: data("slow down")) == .failure(.transient))
    }

    @Test func a200WithAnUnreadableBodyIsTransientNotAuthLoss() {
        // A garbled 200 must not throw away a still-valid saved login.
        #expect(GoogleOAuth.interpretRefreshResponse(status: 200, data: data("<html>nope</html>")) == .failure(.transient))
    }
}
