import Testing
import Foundation
@testable import Overture

// #1824: the app reads what a show actually IS and hands it to the Prep run.
//
// The page this exists for was MEASURED, not imagined. The Green Room 42 listing the 2026-07-30 draft
// was written from (`thegreenroom42.venuetix.com/showdetails/...`) is drawn entirely client-side: a plain
// download returns an 11KB shell carrying zero occurrences of "cabaret", while the rendered page carries
// 1,994 characters of visible text that say outright what the show is (a cabaret concert of new songs by
// one songwriter, a named cast, a 75 minute running time). The synthetic pages below are shaped from that
// measurement: a nav bar, an "About the Show" block, a cast list, and a footer, with the description
// reachable only after the scripts have run.
//
// The Prep run cannot do this itself. Its tool scope (`PREP_ALLOWED_TOOLS`) denies every browser tool, and
// the 2026-07-30 run proves it: it fetched the listing, got the shell, asked for a browser render and was
// refused, then drafted anyway. So the render happens here, on the app side, and the run is handed text.
@MainActor
@Suite("Reading a show's own listing page (#1824)")
struct ShowListingReaderTests {

    // A page whose description exists only after its scripts run, exactly like the measured one.
    private func showPage(description: String) -> String {
        """
        <html><head><title>The Green Room</title></head>
        <body>
          <script>var app = { boot: true };</script>
          <nav><a href="/events">Events</a><a href="/faq">FAQ</a><a href="/contact">Contact</a></nav>
          <h1>Nightingale Quartet</h1>
          <h2>About the Show</h2>
          <p>\(description)</p>
          <div class="cast"><span>Featuring:</span><span>Ada Fenwick</span><span>Ruben Oyelaran</span></div>
          <dl><dt>Genre</dt><dd>New Artists</dd><dt>Duration</dt><dd>75 minutes</dd></dl>
          <footer>Powered by an example ticketing host</footer>
        </body></html>
        """
    }

    private let realShapedDescription =
        "A cabaret concert of new songs written by one songwriter, built around a simple but resonant "
        + "idea, that we are often our own harshest critics."

    @Test func handsBackTheDescriptionARenderedPageCarries() async {
        let listing = await ShowListingReader.read(
            listingURL: "https://tickets.example/showdetails/abc",
            render: { _ in showPage(description: realShapedDescription) })

        #expect(listing?.status == ShowListing.read)
        #expect(listing?.url == "https://tickets.example/showdetails/abc")
        #expect(listing?.text?.contains("cabaret concert of new songs") == true)
        // The cast and the running time are part of what the show IS, so they must survive too.
        #expect(listing?.text?.contains("Ada Fenwick") == true)
        #expect(listing?.text?.contains("75 minutes") == true)
        // Script source is not something a person reads off the page, and it is what made a real Wix
        // fetch unreadable (#806). It must not reach the drafter as if it were the show's description.
        #expect(listing?.text?.contains("var app") == false)
        #expect(listing?.truncated == nil)
    }

    // The failure path, and the one that matters most. A page that will not load must read as UNREADABLE,
    // never as a show with no description: those two are different answers and the run says different
    // things about them (L11). Silently handing back "no description" would put the drafter right back
    // where the 2026-07-30 draft was, inventing what the show is, with the app now vouching for it.
    @Test func aPageThatWillNotLoadIsUnreadableNotAShowWithNoDescription() async {
        struct Dead: Error {}
        let listing = await ShowListingReader.read(
            listingURL: "https://tickets.example/showdetails/abc",
            render: { _ in throw Dead() })

        #expect(listing?.status == ShowListing.unreadable)
        #expect(listing?.text == nil)
        #expect(listing?.url == "https://tickets.example/showdetails/abc")
    }

    // A render that returns a shell (the scripts never ran, or the site served a stub) carries nothing to
    // read. Same verdict as a dead page: we could not read it, and we say so rather than pass chrome along
    // as if it described the show.
    @Test func aRenderedShellWithNothingToReadIsUnreadable() async {
        let listing = await ShowListingReader.read(
            listingURL: "https://tickets.example/showdetails/abc",
            render: { _ in "<html><body><script>boot();</script></body></html>" })

        #expect(listing?.status == ShowListing.unreadable)
        #expect(listing?.text == nil)
    }

