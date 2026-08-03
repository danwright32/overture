import Testing
import Foundation

// #468 (SUP-004): every Gmail network call used to default to URLSession.shared, whose resource
// timeout is 7 days, so a stalled call could hang almost indefinitely with no recovery short of
// an app restart. This is the one shared, bounded session every default fetch closure should
// route through instead.
@Suite("Gmail networking")
struct GmailNetworkingTests {
    @Test func sharedSessionHasABoundedRequestAndResourceTimeout() {
        let config = GmailNetworking.session.configuration
        #expect(config.timeoutIntervalForRequest == 30)
        #expect(config.timeoutIntervalForResource == 30)
    }
}
