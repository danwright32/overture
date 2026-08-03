import Testing
import Foundation

// The lesson from the first real run of the extract path (#799), turned into a rule the code enforces
// rather than a paragraph the runbook asks for.
//
// Bargemusic's listings page names no venue at all: each concert carries a NUMERIC venue id. The run
// got the right answer ("Brooklyn Bridge Park Boathouse at Pier 5") only because it followed the
// event's own detail page, exactly as the runbook tells it to. But a runbook is a request, not a
// guarantee. If a future run skips that step, or a page's detail links break, the events still come
// back looking perfectly well-formed, with a venue of "3" or of nothing at all.
//
// That is not a cosmetic defect. The venue drives the classifier AND the pitch itself: Dan's email
// says "your March 10 concert at Carnegie Hall". A prospect with no venue, or with a venue of "3",
// produces an email that names the wrong place, and nothing downstream would ever catch it, because
// nothing downstream knows what the venue was supposed to be.
//
// So a venue-less event never becomes a prospect silently. It is rejected, with a reason, and the
// rejection is reportable as a problem WITH THAT SOURCE (its detail pages are not being read), which
// is the actionable thing: "this source returned 6 shows and none of them have a venue" tells Dan
// something is wrong with the source, where 6 venue-less prospects would just quietly poison his queue.
@Suite("Extracted event guard (#799)")
struct ExtractedEventGuardTests {
    private func event(title: String = "Aurora Strings", venue: String?,
                       date: String? = "2026-09-19", location: String? = nil) -> ExtractedEvent {
        ExtractedEvent(title: title, presenter: "Aurora Strings", venue: venue,
                       performanceDate: date, sourceUrl: "https://org.example/a", location: location)
    }

