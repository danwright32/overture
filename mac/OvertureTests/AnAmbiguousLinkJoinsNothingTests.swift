import Testing
import Foundation
import SwiftData

// #4098: the two URL arms could not see how ambiguous the URL they matched on actually was.
//
// `matchByProductionToken` has had this discard since #4029: a token appearing under more than one show
// at a venue joins nothing, because a venue stamping one id across its season would otherwise fuse the
// season into a single card. The URL arms had no equivalent, and #4032 is what that costs: on a single
// venue's season page every show shares one URL and one room, so `matchByStableSource`'s venue test
// removes nothing and the arm renamed a dismissed row onto a different show.
//
// WHAT AMBIGUOUS MEANS HERE, and it is the one thing the issue left open that had to be decided rather
// than assumed. Counting TITLE SPELLINGS at a URL is the obvious rule and it is wrong: two rows that are
// a duplicate of one show carry that URL under two spellings, so the count would mark a URL ambiguous
// because of the pair the arm exists to join. #4129's Carnegie pair is exactly that. So the titles at a
// URL are folded into SHOWS first, by the same predicate the arms use, and a URL is ambiguous only when
// two different shows remain.
@MainActor
@Suite("An ambiguous link joins nothing loosely (#4098)")
struct AnAmbiguousLinkJoinsNothingTests {

    private static let season = "https://www.theplayerstheatre.com/show-schedule.html"
    private static let venue = "The Players Theatre"

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self, DayOff.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func stored(_ ctx: ModelContext, _ title: String, night: String,
                        url: String = season, venue: String = venue,
                        runURLs: [String]? = nil) -> Prospect {
        let p = Prospect(naturalKey: Prospect.makeNaturalKey(groupName: title, performanceDate: night,
                                                            venue: venue),
                         groupName: title, discipline: "theater", venue: venue,
                         performanceDate: night, sourceListingURL: url, priorRelationship: "none",
                         production: "unknown", profile: "unknown", coverage: "unknown", fitScore: 3,
                         tier: "medium", fitReason: "", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, runEndDate: nil,
                         partOfRelatedRun: false, runSourceURLs: runURLs ?? [url],
                         runNights: [night])
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    // THE RULE, asked of the pure function first, because every claim below rests on what it calls
    // ambiguous.
    @Test func aPageCarryingTwoDIFFERENTShowsIsAmbiguousAndOneCarryingTwoBillingsIsNot() {
        let twoShows = [(url: "p", title: "Back to Shakespeare", venue: "the players theatre"),
                        (url: "p", title: "Marlise (A New Golden Age Musical)", venue: "the players theatre")]
        #expect(ShowLink.ambiguousURLs(twoShows, scopedByVenue: true) == ["p"])

        // #4129's live pair: one concert, two billings, one listing page. Counting spellings would call
        // this ambiguous and refuse the very join the arm exists for.
        let twoBillings = [
            (url: "c", title: "Ilya Kaler, Violin Rasa Vitkauskaite, Piano With special guests "
                + "Paquito D'Rivera, Jonathan Cohler, Dave Eggar, and Gregg August",
             venue: "weill recital hall"),
            (url: "c", title: "Ilya Kaler, Violin Rasa Vitkauskaite, Piano With special guests "
                + "Paquito D'Rivera, Jonathan Cohler, Dave Eggar, Gregg August, Makeda Hampton, "
                + "and Mak Grgic", venue: "weill recital hall"),
        ]
        #expect(ShowLink.ambiguousURLs(twoBillings, scopedByVenue: true).isEmpty,
                "two billings of one concert are one show, so their shared page is not ambiguous")
    }

