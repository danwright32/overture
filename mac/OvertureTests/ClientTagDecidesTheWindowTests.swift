import Testing
import Foundation
import SwiftData

// #2523: the returning-client tag has never once decided anything.
//
// `WatchedSource.clientTagOverride` lets Dan mark a source "this is a returning client's" or "never one",
// and it beats the automatic Downbeat name match in both directions. Measured on the live store
// 2026-08-11: 0 of 73 sources carry it. So every question has been answered by the name match, and a
// control with zero live uses is indistinguishable from a broken one (L1).
//
// It mattered less when the tag only widened how many months of a calendar were FETCHED. Since #2365 it
// also decides how far ahead those shows are offered for TRIAGE, 12 months rather than 90 days, so a tag
// that silently does not work costs Dan exactly the shows he most wants to see, and one that wrongly
// fires puts a stranger's year-out dates in his Scout list.
//
// `ClientHorizonTests` already covers the override where it is decided. What had never been exercised is
// the CHAIN from the tag to the thing that costs him: tag -> isClient -> clientSourceIds -> ClientWindow
// -> isPastClientShow -> the stage's lead-time window. Every link was tested; the wire was not (L3).
@MainActor
@Suite("Dan's client tag decides the triage window (#2523)")
struct ClientTagDecidesTheWindowTests {

    private let today = "2026-08-16"
    // Nine months out: past the ordinary 90 day edge, inside the client window. The gap this is about.
    private let farOutDate = "2027-05-12"

    private func client(_ name: String) -> DownbeatClient {
        DownbeatClient(id: name, displayName: name, shortName: nil, email: "", contractEmail: "",
                       phoneNumber: nil, isTaxExempt: nil, hasLeftReview: false, specialBehaviors: [],
                       notes: nil, hostingSite: "")
    }

    private func context(_ window: ClientWindow) -> StageContext {
        StageContext(geo: .none, clients: window, today: today)
    }

    private func offeredForTriage(_ p: Prospect, in window: ClientWindow) -> Bool {
        StageNavigation.naturalKeys(for: .scout, in: [p], context: context(window)).contains(p.naturalKey)
    }

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, WatchedSource.self, Inquiry.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func source(_ ctx: ModelContext, id: String, org: String, tag: Bool?) -> WatchedSource {
        let s = WatchedSource(sourceId: id, orgName: org, listingsURL: "https://\(id).example", kind: .html)
        s.clientTagOverride = tag
        ctx.insert(s)
        return s
    }

    private func show(_ ctx: ModelContext, on sourceId: String, date: String) -> Prospect {
        let p = Prospect(naturalKey: "k-\(sourceId)", groupName: "A Stranger Ensemble", discipline: "music",
                         venue: "Merkin Hall", performanceDate: date, sourceListingURL: nil, priorRelationship: "none", production: "self",
                         profile: "strong", coverage: "likely_uncovered", fitScore: 7, tier: "high",
                         fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil)
        p.sourceIds = [sourceId]
        ctx.insert(p)
        return p
    }

    // MARK: the tag ON, with nothing else saying client

    // The direction Dan reaches for the tag: a calendar he KNOWS is a returning client's, whose org name
    // the automatic match does not recognise. Without the tag working, its year-out dates are fetched,
    // stored, and then declined for triage for nine months.
    @Test("a tagged source's far-out show is offered for triage, with no name match anywhere")
    func theTagAloneOpensTheWindow() throws {
        let ctx = ModelContext(try container())
        let s = source(ctx, id: "tagged", org: "Nothing Like A Client Name", tag: true)
        let p = show(ctx, on: "tagged", date: farOutDate)

        // No clients at all, so nothing but the tag can be deciding this.
        let window = ClientWindow(sources: [s], clients: [])
        #expect(window.isPastClientShow(p), "the tag did not reach the window")

        #expect(offeredForTriage(p, in: window),
                "the show is inside the client window and must be offered for triage")
    }

    // And the same show on an untagged source is NOT, which is what makes the assertion above mean
    // something: without this, a window that admitted everything would pass it (L104).
    @Test("the same show on an untagged source stays outside the window")
    func withoutTheTagItIsOutside() throws {
        let ctx = ModelContext(try container())
        let s = source(ctx, id: "untagged", org: "Nothing Like A Client Name", tag: nil)
        let p = show(ctx, on: "untagged", date: farOutDate)

        let window = ClientWindow(sources: [s], clients: [])
        #expect(!window.isPastClientShow(p))

        #expect(!offeredForTriage(p, in: window),
                "a stranger's show nine months out must stay out of Scout")
    }

    // MARK: the tag OFF, beating a name match

    // The other direction, and the one that puts a stranger's year-out dates in front of Dan if it fails:
    // a source whose org name the automatic match DOES recognise, which he has told Overture is not a
    // client's calendar.
    @Test("a source tagged off is not a client, even when the name matches a real one")
    func theTagOffBeatsTheNameMatch() throws {
        let ctx = ModelContext(try container())
        let s = source(ctx, id: "named", org: "Aurora Strings", tag: false)
        let p = show(ctx, on: "named", date: farOutDate)
        let clients = [client("Aurora Strings")]

        // The name match alone would say yes, which is what makes this a real override rather than an
        // agreement: asserted first, so the test cannot pass because the match happened to miss.
        #expect(ClientHorizon.matchesClientName(s.orgName, clients: clients),
                "the fixture no longer matches by name, so this proves nothing about the override")

        let window = ClientWindow(sources: [s], clients: clients)
        #expect(!window.isPastClientShow(p), "Dan's tag must beat the automatic match")

        #expect(!offeredForTriage(p, in: window))
    }

    // And the same source untagged IS a client, so the assertion above is about the tag rather than about
    // the match being broken.
    @Test("the same source untagged is a client by name")
    func untaggedTheNameMatchStillDecides() throws {
        let ctx = ModelContext(try container())
        let s = source(ctx, id: "named", org: "Aurora Strings", tag: nil)
        let p = show(ctx, on: "named", date: farOutDate)
        let clients = [client("Aurora Strings")]

        #expect(ClientWindow(sources: [s], clients: clients).isPastClientShow(p))
    }

    // MARK: the horizon half, at the other end of the same tag

    // The tag decides two things and they must not disagree: how far the calendar is READ, and how far its
    // shows are OFFERED. A tag that opened the window without widening the fetch would offer shows nothing
    // had gone to look for.
    @Test("the tag moves the read horizon and the triage window together")
    func bothEndsAgree() throws {
        let ctx = ModelContext(try container())
        let tagged = source(ctx, id: "tagged", org: "Nothing Like A Client Name", tag: true)
        let untagged = source(ctx, id: "untagged", org: "Nothing Like A Client Name", tag: nil)

        #expect(ClientHorizon.months(for: tagged, clients: []) == ClientHorizon.clientMonths)
        #expect(ClientHorizon.months(for: untagged, clients: []) == CalendarMonthIndex.defaultHorizon)
        #expect(ClientHorizon.clientSourceIds(sources: [tagged, untagged], clients: []) == ["tagged"])
    }
}