    @Test func aRealVenuePasses() {
        #expect(ExtractedEventGuard.rejection(for: event(venue: "Merkin Hall")) == nil)
        #expect(ExtractedEventGuard.rejection(
            for: event(venue: "Brooklyn Bridge Park Boathouse at Pier 5, Brooklyn, NY")) == nil)
    }

    @Test func aMissingVenueIsRejectedNotQuietlyAccepted() {
        #expect(ExtractedEventGuard.rejection(for: event(venue: nil)) == .noVenue)
        #expect(ExtractedEventGuard.rejection(for: event(venue: "")) == .noVenue)
        #expect(ExtractedEventGuard.rejection(for: event(venue: "   ")) == .noVenue)
    }

    // The exact Bargemusic shape: the listings page's venue field is a numeric id. An extractor that
    // did not follow the detail page would hand back "3", which is not a venue, reads as one, and would
    // end up in an email.
    @Test func aNumericVenueIdIsNotAVenue() {
        #expect(ExtractedEventGuard.rejection(for: event(venue: "3")) == .placeholderVenue)
        #expect(ExtractedEventGuard.rejection(for: event(venue: "12")) == .placeholderVenue)
        #expect(ExtractedEventGuard.rejection(for: event(venue: "  7 ")) == .placeholderVenue)
    }

    // A model that could not find the venue and said so, rather than inventing one, must still not have
    // its non-answer treated as an answer.
    @Test func aStatedNonAnswerIsNotAVenue() {
        for nonAnswer in ["unknown", "Unknown", "n/a", "N/A", "null", "TBD", "tbc", "-"] {
            #expect(ExtractedEventGuard.rejection(for: event(venue: nonAnswer)) == .placeholderVenue,
                    "\(nonAnswer) must not be accepted as a venue")
        }
    }

    // #1087: an empty title no longer drops a show on its own. This row (the helper always carries a
    // presenter) now has a name derived from that presenter, so it is KEPT rather than rejected as
    // `.noTitle`. The dedicated rescue tests below pin the naming, the precedence, and the one case
    // where nothing at all can name the show.
    @Test func anEmptyTitleWithAPresenterIsRescuedNotRejected() {
        #expect(ExtractedEventGuard.rejection(for: event(title: "", venue: "Merkin Hall")) == nil)
    }

    // #1087: a genuine performance can arrive with an EMPTY title but a real presenter (the act itself),
    // venue, and date. A touring artist page that lists dates under one performer names no per-show
    // "title" at all, only the performer. Dropping such a show as `.noTitle` is the silent loss #799's
    // venue guard exists to prevent, from the other side: the show has a perfectly good name (its
    // presenter). The guard now tries to name it before dropping, so the row is kept and its name is the
    // presenter, which flows through to the prospect's `groupName` and becomes half its natural key.
    @Test func aTitlelessShowIsRescuedAndNamedByItsPresenter() {
        let e = ExtractedEvent(title: "", presenter: "Aurora Strings", venue: "Merkin Hall",
                               performanceDate: "2026-09-19", sourceUrl: "https://org.example/a",
                               location: nil)
        #expect(ExtractedEventGuard.rejection(for: e) == nil)
        #expect(ExtractedEventGuard.displayName(for: e) == "Aurora Strings")
    }

    // No title AND no presenter, but a real venue: the venue names it. A named room is a weaker name than
    // the act, but it is a real one and far better than dropping a genuine show. It becomes the
    // prospect's `groupName`.
    @Test func aTitlelessPresenterlessShowIsRescuedByItsVenue() {
        let e = ExtractedEvent(title: "", presenter: nil, venue: "Merkin Hall",
                               performanceDate: "2026-09-19", sourceUrl: "https://org.example/a",
                               location: nil)
        #expect(ExtractedEventGuard.rejection(for: e) == nil)
        #expect(ExtractedEventGuard.displayName(for: e) == "Merkin Hall")
    }

    // Precedence is title, then presenter, then venue: the "who" is named before the "where", because
    // that is what Dan reads first and what the pitch is about. When both a presenter and a venue are
    // present on a titleless row, the presenter wins.
    @Test func presenterWinsOverVenueWhenNamingATitlelessShow() {
        let e = ExtractedEvent(title: "   ", presenter: "Aurora Strings", venue: "Merkin Hall",
                               performanceDate: "2026-09-19", sourceUrl: "https://org.example/a",
                               location: nil)
        #expect(ExtractedEventGuard.displayName(for: e) == "Aurora Strings")
    }

    // A real title still names the show, ahead of both presenter and venue. The rescue is a fallback, not
    // a replacement.
    @Test func aTitledShowIsStillNamedByItsTitle() {
        let e = ExtractedEvent(title: "Winter Gala", presenter: "Aurora Strings", venue: "Merkin Hall",
                               performanceDate: "2026-09-19", sourceUrl: "https://org.example/a",
                               location: nil)
        #expect(ExtractedEventGuard.displayName(for: e) == "Winter Gala")
    }

    // Nothing to name it with: empty title, empty presenter, empty venue. THIS is what `.noTitle` now
    // means, a row with no name and no way to derive one, rather than merely an absent title string.
    // Whitespace-only fields count as empty.
    @Test func aShowWithNothingToNameItIsStillDroppedAsNoTitle() {
        #expect(ExtractedEventGuard.rejection(for: ExtractedEvent(
            title: "", presenter: nil, venue: nil, performanceDate: "2026-09-19",
            sourceUrl: "https://org.example/a", location: nil)) == .noTitle)
        #expect(ExtractedEventGuard.rejection(for: ExtractedEvent(
            title: "   ", presenter: "  ", venue: "  ", performanceDate: "2026-09-19",
            sourceUrl: "https://org.example/a", location: nil)) == .noTitle)
        #expect(ExtractedEventGuard.displayName(for: ExtractedEvent(
            title: "", presenter: nil, venue: nil, performanceDate: nil,
            sourceUrl: nil, location: nil)) == nil)
    }

    // #995. A city is not a room, and a run that copies the location into the venue defeats this whole
    // guard while looking like it passed it. These four are verbatim from the first real scout of a
    // venue-less page (Smoke Ring Quartet, 2026-07-16), and are in the live store today. The run said so
    // itself: "Venue field populated with location as best available specificity."
    //
    // The guard cannot see a page, so it cannot know a venue was never published. It CAN see that the
    // venue only restates the location, which is the same fact wearing a disguise.
    @Test func aVenueThatMerelyRestatesTheLocationIsNotAVenue() {
        for place in ["Baltimore, Maryland", "San Rafael, CA", "Harrogate, UK", "Palm Springs, CA"] {
            #expect(ExtractedEventGuard.rejection(for: event(venue: place, location: place))
                    == .locationAsVenue,
                    "\(place) is a place, not a venue, and must not pass as one")
        }
    }

    // #1498: the disguise that got through. A run reported the city with its own explanation stapled on
    // the end, and because the guard compared the raw string, neither the equality nor the clause check
    // matched, so it passed. It reached the live store as a venue and would have gone into a pitch:
    // "downtown Brooklyn, NY (specific venue not named on page)" on the 2026 Brooklyn Folk Festival.
    // A parenthetical is a note ABOUT the venue, never part of its name, so it is stripped before the
    // comparison.
    @Test func aCityWithAnExplanationStapledOnIsStillNotAVenue() {
        #expect(ExtractedEventGuard.rejection(
            for: event(venue: "downtown Brooklyn, NY (specific venue not named on page)",
                       location: "downtown Brooklyn, NY")) == .locationAsVenue)
        #expect(ExtractedEventGuard.rejection(
            for: event(venue: "Baltimore (venue TBA)", location: "Baltimore, Maryland")) == .locationAsVenue)
    }

    // The other half: a real venue that legitimately carries a parenthetical keeps passing. Stripping it
    // for the comparison must not start rejecting rooms that are named this way.
    @Test func aRealVenueKeepsItsParenthetical() {
        #expect(ExtractedEventGuard.rejection(
            for: event(venue: "Merkin Hall (Kaufman Music Center)", location: "New York, NY")) == nil)
        #expect(ExtractedEventGuard.rejection(
            for: event(venue: "The Church of St. Mary the Virgin (Times Square)",
                       location: "New York, NY")) == nil)
    }

    // The same disguise with the edges filed off: a run that reports the city alone, or in another case,
    // is making the identical claim and must fail identically.
    @Test func restatingOnlyPartOfTheLocationIsStillNotAVenue() {
        #expect(ExtractedEventGuard.rejection(
            for: event(venue: "Baltimore", location: "Baltimore, Maryland")) == .locationAsVenue)
        #expect(ExtractedEventGuard.rejection(
            for: event(venue: "  harrogate ", location: "Harrogate, UK")) == .locationAsVenue)
    }

    // The rule must not fire the other way round. A REAL venue routinely names its own city, and this is
    // the exact string the runbook holds up as the right answer (Bargemusic's detail page, #799). If
    // this ever rejects, the guard has started eating the events it exists to protect.
    @Test func aRealVenueThatNamesItsOwnCityStillPasses() {
        #expect(ExtractedEventGuard.rejection(
            for: event(venue: "Brooklyn Bridge Park Boathouse at Pier 5, Brooklyn, NY",
                       location: "Brooklyn, NY")) == nil)
        #expect(ExtractedEventGuard.rejection(
            for: event(venue: "Weill Recital Hall", location: "New York, NY")) == nil)
    }

    // A venue-less row on a page that names no place either. There is nothing to compare against, so
    // this stays the plain `.noVenue` it always was, rather than becoming the new reason.
    @Test func aVenuelessEventWithNoLocationIsStillJustVenueless() {
        #expect(ExtractedEventGuard.rejection(for: event(venue: nil, location: nil)) == .noVenue)
        #expect(ExtractedEventGuard.rejection(for: event(venue: nil, location: "Baltimore, Maryland"))
                == .noVenue)
    }

    // #979 requires "no venue was published" and "the model gave up" to stay distinguishable, or the
    // guard is merely weakened. Dan's ruling (a venue-less NYC show is worth chasing, a venue-less
    // Harrogate one is not) can only ever be built on top of a reason that says which happened.
    @Test func theReasonSaysAPlaceWasGivenRatherThanNothingAtAll() {
        #expect(ExtractedEventGuard.Rejection.locationAsVenue != .noVenue)
        #expect(ExtractedEventGuard.Rejection.locationAsVenue != .placeholderVenue)
    }

    // An undated listing is NOT rejected: "date to be confirmed" is a normal state on a season page,
    // and #798's guard already handles what to do with it. The venue is the field we cannot do without.
    @Test func anUndatedEventIsStillUsable() {
        #expect(ExtractedEventGuard.rejection(for: event(venue: "Merkin Hall", date: nil)) == nil)
    }

    // #1057: a SPECIFIC, NAMED outdoor performance space is a real venue, not a bare location wearing
    // a venue's clothes. The signal the guard can see is a recognizable place-type word ("Park",
    // "Square", "Pier"...) that a bare city/state/country name never carries. These are the two real
    // drops #1057 found live: Every Voice Choirs' Oct 25 2026 show at "Sakura Park, W 122nd St &
    // Riverside Dr", and Jalopy Theatre's Golden Hour Series at Greeley Square, both wrongly discarded
    // because the page's location string repeats the venue name, tripping `restatesLocation`.
    @Test func aNamedOutdoorPlaceIsAVenueEvenWhenTheLocationRepeatsIt() {
        #expect(ExtractedEventGuard.rejection(
            for: event(venue: "Sakura Park", location: "Sakura Park, W 122nd St & Riverside Dr")) == nil)
        #expect(ExtractedEventGuard.rejection(
            for: event(venue: "Greeley Square", location: "Greeley Square, New York, NY")) == nil)
        #expect(ExtractedEventGuard.rejection(for: event(venue: "Bryant Park", location: "Bryant Park"))
                == nil)
    }

    // #1214: the model sometimes NULLS the venue for a named outdoor space and leaves the place only in
    // `location` (the runbook says a named outdoor space IS the venue, but a prompt is a request, not a
    // guarantee). The deterministic net: when the venue is blank but the location names an outdoor
    // place, promote that location into the venue rather than dropping a real, pitchable show. This is
    // the exact Every Voice Choirs / Sakura Park drop found live, read correctly then discarded.
    @Test func aVenuelessOutdoorLocationIsPromotedToTheVenue() {
        let e = event(venue: nil, location: "Sakura Park, W 122nd St & Riverside Dr")
        #expect(ExtractedEventGuard.rejection(for: e) == nil)
        #expect(ExtractedEventGuard.placed(e).venue == "Sakura Park, W 122nd St & Riverside Dr")
    }

    // The promotion is strictly the #1057 outdoor carve-out, never a bare city: "Baltimore, Maryland"
    // carries no place-type word, so it is not promoted and the show stays dropped as venueless.
    // Without this the #995 "city in the venue field" bug would walk right back in.
    @Test func aVenuelessBareCityLocationIsNotPromoted() {
        let e = event(venue: nil, location: "Baltimore, Maryland")
        #expect(ExtractedEventGuard.rejection(for: e) == .noVenue)
        #expect(ExtractedEventGuard.placed(e).venue == nil)
    }

    // Idempotent: a show that already names its own venue is never touched, even when its location also
    // names an outdoor place.
    @Test func placedLeavesAnExistingVenueAlone() {
        let e = event(venue: "Merkin Hall", location: "Bryant Park")
        #expect(ExtractedEventGuard.placed(e).venue == "Merkin Hall")
    }
}