    // THE TWO SCOPES, which are different questions and are kept apart deliberately. An organisation
    // level page spanning two rooms is ambiguous for the arm with no venue test and is NOT ambiguous for
    // the arm that demands the venue agrees, because at each venue it carries one show.
    @Test func aPageSpanningTwoRoomsIsAmbiguousOnlyWhereTheVenueIsNotAsked() {
        let acrossRooms = [(url: "org", title: "La bohème", venue: "the met"),
                           (url: "org", title: "Lincoln in the Bardo", venue: "lincoln center")]
        #expect(ShowLink.ambiguousURLs(acrossRooms, scopedByVenue: false) == ["org"])
        #expect(ShowLink.ambiguousURLs(acrossRooms, scopedByVenue: true).isEmpty,
                "each room carries one show, so the arm that demands the venue has no ambiguity to see")
    }

    // THE INGEST, driven through the real `ScoutService.apply`. A season page holding one show, where a
    // second show arrives for a night the first does not hold: the arms must not join them, and this is
    // the shape #4032 reproduced.
    @Test func asecondShowOnASeasonPageDoesNotTakeOverTheFirst() throws {
        let ctx = try context()
        let first = stored(ctx, "Marlise (A New Golden Age Musical)", night: "2026-09-04")
        first.statusRaw = ReviewStatus.dismissed.rawValue
        let firstKey = first.naturalKey
        try ctx.save()

        let incoming = ExtractedEvent(title: "Back to Shakespeare", presenter: "The Players Theatre",
                                      venue: Self.venue, performanceDate: "2026-09-05",
                                      sourceUrl: Self.season)
        _ = ScoutService.apply(events: [incoming], clients: [], history: [], blocked: .empty,
                               today: "2026-08-20", sourceIds: ["theplayerstheatre-com"], into: ctx)
        try ctx.save()

        let rows = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(rows.count == 2, "two different shows on one page are two shows: \(rows.map(\.groupName))")
        #expect(rows.contains { $0.naturalKey == firstKey },
                "the stored row must still hold its own key: \(rows.map(\.naturalKey).sorted())")
    }

    // THE DISCRIMINATING PAIR, one per arm, and they are here because the ingest test above does NOT
    // discriminate: "Back to Shakespeare" and "Marlise (A New Golden Age Musical)" fail every title test
    // there is, so both arms refuse them with or without this change and a mutation removing either
    // discard SURVIVED that test (L159). What reaches an arm is a title the loose test ACCEPTS and the
    // strict one does not, which is a long subtitle: `isSubtitleExtension` takes any prefix, while
    // `isConfident` needs 0.6 of the longer title, so three shared words out of eight is the gap.
    //
    // A SEASON PAGE CARRYING TWO SHOWS, and a subtitle arriving on a night the stored row does not hold.
    // `matchByStableSource` cannot fire (it demands the same date), so this is `matchByAnyRunURL`, the
    // arm with no venue test at all.
    @Test func alongSubtitleOnAnAmbiguousPageDoesNotRekeyTheRunItSharesAURLWith() throws {
        let ctx = try context()
        let first = stored(ctx, "Back to Shakespeare", night: "2026-09-04")
        let firstKey = first.naturalKey
        stored(ctx, "Marlise (A New Golden Age Musical)", night: "2026-09-06")

        // The loose test accepts this pair and the strict one refuses it, which is what makes the
        // assertion below about the discard rather than about the titles (L159). `isConfident` is NOT
        // the strict test and this records why: it strips a trailing subtitle after a colon, so it
        // ACCEPTS this pair, and the first draft of this branch used it.
        #expect(GroupNameMatch.isSameShowTitle("Back to Shakespeare",
                                               "Back to Shakespeare: An Evening of Sonnets and Songs"))
        #expect(GroupNameMatch.isConfident("Back to Shakespeare",
                                           "Back to Shakespeare: An Evening of Sonnets and Songs"),
                "if this ever goes red, the subtitle strip changed and the fallback below can be revisited")
        #expect(ShowLink.foldedTitle("Back to Shakespeare")
                != ShowLink.foldedTitle("Back to Shakespeare: An Evening of Sonnets and Songs"),
                "the key's own fold is what separates them, which is why the arms fall back to it")

        let incoming = ExtractedEvent(title: "Back to Shakespeare: An Evening of Sonnets and Songs",
                                      presenter: "The Players Theatre", venue: Self.venue,
                                      performanceDate: "2026-09-05", sourceUrl: Self.season)
        _ = ScoutService.apply(events: [incoming], clients: [], history: [], blocked: .empty,
                               today: "2026-08-20", sourceIds: ["theplayerstheatre-com"], into: ctx)
        try ctx.save()

        let rows = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(rows.count == 3, "the run URL arm joined on a page carrying two shows: \(rows.map(\.groupName))")
        #expect(rows.contains { $0.naturalKey == firstKey },
                "the stored row was re-keyed onto the arriving night: \(rows.map(\.naturalKey).sorted())")
    }

    // THE OTHER ARM, on the same page and the SAME night, with no run URLs stored so the arm above
    // cannot answer: this is `matchByStableSource`, which demands the listing URL, the date and the
    // venue, and on a single venue's season page the venue removes nothing because every candidate
    // shares it. That is #4032, reproduced.
    @Test func alongSubtitleOnTheSameNightDoesNotRenameTheStoredShow() throws {
        let ctx = try context()
        let first = stored(ctx, "Back to Shakespeare", night: "2026-09-04", runURLs: [])
        first.statusRaw = ReviewStatus.dismissed.rawValue
        let firstKey = first.naturalKey
        stored(ctx, "Marlise (A New Golden Age Musical)", night: "2026-09-06", runURLs: [])
        try ctx.save()

        let incoming = ExtractedEvent(title: "Back to Shakespeare: An Evening of Sonnets and Songs",
                                      presenter: "The Players Theatre", venue: Self.venue,
                                      performanceDate: "2026-09-04", sourceUrl: Self.season)
        _ = ScoutService.apply(events: [incoming], clients: [], history: [], blocked: .empty,
                               today: "2026-08-20", sourceIds: ["theplayerstheatre-com"], into: ctx)
        try ctx.save()

        let rows = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(rows.count == 3,
                "the listing URL arm renamed a dismissed row onto another show: \(rows.map(\.groupName))")
        #expect(rows.first { $0.naturalKey == firstKey }?.groupName == "Back to Shakespeare",
                "the dismissed row kept its key and its name: \(rows.map(\.groupName).sorted())")
    }

    // WHAT MUST NOT BREAK. A page carrying ONE show still joins a drifted title, which is the whole
    // purpose of both arms (#29, #132). The discard only reaches a page carrying two.
    @Test func adriftedTitleOnAPageCarryingOneShowIsStillRecognised() throws {
        let ctx = try context()
        let url = "https://thecuttingroomnyc.com/events/blues-for-greeny"
        stored(ctx, "Blues For Greeny", night: "2026-11-14", url: url, venue: "The Cutting Room")
        let incoming = ExtractedEvent(title: "Blues For Greeny (The Music of Peter Green)",
                                      presenter: "The Cutting Room", venue: "The Cutting Room",
                                      performanceDate: "2026-11-14", sourceUrl: url)
        _ = ScoutService.apply(events: [incoming], clients: [], history: [], blocked: .empty,
                               today: "2026-09-19", sourceIds: ["thecuttingroomnyc-com"], into: ctx)
        try ctx.save()

        let rows = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(rows.count == 1,
                "a subtitle added on a page carrying one show is still one show: \(rows.map(\.groupName))")
    }

    // AN UNREADABLE STORE refuses every URL rather than none, which is the same direction the token
    // discard takes and the opposite of what an empty set would mean (L42, L215).
    @Test func anUnreadableStoreMakesEveryURLAmbiguous() {
        struct StoreIsDown: Error {}
        let incoming = [AssembledProspect(groupName: "A", presenter: nil, location: nil,
                                          discipline: "music", venue: "V",
                                          performanceDate: "2026-10-01",
                                          sourceListingURL: "https://example.org/x", reachable: true,
                                          priorRelationship: "none", production: "unknown",
                                          profile: "unknown", coverage: "unknown", fitScore: 3,
                                          tier: "medium", fitReason: "", matchedClientName: nil,
                                          possibleMatchSource: nil, possibleMatchName: nil)]
        #expect(throws: StoreIsDown.self) {
            _ = try ScoutService.ambiguousURLsForBatch(incoming, storedRows: { throw StoreIsDown() })
        }
    }
}
