import Testing
import Foundation

// #2656: half the listing text budget was spent on site navigation.
//
// On "54 Sings Shuffle Along, Or... A 10th Anniversary Celebration" (54 Below, 2026-08-17) the run was
// handed 3,999 characters with `truncated: true`. 1,950 of them, 49% of the whole budget, were 54 Below's
// site chrome before the show block began: a hydration promo banner, the phone number, and then the same
// navigation menu four times over for the mobile and toggle variants. The producer credit ("produced and
// directed by Corin Hale") landed at character 3,060 and survived by roughly 900 characters, entirely
// by luck of where the menu ended.
//
// The budget is not too small; it is being spent on a menu. So the fix is to stop paying for the menu
// twice, which needs no new guess at a limit (the issue's option 1, and its own reading of which option
// attacks the measurement rather than restating it).
//
// EVERY FIXTURE HERE IS MEASURED (L48). `fixtures/listing-chrome/archived-listings.json` holds the
// verbatim `showListing.text` of real archived prep runs on Dan's Mac, one per venue, copied out of the
// `overture-prep-queue.json` each run left behind. Nothing was shaped to make the rule fire, which
// matters because a rule about repetition is exactly the kind an invented fixture flatters.
@Suite("Stripping the menu a listing repeats (#2656)")
struct RepeatedBlockStripperTests {

    private struct Archived: Decodable {
        struct Listing: Decodable {
            let run: String
            let venue: String
            let groupName: String
            let truncated: Bool
            let text: String
        }
        let listings: [Listing]
    }

    private func archived() throws -> [Archived.Listing] {
        let url = RepoRoot.url.appendingPathComponent("fixtures/listing-chrome/archived-listings.json")
        return try JSONDecoder().decode(Archived.self, from: Data(contentsOf: url)).listings
    }

    private func listing(_ venuePrefix: String) throws -> Archived.Listing {
        try #require(try archived().first { $0.venue.hasPrefix(venuePrefix) })
    }

    // MARK: - The invariant that makes this safe at all