// The guard is wired into the results boundary itself, not left as a helper an ingest might forget to
// call. `events(for:)` returns only what is USABLE; the rejects are reportable separately. Enforcing it
// by construction is the point: the whole failure this prevents is a step being silently skipped.
@Suite("Scout extract results reject unusable events (#799)")
struct ScoutExtractResultsGuardTests {
    private func results(_ events: [ScoutExtractEvent]) -> ScoutExtractResults {
        ScoutExtractResults(version: 1, generatedAt: "2026-07-12T00:00:00Z",
                            results: [ScoutExtractResult(sourceId: "s", verdict: .upcomingListings,
                                                         events: events, note: nil)])
    }

    private func event(_ title: String, venue: String?, location: String? = nil,
                       sourceUrl: String? = nil) -> ScoutExtractEvent {
        ScoutExtractEvent(title: title, presenter: title, venue: venue,
                          performanceDate: "2026-09-19",
                          sourceUrl: sourceUrl ?? "https://org.example/\(title)",
                          location: location)
    }

    // #1278: a registration/signup-form listing link is stripped at the boundary while the show survives.
    // DCINY's /opportunities/ rows link to a getfeedback.com "apply to sing" form; the runbook forbids
    // recording one (rule 3c), but a prompt is a request, not a guarantee, so the boundary enforces it.
    @Test func aSignupFormListingLinkIsStrippedAtTheBoundaryButTheShowSurvives() {
        let r = results([event("Faith and Freedom", venue: "Carnegie Hall",
                               sourceUrl: "https://dciny.getfeedback.com/r/abc123")])
        let usable = r.events(for: "s")
        #expect(usable.count == 1)                  // the real Carnegie concert is kept...
        #expect(usable.first?.title == "Faith and Freedom")
        #expect(usable.first?.sourceUrl == nil)     // ...with only the bad link drained off
        #expect(r.rejectedEvents(for: "s").isEmpty) // a stripped link is not a rejected show
    }

