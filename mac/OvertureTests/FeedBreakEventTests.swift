import Testing
import Foundation
import SwiftData

// #4027 and #3383 are one question asked twice: a row whose `missedScoutCount` climbs is indistinguishable
// from a cancelled show, and the longer it climbs the more convincing the wrong answer looks.
//
// The discriminator is not the SIZE of the count, which both issues originally proposed and which the data
// refuses. It is that several rows at one venue share an IDENTICAL count: a source that re-keyed its
// calendar broke every row it was publishing in ONE sweep, so they all start missing together and stay
// exactly level for ever after. A genuine departure happens to one show at a time.
//
// Measured on the live store 2026-09-20, which is what makes it a discriminator rather than a hope:
//
//   The Players Theatre  8 rows, ALL at 33     <- the 2026-08-09 re-key, #3278's incident
//   Zankel Hall          3 rows at 72, 58, 57  <- three separate departures, three different counts
//
@Suite("A sweep that broke a whole source is not a cancellation (#4027, #3383)")
@MainActor
struct FeedBreakEventTests {

    private func container() throws -> ModelContainer {
        let schema = Schema([Prospect.self, Recipient.self])
        return try ModelContainer(for: schema,
                                  configurations: [ModelConfiguration(schema: schema,
                                                                      isStoredInMemoryOnly: true)])
    }

    @discardableResult
    private func row(_ ctx: ModelContext, _ title: String, venue: String, opens: String,
                     runEnd: String? = nil, missed: Int) -> Prospect {
        let p = Prospect(naturalKey: "\(title.lowercased())|\(opens)|\(venue.lowercased())",
                         groupName: title, discipline: "theater", venue: venue,
                         performanceDate: opens, sourceListingURL: nil,
                         priorRelationship: "none", production: "unknown", profile: "unknown",
                         coverage: "unknown", fitScore: 3, tier: "medium", fitReason: "",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         runEndDate: runEnd, partOfRelatedRun: runEnd != nil,
                         runSourceURLs: [], runNights: [opens])
        p.missedScoutCount = missed
        ctx.insert(p)
        return p
    }

    private let asOf = "2026-09-20"

    // THE CLAIM. Eight rows at one venue, all on the same count, are one event and are named as one.
    @Test func rowsAtOneVenueSharingAMissCountAreOneEvent() throws {
        let ctx = ModelContext(try container())
        for (i, title) in ["We Are Happy to Serve You", "Space Quest", "Alice in Wonderland",
                           "Day of the Hog"].enumerated() {
            row(ctx, title, venue: "The Players Theatre", opens: "2026-1\(i)-07", missed: 33)
        }
        let events = FeedBreakEvent.events(among: try ctx.fetch(FetchDescriptor<Prospect>()), asOf: asOf)
        #expect(events.count == 1, "expected one event, got \(events.count)")
        let event = try #require(events.first)
        #expect(event.missedScoutCount == 33)
        #expect(event.memberKeys.count == 4, "every row on that count belongs to the event")
        #expect(event.venue == "The Players Theatre")
    }

    // The counter-example that makes the rule a discriminator rather than a description. Zankel Hall's
    // three flagged rows carry three different counts, so they are three departures and no event.
    @Test func rowsAtDifferentCountsAreNotOneEvent() throws {
        let ctx = ModelContext(try container())
        row(ctx, "China Now Chamber Orchestra", venue: "Zankel Hall", opens: "2026-10-02", missed: 72)
        row(ctx, "Deborah Silver with Friends", venue: "Zankel Hall", opens: "2026-10-11", missed: 58)
        row(ctx, "Fang Tao Jiang, Soprano", venue: "Zankel Hall", opens: "2026-10-17", missed: 57)
        let events = FeedBreakEvent.events(among: try ctx.fetch(FetchDescriptor<Prospect>()), asOf: asOf)
        #expect(events.isEmpty, "three different counts are three departures, got \(events.count) event(s)")
    }

