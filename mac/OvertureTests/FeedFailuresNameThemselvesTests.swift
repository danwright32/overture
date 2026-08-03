import Testing
import Foundation

// #1555: a feed adapter reported a malformed address or an error status as "Couldn't reach that page."
//
// #1543 split a broken TLS handshake out of `unreachable` on the main fetch path, because that sentence is
// wrong about a site that is up. The adapters had the same defect in eight places and were not touched.
// Reading them showed the issue's own guess about what they were was wrong, which is worth recording:
//
//   - FOUR were non-2xx STATUS checks (OvationTix, VenueTix, OperaAmerica, Squarespace). The server
//     answered, with a 404 or a 503. `SourceFetchError.http(Int)` has existed for exactly that since the
//     beginning and already says "The page answered with HTTP 503.", so this needs no new vocabulary at
//     all, just the existing word.
//   - TWO were "the response was not an HTTP response", which is genuinely odd and for which `unreachable`
//     is honest. Left alone.
//   - TWO were OvationTix finding no client id in the stored address. That is a WRONG ADDRESS, the one
//     case where the "Fix the address" button already on the row is exactly the right next step, and the
//     only one that earns a new name.
//
// All four status guards were separate copies of one rule, so they are now one shared check rather than
// four that can drift on what counts as an error.
@Suite("A feed's failure says what it actually was (#1555)")
struct FeedFailuresNameThemselvesTests {

    private let url = URL(string: "https://feed.example/events")!

    private func response(_ status: Int) -> URLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    private func caught(_ body: () throws -> Void) -> SourceFetchError? {
        do { try body(); return nil } catch let e as SourceFetchError { return e } catch { return nil }
    }

    // The server answered and said what was wrong. Reporting that as a connectivity problem sends Dan to
    // check whether a site is down when it is up and telling him its calendar is gone.
    @Test func anErrorStatusIsReportedAsThatStatus() {
        #expect(caught { try FeedResponse.check(response(404)) } == .http(404))
        #expect(caught { try FeedResponse.check(response(503)) } == .http(503))
        #expect(caught { try FeedResponse.check(response(429)) } == .http(429))
    }

    // And the message carries the number, so the row says which one rather than a generic failure.
    @Test func theRowNamesTheStatusItGotBack() {
        #expect(SourceFailure.fetch(.http(503)).message.contains("503"))
        #expect(SourceFailure.fetch(.http(503)).message != SourceFailure.fetch(.unreachable).message)
    }

    @Test func aSuccessfulStatusThrowsNothing() {
        #expect(caught { try FeedResponse.check(response(200)) } == nil)
        #expect(caught { try FeedResponse.check(response(204)) } == nil)
    }

    // A response that is not an HTTP response at all has no status to report and nothing better to say,
    // so it stays `unreachable`. Deliberately unchanged: widening the honest cases must not mean inventing
    // a confident answer where there is no evidence.
    @Test func aNonHTTPResponseStaysUnreachable() {
        let odd = URLResponse(url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)

        #expect(caught { try FeedResponse.check(odd) } == .unreachable)
    }

    // MARK: - The wrong address

    // OvationTix reads a venue's calendar by the client id embedded in its address. With no id there,
    // nothing can be fetched, and it is not a network problem: the stored link is wrong or points at the
    // wrong kind of OvationTix page. "Fix the address" is the honest next step and is already on the row.
    @Test func anAddressWithNoClientIdSaysSoRatherThanClaimingItIsUnreachable() {
        let failure = SourceFailure.fetch(.addressUnusable)

        #expect(failure != .fetch(.unreachable))
        #expect(failure.message != SourceFailure.fetch(.unreachable).message)
        #expect(failure.message.lowercased().contains("address"))
    }

    // Fix is the whole point of naming it. Confirm is not: nothing was read, so there is no empty page to
    // confirm as right.
    @Test func aWrongAddressOffersFixAndNothingToConfirm() {
        #expect(SourceFailure.fetch(.addressUnusable).offersFix)
        #expect(SourceFailure.fetch(.addressUnusable).offersConfirm == false)
    }

    // It has to survive a relaunch like every other failure, or the row forgets why it is flagged.
    @Test func itRoundTripsThroughItsStoredString() {
        let failure = SourceFailure.fetch(.addressUnusable)

        #expect(SourceFailure(raw: failure.raw) == failure)
    }

    // MARK: - Wiring (#887)

    // Every adapter must go through the ONE check. Four separate copies of "is this 2xx" is how they drift
    // on what counts as an error, and it is why this issue could exist in four places at once.
    @Test func everyFeedAdapterUsesTheOneSharedCheck() {
        for file in ["Overture/Integration/OvationTixCalendar.swift",
                     "Overture/Integration/VenueTixCalendar.swift",
                     "Overture/Integration/OperaAmericaCalendar.swift",
                     "Overture/Integration/SquarespaceCalendar.swift"] {
            let source = SourceGuardHelper.source(file)
            #expect(source.contains("FeedResponse.check"), "\(file) should use the shared response check")
            #expect(source.contains("(200..<300).contains") == false,
                    "\(file) should not carry its own copy of the status rule")
        }
    }
}