    @Test func aRealConcertListingLinkSurvivesTheBoundaryUntouched() {
        let good = "https://dciny.org/events/faith-and-freedom/"
        let r = results([event("Faith and Freedom", venue: "Carnegie Hall", sourceUrl: good)])
        #expect(r.events(for: "s").first?.sourceUrl == good)
    }

    // #1291: when the boundary strips a form link, a listings-page URL threaded in from the source falls
    // through to the kept show, so a DCINY /opportunities/ prospect is not left with nothing to open.
    @Test func aStrippedFormFallsBackToTheSourceListingsPageAtTheBoundary() {
        let r = results([event("Faith and Freedom", venue: "Carnegie Hall",
                               sourceUrl: "https://dciny.getfeedback.com/r/abc123")])
        let usable = r.events(for: "s", listingsURL: "https://www.dciny.org/opportunities/")
        #expect(usable.count == 1)
        #expect(usable.first?.sourceUrl == "https://www.dciny.org/opportunities/")
    }

    @Test func onlyUsableEventsComeOutOfTheResults() {
        let r = results([event("Good Show", venue: "Merkin Hall"),
                         event("No Venue", venue: nil),
                         event("Numeric Id", venue: "3")])

        let usable = r.events(for: "s")
        #expect(usable.count == 1)
        #expect(usable.first?.title == "Good Show")
    }

