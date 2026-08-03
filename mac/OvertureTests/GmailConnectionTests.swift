import Testing
import Foundation

// #1770: "is Gmail connected?" used to be answered by opening and JSON-decoding the token file, and
// every queue card asked it while it was being built, on the main thread, inside a SwiftUI view body.
// Scrolling re-renders the list, so the answer was re-read from disk for every visible card on every
// scroll frame, which is a large part of the stutter Dan reported on 2026-07-29.
//
// GmailConnection is the one cached answer. These pin the two halves that matter: reading it costs
// nothing after the first load, and the cache can still be brought back to the truth, because a
// credential that has been revoked or deleted must not read as connected forever.
@Suite("The Gmail connected flag is answered from a cache, not from disk (#1770)")
@MainActor
struct GmailConnectionTests {
    // A reference-type counter so the injected loader can record its own calls without capturing a
    // mutable local across an escaping closure boundary.
    private final class LoadCount {
        var value = 0
    }

    // The defect, stated as a test: N reads must cost ONE load. Against the pre-cache shape (a computed
    // property forwarding straight to the loader) this fails at 50.
    @Test func readingTheFlagManyTimesLoadsItOnce() {
        let loads = LoadCount()
        let connection = GmailConnection(load: { loads.value += 1; return true })

        for _ in 0..<50 { _ = connection.isConnected }

        #expect(connection.isConnected == true)
        #expect(loads.value == 1)
    }

    // The cache is only safe if something can put it back in touch with reality, so refresh has to
    // actually go back to the source rather than return the value it already holds.
    @Test func refreshGoesBackToTheSource() {
        let loads = LoadCount()
        let connection = GmailConnection(load: { loads.value += 1; return true })
        _ = connection.isConnected

        connection.refresh()
        connection.refresh()

        #expect(loads.value == 3)
    }

    // The failure path, and the reason this cache needed a test at all: a token file that is revoked or
    // deleted while Overture is open must not leave the app believing it can still send. Driven through
    // the REAL credential reader against a real file on disk, not a stubbed boolean, so this cannot pass
    // against a loader that never touches the thing it claims to read.
    @Test func aDeletedTokenFileIsNoticedOnTheNextRefresh() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gmail-tokens-\(UUID().uuidString).json")
        #expect(GmailCredentials.saveTokens(StoredTokens(refreshToken: "live-refresh-token"), to: url))
        defer { GmailCredentials.clearTokens(at: url) }

        let connection = GmailConnection(load: {
            GmailCredentials.loadTokens(from: url)?.refreshToken.isEmpty == false
        })
        #expect(connection.isConnected == true)

        GmailCredentials.clearTokens(at: url)

        // Still cached: the app has not been told anything changed, and that is the honest state.
        #expect(connection.isConnected == true)
        // ...but the moment it asks again, it gets the truth rather than its own stale optimism.
        connection.refresh()
        #expect(connection.isConnected == false)
    }

    // An unreadable file is not a connection. A corrupt or truncated token file must land on the
    // not-connected side rather than inheriting whatever the cache last held (L50: a failed parse
    // must never quietly keep the permissive answer).
    @Test func anUnreadableTokenFileRefreshesToNotConnected() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gmail-tokens-\(UUID().uuidString).json")
        #expect(GmailCredentials.saveTokens(StoredTokens(refreshToken: "live-refresh-token"), to: url))
        defer { GmailCredentials.clearTokens(at: url) }

        let connection = GmailConnection(load: {
            GmailCredentials.loadTokens(from: url)?.refreshToken.isEmpty == false
        })
        #expect(connection.isConnected == true)

        try Data("{ this is not json".utf8).write(to: url)
        connection.refresh()

        #expect(connection.isConnected == false)
    }
}