    // TWO rows sharing a count is arithmetic, not evidence, and the floor is what says so. Measured on
    // the live store 2026-09-20: four venues hold exactly such a pair (The Green Room 42 at 11, Roulette
    // at 3, The Cutting Room at 2, and one more), and not one of them is a re-key. Without the floor each
    // would be reported as a broken source beside the one real event, and a report that names correct
    // pairs as faults is one Dan stops reading (L93, L36).
    @Test func twoRowsSharingACountAreNotYetAnEvent() throws {
        let ctx = ModelContext(try container())
        row(ctx, "Josie De Guzman", venue: "The Green Room 42", opens: "2026-10-23", missed: 11)
        row(ctx, "What If...", venue: "The Green Room 42", opens: "2026-11-10", missed: 11)
        #expect(FeedBreakEvent.events(among: try ctx.fetch(FetchDescriptor<Prospect>()), asOf: asOf).isEmpty,
                "a pair is below the floor, so it must not be reported as a source breaking")
    }

    // A count BELOW the threshold that already decides whether a row is flagged at all is not an event,
    // however many rows share it. Most of the store sits at 0 and 1, so without this every ordinary
    // sweep would read as a source breaking (L139: a floor is what stops a rate being noise).
    @Test func rowsBelowTheGoneThresholdAreNeverAnEvent() throws {
        let ctx = ModelContext(try container())
        for i in 0..<6 { row(ctx, "Show \(i)", venue: "The Cutting Room", opens: "2026-10-0\(i+1)", missed: 1) }
        #expect(FeedBreakEvent.events(among: try ctx.fetch(FetchDescriptor<Prospect>()), asOf: asOf).isEmpty,
                "rows the app does not even flag cannot be evidence that a source broke")
    }

    // A show that has already played is not something Dan can act on, and the whole point of naming an
    // event is the work it is still costing. The orphans measured on the live store run to June 2027.
    @Test func aPastShowIsNotCountedIntoAnEvent() throws {
        let ctx = ModelContext(try container())
        row(ctx, "Played Already", venue: "The Players Theatre", opens: "2026-08-01", missed: 33)
        row(ctx, "Played Too", venue: "The Players Theatre", opens: "2026-08-02", missed: 33)
        row(ctx, "Still To Come", venue: "The Players Theatre", opens: "2026-12-20", missed: 33)
        #expect(FeedBreakEvent.events(among: try ctx.fetch(FetchDescriptor<Prospect>()), asOf: asOf).isEmpty,
                "one future row is not an event; the two past ones must not make it one")
    }

    // The half that says what the event MEANS, and the half #4027 is actually about: a member with a live
    // twin is a row the source re-keyed, not a show that stopped. Reuses `ContradictedCancellation`, which
    // already answers this with the app's own three tests, rather than matching again here (L370).
    @Test func anEventSaysHowManyOfItsRowsAnotherCardAlreadyCovers() throws {
        let ctx = ModelContext(try container())
        row(ctx, "We Are Happy to Serve You", venue: "The Players Theatre", opens: "2026-12-20", missed: 33)
        row(ctx, "Space Quest", venue: "The Players Theatre", opens: "2027-02-04", missed: 33)
        row(ctx, "Day of the Hog", venue: "The Players Theatre", opens: "2026-09-27", missed: 33)
        // The twin the source now publishes: same show, same room, overlapping run, still being listed.
        // It is NOT a member: a row the feed still lists has missed nothing.
        row(ctx, "We Are Happy to Serve You", venue: "The Players Theatre", opens: "2026-12-03",
            runEnd: "2026-12-20", missed: 0)
        let events = FeedBreakEvent.events(among: try ctx.fetch(FetchDescriptor<Prospect>()), asOf: asOf)
        let event = try #require(events.first)
        #expect(event.memberKeys.count == 3)
        #expect(event.coveredByAnotherCard == 1,
                "exactly one member has a live twin, got \(event.coveredByAnotherCard)")
    }

    // The notice, which is the only part of this Dan sees.

    private let event = FeedBreakEvent.Event(venue: "The Players Theatre", missedScoutCount: 33,
                                             memberKeys: ["queued", "archived", "also queued"],
                                             coveredByAnotherCard: 7)

    @Test func theControlOffersOnlyTheRowsTheQueueWillActuallyShow() throws {
        let notices = AppNotices.feedBreaks([event], shownInQueue: { $0 != "archived" })
        let notice = try #require(notices.first)
        #expect(notice.tone == .warning)
        #expect(notice.action == .showShowsOneSweepBroke(keys: ["queued", "also queued"]),
                "the dismissed row opens in the Archive, so naming it here is a control that does nothing")
    }

    // A control that cannot do its job is worse than none at all, which is the rule `AppNotices.servable`
    // already applies to the shortfall report. The SENTENCE stays: what happened is still true (L44).
    @Test func anEventWhoseRowsAreAllInTheArchiveCarriesNoControl() throws {
        let notices = AppNotices.feedBreaks([event], shownInQueue: { _ in false })
        let notice = try #require(notices.first)
        #expect(notice.action == nil, "offered to show rows the queue will not render")
        #expect(notice.text == event.sentence, "the sentence must survive losing the control")
    }

    @Test func aStoreWithNoBrokenSourceAddsNoLinesAtAll() throws {
        #expect(AppNotices.feedBreaks([], shownInQueue: { _ in true }).isEmpty,
                "a quiet app must add no rows to the masthead")
    }

    // The sentence Dan reads. Written as a test because it is the only thing this ships that he sees, and
    // because a count in prose is the part that goes stale silently.
    @Test func theNoticeNamesTheVenueTheCountAndWhatIsAlreadyCovered() throws {
        let event = FeedBreakEvent.Event(venue: "The Players Theatre", missedScoutCount: 33,
                                   memberKeys: ["a", "b", "c"], coveredByAnotherCard: 2)
        #expect(event.sentence == "3 shows at The Players Theatre dropped out of its listings on the "
                + "same day, which is one change at the venue rather than 3 cancellations. "
                + "2 of them are already on another card.")
    }

    @Test func theNoticeSaysNothingAboutCoverWhenNoneOfThemAreCovered() throws {
        let event = FeedBreakEvent.Event(venue: "The Green Room 42", missedScoutCount: 11,
                                   memberKeys: ["a", "b"], coveredByAnotherCard: 0)
        #expect(event.sentence == "2 shows at The Green Room 42 dropped out of its listings on the "
                + "same day, which is one change at the venue rather than 2 cancellations.")
    }
}
