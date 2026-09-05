import Testing
import Foundation
import SwiftData

// #2365: Scout is the ONLY surface that applies a lead time window, and it applies two.
//
// Dan's rule, 2026-08-11, in his words: "90 days for anything that isn't a past client. and then the
// extended check for past clients. we should show everything in scout from those two groups, don't hide
// anything." And, on the other end: "Scout should be solely responsible for filtering out based on how
// far away it is. If it gets to prep I want to be able to prep it."
//
// The measurement that decided the client rule is recorded in `ClientWindow`; the numbers are not
// asserted here, because a census pinned in a test goes stale while reading as protection (L63). What is
// asserted is the INVARIANT: which window each show is judged by, and that nothing else judges at all.
@Suite("Scout applies both lead time windows and nothing else applies one (#2365)")
struct ClientLeadTimeWindowTests {

    static let today = "2026-08-11"

    static func container() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Prospect.self, WatchedSource.self,
                                        configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
    }

    @discardableResult
    static func show(_ ctx: ModelContext, key: String, date: String,
                     matchedClientName: String? = nil, priorRelationship: String? = nil,
                     sourceIds: [String] = []) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: key, discipline: "music", venue: "Merkin Hall",
                         performanceDate: date, sourceListingURL: nil,
                         priorRelationship: priorRelationship ?? "none", production: "self",
                         profile: "strong", coverage: "likely_uncovered", fitScore: 5, tier: "mid",
                         fitReason: "r", matchedClientName: matchedClientName,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .new)
        p.sourceIds = sourceIds
        ctx.insert(p)
        return p
    }

    static func scoutKeys(_ ctx: ModelContext, clients: ClientWindow) throws -> Set<String> {
        let all = try ctx.fetch(FetchDescriptor<Prospect>())
        return Set(StageNavigation.naturalKeys(for: .scout, in: all,
                                               context: .at(today, geo: .none, clients: clients)))
    }

    // MARK: - The ordinary window

    @Test("a show that is not a past client's is offered inside 90 days and held beyond it")
    func theOrdinaryWindow() throws {
        let ctx = try Self.container()
        Self.show(ctx, key: "near", date: "2026-10-01")     // 51 days out
        Self.show(ctx, key: "edge", date: "2026-11-09")     // exactly 90 days out
        Self.show(ctx, key: "far", date: "2026-11-10")      // 91 days out
        let keys = try Self.scoutKeys(ctx, clients: .none)
        #expect(keys.contains("near"))
        #expect(keys.contains("edge"))
        #expect(!keys.contains("far"))
    }

    // MARK: - The client window, by each route on its own

    // The route that catches a client playing a room Dan watches: nothing about the CALENDAR says client,
    // but the show itself resolved to one.
    @Test("a show that matched a client by name is offered far beyond the ordinary window")
    func theShowRoute() throws {
        let ctx = try Self.container()
        Self.show(ctx, key: "client", date: "2027-06-13", matchedClientName: "The Dessoff Choirs")
        Self.show(ctx, key: "stranger", date: "2027-06-13")
        let keys = try Self.scoutKeys(ctx, clients: .none)
        #expect(keys.contains("client"))
        #expect(!keys.contains("stranger"))
    }

    @Test("a show Dan has booked before is offered far beyond the ordinary window")
    func theBookedRoute() throws {
        let ctx = try Self.container()
        Self.show(ctx, key: "booked", date: "2027-06-13", priorRelationship: "booked")
        #expect(try Self.scoutKeys(ctx, clients: .none).contains("booked"))
    }

    // The route the live store says does the real work: a night on a client's OWN calendar, billed under
    // a name nothing on the show itself recognises.
    @Test("a show from a client's own calendar is offered even when the show names nobody known")
    func theCalendarRoute() throws {
        let ctx = try Self.container()
        Self.show(ctx, key: "onClientCalendar", date: "2027-06-13", sourceIds: ["src-dciny"])
        Self.show(ctx, key: "onARoom", date: "2027-06-13", sourceIds: ["src-merkin"])
        let keys = try Self.scoutKeys(ctx, clients: ClientWindow(clientSourceIds: ["src-dciny"]))
        #expect(keys.contains("onClientCalendar"))
        #expect(!keys.contains("onARoom"))
    }

    // MARK: - The client window has an edge too, and it is inside what the scout reads

    @Test("even a past client's show is held once it is past the client window")
    func theClientWindowStillHasAnEdge() throws {
        let ctx = try Self.container()
        Self.show(ctx, key: "inside", date: "2027-07-11", matchedClientName: "DCINY")   // 11 months
        Self.show(ctx, key: "outside", date: "2027-07-12", matchedClientName: "DCINY")  // 11 months + 1
        let keys = try Self.scoutKeys(ctx, clients: .none)
        #expect(keys.contains("inside"))
        #expect(!keys.contains("outside"))
    }

    // L81/#1571: the demand window must sit inside the supply, or Overture offers a date it never fetches
    // and the list silently depends on which day of the month it is asked. Measured from the constants
    // themselves rather than restated, so moving either is a deliberate act.
    @Test("the client display window is strictly inside the client fetch horizon")
    func demandStaysInsideSupply() {
        #expect(QueueModel.clientLeadTimeWindowMonths < ClientHorizon.clientMonths,
                "a client's display window must end before the last month its calendar is read to")
        #expect(QueueModel.leadTimeWindowDays == 63)
    }

    // MARK: - Nothing else applies a window

    // Dan's second sentence, as a test rather than a promise. A show that reached Prep is one he kept, so
    // the run defaults to covering it whatever its date.
    @Test("every kept show defaults into a Prep run, however far out it is")
    func prepAppliesNoDateRule() throws {
        let ctx = try Self.container()
        let near = Self.show(ctx, key: "near", date: "2026-09-01")
        let far = Self.show(ctx, key: "far", date: "2027-06-13")
        let all = try ctx.fetch(FetchDescriptor<Prospect>())
        let selected = PrepQueueBuilder.prepDefaultSelection(prospects: all)
        #expect(selected == Set([near.naturalKey, far.naturalKey]))
    }

    // The other half of "solely responsible": a kept, drafted or pitched show keeps its stage whatever
    // its date, so the window can only ever hold back an UNTRIAGED show.
    @Test("a kept show far past both windows still holds its stage")
    func onlyTriageIsWindowed() throws {
        let ctx = try Self.container()
        let kept = Self.show(ctx, key: "kept", date: "2028-01-01")
        kept.status = .queued
        let all = try ctx.fetch(FetchDescriptor<Prospect>())
        let context = StageContext.at(Self.today, geo: .none, clients: .none)
        #expect(StageNavigation.naturalKeys(for: .prep, in: all, context: context) == ["kept"])
        #expect(StageNavigation.opensInQueue(key: "kept", in: all, reachedOutKeys: [], context: context))
    }

    // #2365's own complaint: a live far-out show must be reachable in the Queue rather than routed to the
    // Archive, which reads as "this show is gone" about a show that is not.
    @Test("a far-out client show opens in the Queue rather than the Archive")
    func theOriginalComplaint() throws {
        let ctx = try Self.container()
        Self.show(ctx, key: "farClient", date: "2027-06-13", sourceIds: ["src-dciny"])
        let all = try ctx.fetch(FetchDescriptor<Prospect>())
        let context = StageContext.at(Self.today, geo: .none,
                                      clients: ClientWindow(clientSourceIds: ["src-dciny"]))
        #expect(StageNavigation.opensInQueue(key: "farClient", in: all, reachedOutKeys: [],
                                             context: context))
    }
}
