import Testing
import Foundation
import SwiftData
@testable import Overture

// #799 slice 4a: what happens between Dan pasting a link and Dan seeing something to confirm.
//
// The whole point of routing the intake through a CONFIRM step is that a bad parse gets caught by Dan
// on a sheet, instead of being written into the live store overnight by an unattended run. So the
// states this thing can be in are the feature, and each one has to be honest about what actually
// happened:
//
//   - "I read the page and here is what I found"     -> he confirms, edits, or drops
//   - "That page has no upcoming shows"              -> NOT an error. The #770 spike found this is the
//                                                       normal state for 5 of 7 real org sites in July.
//   - "That doesn't look like an events page"        -> probably the wrong URL (a 2021 archive answers
//                                                       HTTP 200 and looks fine)
//   - "I can't read that page at all"                -> a JavaScript-only calendar, or a login wall.
//                                                       An INSTAGRAM link is exactly this, and Dan said
//                                                       he would sometimes paste one, so it must say
//                                                       what to paste instead rather than sit there.
//   - a named fetch failure                          -> 404, a redirect to a different site, a PDF
//
// Never a spinner that ends in silence, and never an empty list that means four different things.
@MainActor
@Suite("Lead intake (#799)")
struct LeadIntakeTests {
    private func results(verdict: PageVerdict, events: [ScoutExtractEvent], note: String? = nil)
    -> ScoutExtractResults {
        ScoutExtractResults(version: 1, generatedAt: "2026-07-12T00:00:00Z",
                            results: [ScoutExtractResult(sourceId: "lead", verdict: verdict,
                                                         events: events, note: note)])
    }

    private func event(_ title: String, venue: String? = "Merkin Hall",
                       date: String? = "2026-09-19") -> ScoutExtractEvent {
        ScoutExtractEvent(title: title, presenter: title, venue: venue,
                          performanceDate: date, sourceUrl: "https://org.example/\(title)")
    }

    @Test func aReadablePageWithShowsBecomesSomethingToConfirm() {
        let outcome = LeadIntake.outcome(from: results(verdict: .upcomingListings,
                                                       events: [event("Brooklyn Youth Chorus")]),
                                         sourceId: "lead")

        guard case .found(let events, _) = outcome else {
            Issue.record("expected .found, got \(outcome)"); return
        }
        #expect(events.count == 1)
        #expect(events.first?.venue == "Merkin Hall")
    }

    // NOT an error, and this is the single most important thing for Dan to understand: an org between
    // seasons is a HEALTHY source with nothing on. Calling it a failure would train him to distrust a
    // system that is working correctly, and the spike says this is the common case, not the rare one.
    @Test func aPageWhoseShowsHaveAllHappenedIsNotAFailure() {
        let outcome = LeadIntake.outcome(from: results(verdict: .allPast, events: []), sourceId: "lead")

        guard case .noUpcomingShows(let message) = outcome else {
            Issue.record("expected .noUpcomingShows, got \(outcome)"); return
        }
        #expect(message.lowercased().contains("no upcoming"))
        #expect(!message.lowercased().contains("error"))
        #expect(!message.lowercased().contains("fail"))
    }

    // The wrong-page case: musicasacrany.com/concerts answers HTTP 200 and is full of dates, and every
    // one of them is from 2021. Nothing is broken; the URL is simply not the events page.
    @Test func aPageWithNoListingsSaysItIsProbablyTheWrongLink() {
        let outcome = LeadIntake.outcome(from: results(verdict: .noDatedContent, events: []),
                                         sourceId: "lead")

        guard case .notAnEventsPage(let message) = outcome else {
            Issue.record("expected .notAnEventsPage, got \(outcome)"); return
        }
        #expect(message.lowercased().contains("events page") || message.lowercased().contains("listings"))
    }

    // Dan's decision, and the reason it is not hypothetical: he said he would sometimes paste an
    // Instagram link, and a raw fetch of one returns ~600KB of LOGIN WALL with no caption and no event
    // data at all. It must say what to paste INSTEAD, not fail silently and not pretend to have read it.
    @Test func anUnreadablePageTellsDanWhatToPasteInstead() {
        let outcome = LeadIntake.outcome(from: results(verdict: .unreadable, events: []), sourceId: "lead")

        guard case .unreadable(let message) = outcome else {
            Issue.record("expected .unreadable, got \(outcome)"); return
        }
        // Honest about whose fault it is (ours, not the page's) and useful about where to go next.
        #expect(message.lowercased().contains("venue") || message.lowercased().contains("ticket"))
        #expect(message.lowercased().contains("can't read"))
        // It must NOT tell him to paste "the org's own site": on the real case that triggered this
        // (his ensemble's Wix site), that is precisely what he had just pasted.
        #expect(!message.lowercased().contains("the org's own site"))
    }