    // NOTHING IS LOST. The first occurrence of every run of words is kept and only later copies go, so
    // every distinct word the page published still reaches the run. This is the assertion that separates
    // stripping chrome from eating the listing (L104: a filter matching a SHAPE has to be tested against
    // what it must preserve, not only against what it must catch), and it holds over all eight venues,
    // not only the one the issue was filed about.
    @Test func noVenueLosesADistinctWord() throws {
        for l in try archived() {
            let before = Set(l.text.split(separator: " ").map(String.init))
            let after = Set(RepeatedBlockStripper.strip(l.text).split(separator: " ").map(String.init))
            #expect(before.subtracting(after).isEmpty,
                    "\(l.venue) lost \(before.subtracting(after).sorted().prefix(5))")
        }
    }

    // MARK: - What it actually returns, per venue

    // The page the issue is about. Measured on the archived text, which is already CUT at 4,000: the
    // copies of the menu that fell past the cap cannot be counted here, so 830 is a floor on what the
    // strip returns in production, not the figure. Stated rather than rounded up, because a number
    // measured with the expensive part switched off is the L102 trap.
    @Test func theFiftyFourBelowMenuStopsBeingPaidForFourTimes() throws {
        let l = try listing("54 Below")
        #expect(l.truncated, "this venue hits the cap on every run measured")
        let stripped = RepeatedBlockStripper.strip(l.text)
        #expect(l.text.count - stripped.count >= 830)

        // And what goes is the menu, not the show: the block that appeared three times appears ONCE.
        // Counted rather than tested for absence, because the first copy staying is the point.
        let menu = "Group Sales &amp; Special Occasions Gift Cards Seating Student Rush Catalogue Catalogue Artists Podcast"
        #expect(l.text.ranges(of: menu).count == 3)
        #expect(stripped.ranges(of: menu).count == 1)

        // The credit the issue was filed about. In the archived text it landed at character 3,060 and
        // survived the cut by roughly 900 characters purely by luck; here it is nearly a thousand
        // characters further from the edge.
        let creditBefore = try #require(l.text.range(of: "Produced by"))
        let creditAfter = try #require(stripped.range(of: "Produced by"))
        #expect(stripped.distance(from: stripped.startIndex, to: creditAfter.lowerBound)
                < l.text.distance(from: l.text.startIndex, to: creditBefore.lowerBound) - 800)
    }

    // The venue the 4,000 limit was calibrated on. It publishes no repeated block, so the strip must be a
    // no-op on it: a rule that quietly rewrote the calibration page would make the whole measurement above
    // unreadable.
    @Test func theGreenRoomFortyTwoPageIsUntouched() throws {
        let l = try listing("The Green Room 42")
        #expect(RepeatedBlockStripper.strip(l.text) == l.text)
    }

    // The venue that gains the most in proportion: 44% of its page was its own title, address and dates
    // restated. Every one of those facts still appears once.
    @Test func aTicketingPageStopsRestatingItsOwnHeader() throws {
        let l = try listing("Jalopy Theatre")
        let stripped = RepeatedBlockStripper.strip(l.text)
        #expect(l.text.count - stripped.count >= 590)
        #expect(stripped.contains("315 Columbia St, Brooklyn, New York"))
        #expect(stripped.contains("Jalopy Open Mic Every Wednesday"))
    }

    // MARK: - The threshold, stated as behaviour

    // Twelve words is long enough that a verbatim repeat is chrome rather than coincidence. A short repeat
    // is ordinary English and must survive: an act's name, a date, or a word like "and" appearing twice is
    // not a navigation block, and a rule that cut those would be silently rewriting the listing.
    @Test func aShortRepeatIsOrdinaryEnglishAndSurvives() {
        let text = "Aurora Strings play Bach. Aurora Strings play at eight."
        #expect(RepeatedBlockStripper.strip(text) == text)
    }

    @Test func aLongVerbatimRepeatGoesAndItsFirstCopyStays() {
        let block = "Calendar Plan Your Visit Group Sales Gift Cards Seating Student Rush Catalogue Artists Podcast Support"
        let text = "\(block) The show itself. \(block) More about the show."
        let stripped = RepeatedBlockStripper.strip(text)
        #expect(stripped == "\(block) The show itself. More about the show.")
    }

    // Three copies, not two, which is the shape 54 Below actually publishes (mobile and toggle variants of
    // one menu). Every copy after the first goes, rather than only the second.
    @Test func everyCopyAfterTheFirstGoes() {
        let block = "Calendar Plan Your Visit Group Sales Gift Cards Seating Student Rush Catalogue Artists Podcast Support"
        let stripped = RepeatedBlockStripper.strip("\(block) A \(block) B \(block) C")
        #expect(stripped == "\(block) A B C")
    }

    // Empty and single-word input cannot crash the reader, which sits between Dan pressing Prep and the
    // run launching: a trap here would take the whole run with it.
    @Test func degenerateInputIsHandled() {
        #expect(RepeatedBlockStripper.strip("") == "")
        #expect(RepeatedBlockStripper.strip("Hello") == "Hello")
    }

    // MARK: - Wired, not merely built

    // A correct rule that nothing calls returns nothing to anybody (L3). This drives the real reader over a
    // page carrying the menu twice and asserts the run is handed one copy, so the strip has to be ON the
    // path between the page and the queue file rather than merely existing beside it.
    //
    // The menu is put BEFORE the description on purpose, which is where 54 Below's is: that is the whole
    // reason it was eating the budget the show block needed.
    @Test func theReaderStripsTheRepeatBeforeSpendingTheBudget() async throws {
        let menu = "Calendar Plan Your Visit Group Sales Gift Cards Seating Student Rush Catalogue Artists"
        let html = """
        <html><body><nav>\(menu)</nav><nav>\(menu)</nav><nav>\(menu)</nav>
        <p>A cabaret concert of new songs, produced by Gabrielle Karyss.</p></body></html>
        """
        let listing = await ShowListingReader.read(listingURL: "https://tickets.example/showdetails/abc",
                                                   render: { _ in html })
        let text = try #require(listing?.text)
        #expect(text.ranges(of: menu).count == 1)
        #expect(text.contains("produced by Gabrielle Karyss"))
    }
}