    // The rejects are not thrown away: a source that returns SIX shows and no venues is a source whose
    // detail pages are not being read, and that is a fact about the source Dan can act on. Six silently
    // venue-less prospects would just poison the queue.
    @Test func theRejectsAreReportableAgainstTheSourceThatProducedThem() {
        let r = results([event("Good Show", venue: "Merkin Hall"),
                         event("No Venue", venue: nil),
                         event("Numeric Id", venue: "3")])

        let rejected = r.rejectedEvents(for: "s")
        #expect(rejected.count == 2)
        #expect(rejected.map(\.reason).contains(.noVenue))
        #expect(rejected.map(\.reason).contains(.placeholderVenue))
        #expect(rejected.first(where: { $0.reason == .noVenue })?.title == "No Venue")
    }

    // #995: the wire, not the rule. The rule rejecting a city and the BOUNDARY dropping it are two
    // separate claims, and only the second one keeps a fabricated venue out of Dan's store. This is the
    // exact payload the first real scout of Smoke Ring Quartet returned.
    @Test func aCityDisguisedAsAVenueIsDroppedAtTheBoundaryAndReported() {
        let r = results([event("Good Show", venue: "Merkin Hall", location: "New York, NY"),
                         event("LABBS 50th Convention", venue: "Harrogate, UK",
                               location: "Harrogate, UK")])

        #expect(r.events(for: "s").map(\.title) == ["Good Show"])

        let rejected = r.rejectedEvents(for: "s")
        #expect(rejected.count == 1)
        #expect(rejected.first?.title == "LABBS 50th Convention")
        #expect(rejected.first?.reason == .locationAsVenue)
    }

    // #1214: a venueless show whose location names an outdoor space comes OUT of the boundary with the
    // location PROMOTED into the venue, so it reaches the prospect placed rather than dropped. The
    // guard's verdict alone is not enough: the event that becomes a prospect has to actually carry the
    // venue, or the pitch names nowhere.
    @Test func aVenuelessOutdoorShowIsPromotedAndSurvivesTheBoundary() {
        let r = results([event("Pumpkin Singalong", venue: nil,
                               location: "Sakura Park, W 122nd St & Riverside Dr")])
        let usable = r.events(for: "s")
        #expect(usable.count == 1)
        #expect(usable.first?.venue == "Sakura Park, W 122nd St & Riverside Dr")
        #expect(r.rejectedEvents(for: "s").isEmpty)
    }

    @Test func aSourceWhoseEventsAreAllVenuelessIsVisiblyBrokenRatherThanEmpty() {
        let r = results([event("A", venue: nil), event("B", venue: "7")])

        #expect(r.events(for: "s").isEmpty)                 // nothing usable...
        #expect(r.rejectedEvents(for: "s").count == 2)      // ...but NOT because the page was empty
        #expect(r.verdict(for: "s") == .upcomingListings)   // the page HAD shows; we just can't use them
    }

    // MARK: - #1032: rejected shows split by whether the reason is about a venue or a title.