    @Test func anInstagramLinkIsRecognizedBeforeWeEvenFetchIt() {
        // Cheap and honest: we know how this ends, so say so immediately rather than spending a fetch
        // and a Claude run to discover a login wall.
        #expect(LeadIntake.knownUnreadableHost(URL(string: "https://www.instagram.com/p/abc123/")!) != nil)
        #expect(LeadIntake.knownUnreadableHost(URL(string: "https://instagram.com/someband")!) != nil)
        #expect(LeadIntake.knownUnreadableHost(URL(string: "https://bargemusic.org/calendar")!) == nil)
    }

    // A page whose shows all lack a venue is NOT "no shows". It is a source whose detail pages are not
    // being read (the Bargemusic shape: numeric venue ids). Saying "no upcoming shows" there would be a
    // lie that hides a real, fixable problem.
    @Test func showsThatAllLackAVenueReadAsAProblemNotAsAnEmptyPage() {
        let outcome = LeadIntake.outcome(
            from: results(verdict: .upcomingListings,
                          events: [event("A", venue: nil), event("B", venue: "3")]),
            sourceId: "lead")

        guard case .foundButUnusable(let rejected, _) = outcome else {
            Issue.record("expected .foundButUnusable, got \(outcome)"); return
        }
        #expect(rejected.count == 2)
    }

    // A results file that came back for a DIFFERENT source id than we queued (a run that rebuilt the
    // key instead of echoing it) must read as "nothing came back", never as somebody else's shows.
    @Test func resultsForAnotherSourceAreNotMistakenForOurs() {
        let outcome = LeadIntake.outcome(from: results(verdict: .upcomingListings,
                                                       events: [event("Someone Else's Show")]),
                                         sourceId: "a-different-lead")

        guard case .nothingCameBack = outcome else {
            Issue.record("expected .nothingCameBack, got \(outcome)"); return
        }
    }

    // The confirmed shows go in through the EXISTING classify/assemble/upsert chain, never a hand-built
    // insert. That is what keeps blocked dates, the #769 do-not-contact suppression, the #798
    // upcoming-only guard and the #797 run identity all applying to a hand-added lead exactly as they
    // do to a scouted one. One pipeline, not two.
    @Test func confirmedShowsEnterThroughTheNormalPipeline() throws {
        let ctx = ModelContext(try ModelContainer(
            for: Schema([Prospect.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))

        let outcome = ScoutService.apply(
            events: [ExtractedEvent(title: "Brooklyn Youth Chorus", presenter: "Brooklyn Youth Chorus",
                                    venue: "Merkin Hall", performanceDate: "2026-09-19",
                                    sourceUrl: "https://org.example/a")],
            clients: [], history: [], blocked: .empty,
            today: ScoutTestClock.beforeAllFixtures, into: ctx)

        #expect(outcome.inserted == 1)
        let stored = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(stored.first?.tier != nil)          // ranked, like anything else
        #expect(stored.first?.venue == "Merkin Hall")
    }

    // A do-not-contact org must not be importable by hand either. The suppression already lives in the
    // pipeline, which is exactly why the intake goes THROUGH the pipeline: a hand-built insert would
    // have quietly bypassed the one rule that cannot be taken back.
    @Test func aHandAddedLeadCannotSmuggleInARefusedOrg() throws {
        let ctx = ModelContext(try ModelContainer(
            for: Schema([Prospect.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
        let dnc = [HistoryRecord(groupName: "Brooklyn Youth Chorus", status: "dnc")]

        let outcome = ScoutService.apply(
            events: [ExtractedEvent(title: "Brooklyn Youth Chorus", presenter: "Brooklyn Youth Chorus",
                                    venue: "Merkin Hall", performanceDate: "2026-09-19",
                                    sourceUrl: "https://org.example/a")],
            clients: [], history: dnc, blocked: .empty,
            today: ScoutTestClock.beforeAllFixtures, into: ctx)

        #expect(outcome.inserted == 0)
        #expect(outcome.skipped == 1)
        #expect(try ctx.fetch(FetchDescriptor<Prospect>()).isEmpty)
    }
}
