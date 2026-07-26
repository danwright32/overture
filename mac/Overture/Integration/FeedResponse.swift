import Foundation

// #1555: the ONE rule for what a feed's HTTP response means, shared by every native adapter.
//
// It used to be four separate copies of `guard let http = ..., (200..<300).contains(http.statusCode)`, one
// per adapter, each throwing `unreachable`. Two things wrong with that. The copies could drift on what
// counts as an error, and the sentence was false: a server that answers 404 or 503 is up and telling
// Overture its calendar is gone, which is not "Couldn't reach that page." and does not call for the same
// response from Dan. `SourceFetchError.http(Int)` has existed for exactly this since the beginning.
//
// A response that is not an HTTP response at all has no status to report and nothing better to say, so it
// stays `unreachable`. Naming the honest cases must not mean inventing a confident answer where there is
// no evidence (#1543's rule, same reasoning).
enum FeedResponse {
    static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw SourceFetchError.unreachable }
        guard (200..<300).contains(http.statusCode) else { throw SourceFetchError.http(http.statusCode) }
    }
}