    // The three venue reasons (the detail page was not read) are counted apart from the one that has
    // nothing to do with a detail page (a row with no name), so the Sources note can stop calling a
    // titleless drop "no venue". Usable events are not counted at all.
    // Built directly rather than via the two overloaded `event` helpers in this file, whose shared name
    // makes an explicit per-title list ambiguous.
    private func extracted(_ title: String, venue: String?, location: String? = nil) -> ExtractedEvent {
        ExtractedEvent(title: title, presenter: title, venue: venue,
                       performanceDate: "2026-09-19", sourceUrl: "https://org.example/a", location: location)
    }

    @Test func rejectionCountsSplitVenueReasonsFromTitleReasons() {
        let counts = ExtractedEventGuard.rejectionCounts(for: [
            extracted("Good", venue: "Merkin Hall"),                                 // usable
            extracted("No venue", venue: nil),                                       // venue
            extracted("Placeholder", venue: "3"),                                    // venue
            extracted("City", venue: "Harrogate, UK", location: "Harrogate, UK"),    // venue
            extracted("", venue: nil)                                                // title (#1087: nothing to name it, and no venue either)
        ])
        #expect(counts.venueRelated == 3)
        #expect(counts.titleRelated == 1)
        // #1472: on the default (an .html source, whose events ARE read page by page) every drop is still a
        // suspected reading failure, so the count the #887 tolerance measures is unchanged.
        #expect(counts.unreadTotal == 4)
        #expect(counts.structuralGapCount == 0)
    }

    @Test func rejectionCountsAreZeroWhenEveryEventIsUsable() {
        let counts = ExtractedEventGuard.rejectionCounts(for: [
            extracted("A", venue: "Merkin Hall"),
            extracted("B", venue: "Carnegie Hall")
        ])
        #expect(counts == RejectionCounts(venueRelated: 0, titleRelated: 0))
        #expect(counts.unreadTotal == 0)
        #expect(counts.droppedTotal == 0)
    }

    // LIVE-STORE-CLAIM verified=2026-07-29 measure="open rows whose presenter is spelled exactly like their own venue"
    // #1766: the AGENT door, and the one that matters. FRIGID New York's rows come through here, so a
    // drain wired only into the native extractor path would have left the reported case untouched.
    // Measured before this shipped: 163 of 512 open rows carried a presenter spelled exactly like their
    // own venue, which is what the paid contact hunt then goes looking for an inbox for.
    //
    // The show SURVIVES. It is real and Dan should see it; what goes is the false claim about who is
    // putting it on.
    @Test func aPresenterThatIsReallyTheRoomIsDrainedAtTheBoundaryButTheShowSurvives() {
        let r = results([ScoutExtractEvent(title: "Italian Abroad: Culture in Translation",
                                           presenter: "Under St Marks", venue: "Under St Marks",
                                           performanceDate: "2026-09-19",
                                           sourceUrl: "https://tickets.frigid.nyc/italian-abroad",
                                           location: nil)])
        let usable = r.events(for: "s")
        #expect(usable.count == 1)
        #expect(usable.first?.presenter == nil)
        #expect(usable.first?.venue == "Under St Marks")
        // #1788, Dan's call on the #1766 post-merge check: "flag the card for me". A discarded name and a
        // page that named nobody are DIFFERENT facts, and he can act on the first. Without this the two
        // are indistinguishable the moment the name is drained.
        #expect(usable.first?.presenterWasTheRoom == true)
    }

    // And a show whose page genuinely named nobody is NOT flagged, or the mark would say "Overture threw
    // a name away here" on every row that never had one, which is most of them.
    @Test func aShowThatNamedNobodyIsNotFlaggedAsHavingHadAPresenterDiscarded() {
        let r = results([ScoutExtractEvent(title: "A Quiet Listing", presenter: nil,
                                           venue: "Under St Marks", performanceDate: "2026-09-19",
                                           sourceUrl: "https://tickets.frigid.nyc/quiet", location: nil)])
        #expect(r.events(for: "s").first?.presenterWasTheRoom != true)
    }

    // And a real presenter reaches the prospect untouched, or the guard would erase the very thing the
    // runbook rule exists to capture.
    @Test func arealPresenterReachesTheProspectThroughTheBoundary() {
        let r = results([ScoutExtractEvent(title: "Sins and Stardust Burlesque",
                                           presenter: "Stiletto Sinclair and Jackie Galaxy",
                                           venue: "Under St Marks", performanceDate: "2026-09-19",
                                           sourceUrl: "https://tickets.frigid.nyc/sins", location: nil)])
        #expect(r.events(for: "s").first?.presenter == "Stiletto Sinclair and Jackie Galaxy")
    }
}

