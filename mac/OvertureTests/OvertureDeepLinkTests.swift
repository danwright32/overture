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

    // #301: a tapped notification routes to the lead via leadURL(forKey:), the inverse of
    // leadKey(from:). Round-trips a key with the spaces/pipes a naturalKey carries.
    @Test func buildsALeadURLThatRoundTripsBackToTheKey() throws {
        let key = "aurora strings|2026-03-10|carnegie hall"
        let url = try #require(OvertureDeepLink.leadURL(forKey: key))
        #expect(url.scheme == OvertureDeepLink.scheme)
        #expect(url.host == OvertureDeepLink.leadHost)
        #expect(OvertureDeepLink.leadKey(from: url) == key)
    }

    @Test func leadURLIsNilForAnEmptyKey() {
        #expect(OvertureDeepLink.leadURL(forKey: "") == nil)
    }

    @Test func rejectsOtherSchemesHostsAndMissingKeys() throws {
        #expect(OvertureDeepLink.leadKey(from: try #require(URL(string: "https://example.com/lead?key=x"))) == nil)
        #expect(OvertureDeepLink.leadKey(from: try #require(URL(string: "overture://other?key=x"))) == nil)
        #expect(OvertureDeepLink.leadKey(from: try #require(URL(string: "overture://lead?notkey=x"))) == nil)
        #expect(OvertureDeepLink.leadKey(from: try #require(URL(string: "overture://lead?key="))) == nil)
    }

    // #308: a coalesced multi-lead away alert routes to overture://leads?key=k1&key=k2…, carrying the
    // whole set so the tap can filter the queue to exactly those leads. Round-trips keys with the
    // spaces/pipes a naturalKey carries, and stays distinct from the singular `lead` host (#236).
    @Test func buildsALeadsURLThatRoundTripsBackToTheKeys() throws {
        let keys = ["aurora strings|2026-03-10|carnegie hall", "joyce|2026-03-14|theater"]
        let url = try #require(OvertureDeepLink.leadsURL(forKeys: keys))
        #expect(url.scheme == OvertureDeepLink.scheme)
        #expect(url.host == OvertureDeepLink.leadsHost)
        #expect(OvertureDeepLink.leadKeys(from: url) == keys)
    }

    @Test func leadsURLDropsEmptyKeysAndIsNilWhenNoneRemain() throws {
        let url = try #require(OvertureDeepLink.leadsURL(forKeys: ["", "k1", ""]))
        #expect(OvertureDeepLink.leadKeys(from: url) == ["k1"])
        #expect(OvertureDeepLink.leadsURL(forKeys: ["", ""]) == nil)
        #expect(OvertureDeepLink.leadsURL(forKeys: []) == nil)
    }

    @Test func leadKeysRejectsOtherSchemesAndHosts() throws {
        #expect(OvertureDeepLink.leadKeys(from: try #require(URL(string: "https://example.com/leads?key=x"))) == nil)
        #expect(OvertureDeepLink.leadKeys(from: try #require(URL(string: "overture://lead?key=x"))) == nil)
        #expect(OvertureDeepLink.leadKeys(from: try #require(URL(string: "overture://leads?notkey=x"))) == nil)
    }

    // #282: `overture://show` surfaces the resident copy's window. The build script opens this URL
    // instead of re-launching the bundle, which routes to the already-running instance rather than
    // spawning a second copy that the store lock then refuses.
    @Test func recognizesTheShowWindowCommand() throws {
        #expect(OvertureDeepLink.isShowCommand(try #require(URL(string: "overture://show"))))
        #expect(!OvertureDeepLink.isShowCommand(try #require(URL(string: "overture://lead?key=x"))))
        #expect(!OvertureDeepLink.isShowCommand(try #require(URL(string: "https://example.com/show"))))
    }
}
