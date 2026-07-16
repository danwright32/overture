import Testing
import Foundation
@testable import Overture

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

    @Test func anEventWithNoTitleIsRejected() {
        #expect(ExtractedEventGuard.rejection(for: event(title: "", venue: "Merkin Hall")) == .noTitle)
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

    private func event(_ title: String, venue: String?, location: String? = nil) -> ScoutExtractEvent {
        ScoutExtractEvent(title: title, presenter: title, venue: venue,
                          performanceDate: "2026-09-19", sourceUrl: "https://org.example/\(title)",
                          location: location)
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

    @Test func aSourceWhoseEventsAreAllVenuelessIsVisiblyBrokenRatherThanEmpty() {
        let r = results([event("A", venue: nil), event("B", venue: "7")])

        #expect(r.events(for: "s").isEmpty)                 // nothing usable...
        #expect(r.rejectedEvents(for: "s").count == 2)      // ...but NOT because the page was empty
        #expect(r.verdict(for: "s") == .upcomingListings)   // the page HAD shows; we just can't use them
    }
}
