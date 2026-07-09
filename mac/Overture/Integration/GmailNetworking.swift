import Foundation

// #468 (SUP-004): a single, bounded URLSession every Gmail call routes through by default. The
// plain URLSession.shared this replaced has a 7-day resource timeout, so a stalled call (token
// refresh, send, reply check) could hang for days with no recovery short of an app restart. Every
// call site here still injects its own fetch closure for tests, so this only changes what a real
// production call actually waits on.
enum GmailNetworking {
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()
}
