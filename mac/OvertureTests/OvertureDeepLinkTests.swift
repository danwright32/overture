import Testing
import Foundation
@testable import Overture

// #236: the OmniFocus follow-up tasks embed an `overture://lead?key=<naturalKey>` link. This parses
// that URL back into the natural key so the app can jump to the lead. Must be the exact inverse of
// OmniFocusSync.deepLink(for:), including percent-encoded keys (group|date|venue with spaces/pipes).
@Suite("Overture deep link (#236)")
struct OvertureDeepLinkTests {
    @Test func parsesTheKeyRoundTrippedFromTheBuilder() throws {
        let key = "aurora strings|2026-03-10|carnegie hall"
        let url = try #require(URL(string: OmniFocusSync.deepLink(for: key)))
        #expect(OvertureDeepLink.leadKey(from: url) == key)
    }

    @Test func rejectsOtherSchemesHostsAndMissingKeys() throws {
        #expect(OvertureDeepLink.leadKey(from: try #require(URL(string: "https://example.com/lead?key=x"))) == nil)
        #expect(OvertureDeepLink.leadKey(from: try #require(URL(string: "overture://other?key=x"))) == nil)
        #expect(OvertureDeepLink.leadKey(from: try #require(URL(string: "overture://lead?notkey=x"))) == nil)
        #expect(OvertureDeepLink.leadKey(from: try #require(URL(string: "overture://lead?key="))) == nil)
    }
}
