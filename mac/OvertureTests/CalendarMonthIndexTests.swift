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
        let months = CalendarMonthIndex.index(
            in: kaufman,
            at: url("https://www.kaufmanmusiccenter.org/mch/calendar/"),
            now: july2026(), horizon: 4).pages

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
        let months = CalendarMonthIndex.index(
            in: kaufman, at: url("https://www.kaufmanmusiccenter.org/mch/calendar/"),
            now: july2026(), horizon: 4).pages

        #expect(!months.map(\.absoluteString).contains { $0.hasSuffix("/2026/05/") })
        #expect(!months.map(\.absoluteString).contains { $0.hasSuffix("/2026/06/") })
    }

    // The horizon is a HARD cap, not a suggestion. Kaufman lists 21 months out to January 2028; reading
    // all of them would cost a multiple of every scout forever, for shows too far out to pitch.
    @Test func theHorizonIsAHardCap() {
        let months = CalendarMonthIndex.index(
            in: kaufman, at: url("https://www.kaufmanmusiccenter.org/mch/calendar/"),
            now: july2026(), horizon: 4).pages
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
        let months = CalendarMonthIndex.index(
            in: showPage, at: url("https://example.org/show/immortal-gifts"),
            now: july2026(), horizon: 4).pages
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
        let months = CalendarMonthIndex.index(
            in: archive, at: url("https://someblog.com/archive"),
            now: july2026(), horizon: 4).pages
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
        let months = CalendarMonthIndex.index(
            in: page, at: url("https://www.kaufmanmusiccenter.org/mch/calendar/"),
            now: july2026(), horizon: 4).pages

        #expect(months.allSatisfy { $0.host?.contains("kaufmanmusiccenter.org") == true })
        #expect(!months.contains { $0.absoluteString.contains("someoneelse.org") })
    }

    // #900. Everything above is Kaufman's shape: a month in the PATH (/2026/10/). It is the only shape
    // we can follow, and every other calendar on earth returns nothing and is read one month deep.
    //
    // Refusing to follow a shape we do not understand is right (guessing a URL pattern is what made the
    // original #858 premise dangerous). Doing it SILENTLY is not: a venue read one month deep looks
    // exactly like a venue read four months deep whose later months are empty, which is the app's normal
    // off-season state. Dan could watch a busy hall all season and never know he was seeing a quarter of
    // it.
    //
    // So the calendar's own month NAMES are read separately from its URLs, and the gap between what it
    // advertises and what we can fetch is reported.
    @Suite("A calendar whose month links we cannot follow (#900)")
    struct UnreachableMonths {

        private func url(_ s: String) -> URL { URL(string: s)! }

        private func july2026() -> Date {
            var c = DateComponents()
            c.year = 2026; c.month = 7; c.day = 13
            c.timeZone = TimeZone(identifier: "America/New_York")
            return Calendar(identifier: .gregorian).date(from: c)!
        }

        // The shape that started this: the month lives in the QUERY, not the path. `Month(pathOf:)` reads
        // nothing out of it, so there is no page to fetch. But the select still SAYS "October 2026", and
        // that is a fact about the calendar we can hand to Dan.
        private let queryPaged = """
        <select>
            <option value="?month=2026-07" selected>July 2026</option>
            <option value="?month=2026-08">August 2026</option>
            <option value="?month=2026-09">September 2026</option>
            <option value="?month=2026-10">October 2026</option>
        </select>
        """

        @Test func aMonthTheCalendarNamesButWeCannotReachIsSaidOutLoud() {
            let index = CalendarMonthIndex.index(
                in: queryPaged, at: url("https://merkin.example.org/calendar"),
                now: july2026(), horizon: 4)

            #expect(index.unreachableMonths == ["2026-08", "2026-09", "2026-10"])
        }

        // ...and we still do not paginate. Naming a month we cannot reach must never become a licence to
        // GUESS its URL. Nothing was fetched, and nothing about the document changed.
        @Test func namingAMonthWeCannotReachNeverInventsAURLForIt() {
            let index = CalendarMonthIndex.index(
                in: queryPaged, at: url("https://merkin.example.org/calendar"),
                now: july2026(), horizon: 4)

            #expect(index.pages.isEmpty)
        }

        // The month we LANDED on is not missing: it is the page in our hands. Telling Dan we could not
        // read July, on the very page whose July shows we just read, would be false.
        @Test func theMonthWeLandedOnIsNeverCalledUnreachable() {
            let index = CalendarMonthIndex.index(
                in: queryPaged, at: url("https://merkin.example.org/calendar"),
                now: july2026(), horizon: 4)

            #expect(!index.unreachableMonths.contains("2026-07"))
        }

        // A calendar we CAN page through has nothing missing. Kaufman must stay silent, or the note fires
        // on the one source it was built for and becomes noise.
        @Test func aCalendarWeCanFollowReportsNothingMissing() {
            let kaufman = """
            <select>
                <option value="https://www.kaufmanmusiccenter.org/mch/calendar/2026/07/">July 2026</option>
                <option value="https://www.kaufmanmusiccenter.org/mch/calendar/2026/08/">August 2026</option>
                <option value="https://www.kaufmanmusiccenter.org/mch/calendar/2026/09/">September 2026</option>
                <option value="https://www.kaufmanmusiccenter.org/mch/calendar/2026/10/">October 2026</option>
            </select>
            """
            let index = CalendarMonthIndex.index(
                in: kaufman, at: url("https://www.kaufmanmusiccenter.org/mch/calendar/"),
                now: july2026(), horizon: 4)

            #expect(index.pages.count == 4)
            #expect(index.unreachableMonths.isEmpty)
        }

        // THE FALSE POSITIVE THAT WOULD COST THE MOST. A blog archive is a list of links whose text is a
        // month name, which is exactly the signal this reads. It is not a calendar, and every month it
        // names is in the PAST, so there is nothing here Dan could pitch and nothing to tell him about.
        @Test func aBlogArchiveOfPastMonthsReportsNothingMissing() {
            let archive = """
            <ul>
            <li><a href="/2024/03/">March 2024</a></li>
            <li><a href="/2024/04/">April 2024</a></li>
            <li><a href="/2026/07/">July 2026</a></li>
            </ul>
            """
            let index = CalendarMonthIndex.index(
                in: archive, at: url("https://someblog.com/archive"),
                now: july2026(), horizon: 4)

            #expect(index.unreachableMonths.isEmpty)
        }

        // A show page names its own month in prose ("October 3rd, 2026"). It is not a link, it is not a
        // month index, and a note about missing months on a single show page is pure noise.
        @Test func aShowPageThatMerelyMentionsAMonthReportsNothingMissing() {
            let showPage = """
            <h1>Immortal Gifts</h1>
            <p>A concert at Merkin Hall on October 3rd, 2026, and again in November 2026.</p>
            <a href="/tickets">Buy tickets</a>
            """
            let index = CalendarMonthIndex.index(
                in: showPage, at: url("https://example.org/show/immortal-gifts"),
                now: july2026(), horizon: 4)

            #expect(index.unreachableMonths.isEmpty)
        }

        // A month on ANOTHER site was refused on purpose (#888: another site's calendar is another
        // organization's shows). Refused is not unreachable, and reporting it would send Dan hunting for
        // a month that was never his to begin with.
        @Test func aMonthOnAnotherSiteIsNotReportedAsMissing() {
            let page = """
            <select>
                <option value="https://www.kaufmanmusiccenter.org/mch/calendar/2026/08/">August 2026</option>
                <option value="https://someoneelse.org/calendar/?month=2026-09">September 2026</option>
            </select>
            """
            let index = CalendarMonthIndex.index(
                in: page, at: url("https://www.kaufmanmusiccenter.org/mch/calendar/"),
                now: july2026(), horizon: 4)

            #expect(index.unreachableMonths.isEmpty)
        }

        // The horizon caps what we COMPLAIN about, not just what we fetch. Kaufman lists 21 months out to
        // January 2028; a calendar that shape with an unfollowable link would otherwise hand Dan a list of
        // twenty missing months, nineteen of them too far out to pitch and none of them worth reading.
        @Test func theHorizonCapsWhatWeReportAsMissing() {
            let options = (7...12).map { "<option value=\"?m=2026-\($0)\">\(Self.monthName($0)) 2026</option>" }
                + (1...12).map { "<option value=\"?m=2027-\($0)\">\(Self.monthName($0)) 2027</option>" }
            let index = CalendarMonthIndex.index(
                in: "<select>\(options.joined())</select>",
                at: url("https://merkin.example.org/calendar"),
                now: july2026(), horizon: 4)

            // Four months of window, minus July, which is the page we are holding.
            #expect(index.unreachableMonths == ["2026-08", "2026-09", "2026-10"])
        }

        // A real select wraps its label in markup as often as not. The month is the link's TEXT, whatever
        // the markup around it, or this reads real calendars as blank.
        @Test func aMonthLabelWrappedInMarkupIsStillRead() {
            let page = """
            <a href="/cal?month=2026-10"><span class="m">October</span> <span>2026</span></a>
            """
            let index = CalendarMonthIndex.index(
                in: PageNormalizer.normalize(page), at: url("https://merkin.example.org/calendar"),
                now: july2026(), horizon: 4)

            #expect(index.unreachableMonths == ["2026-10"])
        }

        // "Oct 2026" is the same month as "October 2026". A calendar that abbreviates is not a calendar
        // we get to ignore.
        @Test func anAbbreviatedMonthLabelIsStillRead() {
            let page = "<select><option value=\"?m=10\">Oct 2026</option></select>"
            let index = CalendarMonthIndex.index(
                in: page, at: url("https://merkin.example.org/calendar"),
                now: july2026(), horizon: 4)

            #expect(index.unreachableMonths == ["2026-10"])
        }

        private static func monthName(_ m: Int) -> String {
            ["January", "February", "March", "April", "May", "June", "July",
             "August", "September", "October", "November", "December"][m - 1]
        }
    }
}
