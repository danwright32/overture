import Foundation
import Testing
@testable import Overture

// #858. A venue's calendar shows you the month you landed on and nothing else. Kaufman's landing page
// carries July's 6 shows; August (2), September (8) and October (14) are on their own pages and were
// silently never read. October is the richest month on their calendar, and it is exactly the kind of
// show Dan can still pitch, because pitching a performance needs lead time. The shows being dropped
// were the valuable ones.
//
// The way to the other months is the site's OWN month index: a <select> whose options carry the URLs
// (#892 is what stopped us deleting them). This type reads that index and says which months to fetch.
// It never invents a URL, and it never follows anything the page did not offer.
@Suite("The month index a calendar publishes about itself (#858)")
struct CalendarMonthIndexTests {

    // Verbatim from the live Kaufman Music Center calendar (2026-07-13), indentation, bare `selected`
    // and line breaks included. A tidied fixture is how the last normalizer bug stayed green.
    private let kaufman = """
    <select>
        <option value="https://www.kaufmanmusiccenter.org/mch/calendar/2026/05/">
        May 2026
    </option>
        <option value="https://www.kaufmanmusiccenter.org/mch/calendar/2026/06/">
        June 2026
    </option>
        <option value="https://www.kaufmanmusiccenter.org/mch/calendar/2026/07/" selected>
        July 2026
    </option>
        <option value="https://www.kaufmanmusiccenter.org/mch/calendar/2026/08/">
        August 2026
    </option>
        <option value="https://www.kaufmanmusiccenter.org/mch/calendar/2026/09/">
        September 2026
    </option>
        <option value="https://www.kaufmanmusiccenter.org/mch/calendar/2026/10/">
        October 2026
    </option>
        <option value="https://www.kaufmanmusiccenter.org/mch/calendar/2026/11/">
        November 2026
    </option>
    </select>
    """

    private func url(_ s: String) -> URL { URL(string: s)! }

    private func july2026() -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 7; c.day = 13
        c.timeZone = TimeZone(identifier: "America/New_York")
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    // The whole point: four months forward, starting from the month we are in. Dan's call.
    @Test func readsTheMonthWeAreInAndTheThreeAfterIt() {
        let months = CalendarMonthIndex.monthPages(
            in: kaufman,
            at: url("https://www.kaufmanmusiccenter.org/mch/calendar/"),
            now: july2026(), horizon: 4)

        #expect(months.map(\.absoluteString) == [
            "https://www.kaufmanmusiccenter.org/mch/calendar/2026/07/",
            "https://www.kaufmanmusiccenter.org/mch/calendar/2026/08/",
            "https://www.kaufmanmusiccenter.org/mch/calendar/2026/09/",
            "https://www.kaufmanmusiccenter.org/mch/calendar/2026/10/",
        ])
    }

    // A month that has already been and gone is not worth a fetch: nothing in it can be pitched. May and
    // June are in Kaufman's index and must not be read.
    @Test func aMonthThatHasAlreadyGoneByIsNeverFetched() {
        let months = CalendarMonthIndex.monthPages(
            in: kaufman, at: url("https://www.kaufmanmusiccenter.org/mch/calendar/"),
            now: july2026(), horizon: 4)

        #expect(!months.map(\.absoluteString).contains { $0.hasSuffix("/2026/05/") })
        #expect(!months.map(\.absoluteString).contains { $0.hasSuffix("/2026/06/") })
    }

    // The horizon is a HARD cap, not a suggestion. Kaufman lists 21 months out to January 2028; reading
    // all of them would cost a multiple of every scout forever, for shows too far out to pitch.
    @Test func theHorizonIsAHardCap() {
        let months = CalendarMonthIndex.monthPages(
            in: kaufman, at: url("https://www.kaufmanmusiccenter.org/mch/calendar/"),
            now: july2026(), horizon: 4)
        #expect(months.count == 4)
    }

    // A page that is not a month calendar must be left completely alone. Dan pastes single show pages,
    // org homepages and Substack posts, and none of them should suddenly start fetching three extra
    // pages. Nothing here is worth guessing about: no month index, no pagination.
    @Test func aPageWithNoMonthIndexIsNotPaginatedAtAll() {
        let showPage = """
        <html><body>
        <h1>Immortal Gifts</h1>
        <a href="/tickets">Buy tickets</a>
        <a href="/about">About us</a>
        </body></html>
        """
        let months = CalendarMonthIndex.monthPages(
            in: showPage, at: url("https://example.org/show/immortal-gifts"),
            now: july2026(), horizon: 4)
        #expect(months.isEmpty)
    }

    // The obvious false positive, and the one that would quietly cost the most: a blog archive links to
    // /2024/03/, /2024/04/ ... by the dozen. They are all in the PAST, so the "not yet gone by" rule
    // already refuses them, and a blog never turns into three extra fetches.
    @Test func aBlogArchiveOfPastMonthsIsNotMistakenForACalendar() {
        let archive = """
        <html><body><ul>
        <li><a href="/2024/03/">March 2024</a></li>
        <li><a href="/2024/04/">April 2024</a></li>
        <li><a href="/2025/01/">January 2025</a></li>
        </ul></body></html>
        """
        let months = CalendarMonthIndex.monthPages(
            in: archive, at: url("https://someblog.com/archive"),
            now: july2026(), horizon: 4)
        #expect(months.isEmpty)
    }

    // Never leave the site. A month link that points somewhere else is not this venue's calendar, and
    // following it would read another organization's shows and file them under this lead.
    @Test func aMonthLinkOnAnotherSiteIsNeverFollowed() {
        let page = """
        <select>
        <option value="https://www.kaufmanmusiccenter.org/mch/calendar/2026/08/">August 2026</option>
        <option value="https://someoneelse.org/calendar/2026/09/">September 2026</option>
        </select>
        """
        let months = CalendarMonthIndex.monthPages(
            in: page, at: url("https://www.kaufmanmusiccenter.org/mch/calendar/"),
            now: july2026(), horizon: 4)

        #expect(months.allSatisfy { $0.host?.contains("kaufmanmusiccenter.org") == true })
        #expect(!months.contains { $0.absoluteString.contains("someoneelse.org") })
    }
}