// #1278: the listing link (`sourceUrl`) is what Dan clicks to look a concert up. Some rows link only to a
// performer signup/registration form (DCINY's /opportunities/ rows link to getfeedback.com "apply to sing"
// pages), which sends Dan to join the choir, not to the show he is deciding whether to photograph. Runbook
// rule 3c forbids recording one, but a prompt is a request, not a guarantee: the guard nulls a known
// registration-form host so a bad link can never reach the store, while keeping the real, pitchable show.
@Suite("Signup-form listing links are stripped (#1278)")
struct SignupFormSourceURLGuardTests {
    private func event(sourceUrl: String?) -> ExtractedEvent {
        ExtractedEvent(title: "We Sing Noel", presenter: "Joel Raney", venue: "Carnegie Hall",
                       performanceDate: "2026-11-16", sourceUrl: sourceUrl, location: nil)
    }

    @Test func aGetFeedbackFormLinkIsNulled() {
        #expect(ExtractedEventGuard.sanitizedSourceURL(
            event(sourceUrl: "https://dciny.getfeedback.com/r/abc123")).sourceUrl == nil)
        #expect(ExtractedEventGuard.sanitizedSourceURL(
            event(sourceUrl: "https://getfeedback.com/r/abc123")).sourceUrl == nil)
    }

    @Test func googleMicrosoftAndSurveyFormsAreNulled() {
        for form in ["https://docs.google.com/forms/d/e/xyz/viewform",
                     "https://forms.gle/abc123",
                     "https://forms.office.com/r/abc",
                     "https://mychoir.typeform.com/to/xyz",
                     "https://www.surveymonkey.com/r/abc",
                     "https://form.jotform.com/12345"] {
            #expect(ExtractedEventGuard.sanitizedSourceURL(event(sourceUrl: form)).sourceUrl == nil,
                    "\(form) is a registration form, not a concert page")
        }
    }

    @Test func aRealConcertOrListingsLinkIsKept() {
        for good in ["https://dciny.org/events/faith-and-freedom/",
                     "https://www.carnegiehall.org/Calendar/2026/11/16/We-Sing-Noel",
                     "https://www.google.com/search?q=concert"] {   // a plain Google host is not a form
            #expect(ExtractedEventGuard.sanitizedSourceURL(event(sourceUrl: good)).sourceUrl == good,
                    "\(good) is a real link and must survive")
        }
    }

    @Test func theShowSurvivesEvenWhenItsLinkIsStripped() {
        let cleaned = ExtractedEventGuard.sanitizedSourceURL(
            event(sourceUrl: "https://getfeedback.com/r/abc"))
        #expect(cleaned.title == "We Sing Noel")
        #expect(cleaned.venue == "Carnegie Hall")
        #expect(ExtractedEventGuard.isUsable(cleaned))   // still a usable, pitchable prospect
    }

    @Test func aBlankOrMissingLinkIsLeftAlone() {
        #expect(ExtractedEventGuard.sanitizedSourceURL(event(sourceUrl: nil)).sourceUrl == nil)
        #expect(ExtractedEventGuard.sanitizedSourceURL(event(sourceUrl: "")).sourceUrl == "")
    }

    @Test func sanitizingIsIdempotent() {
        let once = ExtractedEventGuard.sanitizedSourceURL(
            event(sourceUrl: "https://getfeedback.com/r/abc"))
        #expect(ExtractedEventGuard.sanitizedSourceURL(once).sourceUrl == nil)
    }

    // #1291: a stripped form link falls back to the LISTINGS PAGE the row was read from (runbook 3c), so a
    // kept DCINY /opportunities/ show still has something Dan can open, instead of no link at all.
    @Test func aStrippedFormFallsBackToTheListingsPage() {
        let cleaned = ExtractedEventGuard.sanitizedSourceURL(
            event(sourceUrl: "https://dciny.getfeedback.com/r/abc"),
            listingsURL: "https://www.dciny.org/opportunities/")
        #expect(cleaned.sourceUrl == "https://www.dciny.org/opportunities/")
        #expect(ExtractedEventGuard.isUsable(cleaned))
    }

    // A real concert link is never displaced by the fallback: the fallback only rescues a STRIPPED form.
    @Test func aRealLinkIsNotReplacedByTheListingsFallback() {
        let good = "https://dciny.org/events/faith-and-freedom/"
        #expect(ExtractedEventGuard.sanitizedSourceURL(
            event(sourceUrl: good), listingsURL: "https://www.dciny.org/opportunities/").sourceUrl == good)
    }

    // Defensive: a listings URL is never itself a form, but if a form (or a blank) were handed in as the
    // fallback it must not replace one bad link with another; it drains to nil, exactly as before #1291.
    @Test func aFormOrBlankFallbackStillDrainsToNil() {
        let form = "https://getfeedback.com/r/abc"
        #expect(ExtractedEventGuard.sanitizedSourceURL(
            event(sourceUrl: form), listingsURL: "https://forms.gle/xyz").sourceUrl == nil)
        #expect(ExtractedEventGuard.sanitizedSourceURL(
            event(sourceUrl: form), listingsURL: "   ").sourceUrl == nil)
        #expect(ExtractedEventGuard.sanitizedSourceURL(
            event(sourceUrl: form), listingsURL: nil).sourceUrl == nil)
    }

    // LIVE-STORE-CLAIM verified=2026-07-29 measure="open rows whose presenter is spelled exactly like their own venue"
    // #1766: runbook rule 3d forbids reporting the venue as the presenter, and a real run against the
    // pinned FRIGID page obeyed it. But a runbook is a request, not a guarantee (the same reasoning that
    // put the venue and signup-form guards in this file), and 163 of 512 open rows already carry a
    // presenter spelled exactly like their own venue. A presenter is what the PAID contact hunt is aimed
    // at, so a room's name sitting there sends Dan's money looking for the building's own inbox and the
    // answer comes back reading like an honest "nobody is reachable".
    //
    // Drained to nil rather than dropping the show: the performance is real and Dan should still see it.
    // Nil is also the honest value, because the page did not tell us who presents it.
    @Test func aPresenterThatIsReallyTheVenueIsDrainedRatherThanStored() {
        let e = ExtractedEvent(title: "Italian Abroad", presenter: "Under St Marks",
                               venue: "Under St Marks", performanceDate: "2026-09-11", sourceUrl: nil)
        #expect(ExtractedEventGuard.presenterThatIsNotTheRoom(e).presenter == nil)
    }

    // The same room under a spelling the venue fold already collapses. Compared through ProducerGate.key,
    // the one fold the app already uses for exactly this presenter-versus-venue question, so this guard
    // cannot drift from the producer gate's own idea of when a name IS the room.
    @Test func aPresenterMatchingItsRoomUnderAnotherSpellingIsAlsoDrained() {
        let e = ExtractedEvent(title: "A Recital", presenter: "The Cutting Room",
                               venue: "The Cutting Room, 44 East 32nd Street, New York, NY",
                               performanceDate: "2026-09-11", sourceUrl: nil)
        #expect(ExtractedEventGuard.presenterThatIsNotTheRoom(e).presenter == nil)
    }

    // And a real presenter is untouched, or the guard would erase the very thing #1766 exists to capture.
    @Test func arealPresenterSurvivesTheGuard() {
        let e = ExtractedEvent(title: "Sins and Stardust Burlesque",
                               presenter: "Stiletto Sinclair and Jackie Galaxy", venue: "Under St Marks",
                               performanceDate: "2026-09-28", sourceUrl: nil)
        #expect(ExtractedEventGuard.presenterThatIsNotTheRoom(e).presenter == "Stiletto Sinclair and Jackie Galaxy")
        // Nothing else about the event moves.
        #expect(ExtractedEventGuard.presenterThatIsNotTheRoom(e).venue == "Under St Marks")
    }

    // Idempotent, like the other two drains in this file: running it twice changes nothing.
    @Test func drainingThePresenterTwiceChangesNothing() {
        let e = ExtractedEvent(title: "Italian Abroad", presenter: "Under St Marks",
                               venue: "Under St Marks", performanceDate: "2026-09-11", sourceUrl: nil)
        let once = ExtractedEventGuard.presenterThatIsNotTheRoom(e)
        #expect(ExtractedEventGuard.presenterThatIsNotTheRoom(once) == once)
    }

}