    // No listing URL at all is a third answer: the app never looked, because there was nothing to look at.
    // Absent, not "unreadable", so the run can tell "we tried and failed" from "there was no page".
    @Test func noListingURLMeansTheAppNeverLooked() async {
        let flag = RenderFlag()
        let listing = await ShowListingReader.read(listingURL: nil,
                                                   render: { _ in flag.rendered = true; return "<html/>" })
        #expect(listing == nil)
        #expect(flag.rendered == false)
    }

    @Test func anUnusableListingURLIsNotRendered() async {
        let flag = RenderFlag()
        let listing = await ShowListingReader.read(listingURL: "   ",
                                                   render: { _ in flag.rendered = true; return "<html/>" })
        #expect(listing == nil)
        #expect(flag.rendered == false)
    }

    // A reference so the two "we never touched the browser" tests can observe the injected renderer from
    // inside a Sendable closure (a captured local `var` cannot cross that boundary).
    @MainActor private final class RenderFlag { var rendered = false }

    // The queue file is read by a detached run through a line-oriented Read tool, and a single oversized
    // line is the exact shape that left an 82KB page half-read forever (#1056, PageNormalizer's
    // readerLineWidth note). So the text is bounded, and a page that had to be cut SAYS it was cut: a
    // description that fell past the cut must not read to the run as a page that published none.
    @Test func anOverlongPageIsCutAndSaysSo() async {
        let filler = String(repeating: "long programme note. ", count: 2000)
        let listing = await ShowListingReader.read(
            listingURL: "https://tickets.example/showdetails/abc",
            render: { _ in self.showPage(description: filler) })

        #expect(listing?.status == ShowListing.read)
        #expect((listing?.text?.count ?? 0) <= ShowListingReader.textLimit)
        #expect(listing?.truncated == true)
    }

    // Reading a whole run's worth of listings: every item that has a URL gets an answer keyed by its own
    // natural key, and progress is reported as it goes, because a launch that renders a dozen pages must
    // show working / still alive / failed as distinct states rather than one indefinite spinner.
    @Test func readsEveryItemInTheRunAndReportsProgress() async {
        let items = [
            item(key: "a", url: "https://tickets.example/a"),
            item(key: "b", url: "https://tickets.example/b"),
            item(key: "c", url: nil),
        ]
        var seen: [Int] = []
        let listings = await ShowListingReader.readAll(
            for: items,
            render: { _ in self.showPage(description: self.realShapedDescription) },
            onProgress: { done, total in seen.append(done); #expect(total == 3) })

        #expect(listings.count == 2)
        #expect(listings["a"]?.status == ShowListing.read)
        #expect(listings["b"]?.status == ShowListing.read)
        // The item with no listing URL is absent, not a fabricated "unreadable" entry.
        #expect(listings["c"] == nil)
        // Progress ends at the full count, and the item with nothing to read still advances it: a
        // counter that stalls on the skipped items reads as a stuck run.
        #expect(seen.last == 3)
    }

    // One dead page must not take the rest of the run's listings down with it. The other shows still get
    // their descriptions, and the dead one is recorded as unreadable rather than dropped.
    @Test func oneDeadPageDoesNotCostTheRunItsOtherListings() async {
        struct Dead: Error {}
        let items = [item(key: "a", url: "https://tickets.example/a"),
                     item(key: "b", url: "https://tickets.example/dead")]
        let listings = await ShowListingReader.readAll(
            for: items,
            render: { url in
                if url.absoluteString.contains("dead") { throw Dead() }
                return self.showPage(description: self.realShapedDescription)
            })

        #expect(listings["a"]?.status == ShowListing.read)
        #expect(listings["b"]?.status == ShowListing.unreadable)
    }

    private func item(key: String, url: String?) -> PrepQueueItem {
        PrepQueueItem(naturalKey: key, groupName: "G", venue: "V", performanceDate: "2026-08-03",
                      discipline: "other", websiteURL: nil, sourceListingURL: url,
                      possibleMatchName: nil, priorRelationship: "none")
    }
}
