import Testing
import Foundation
import SwiftData

// #4106 plan v7, Step T0. Test code only: nothing here changes what the app does.
//
// Two halves per order dependent term, and the order of the halves is the point.
//
// 1. `today...` tests REPRODUCE the dependence on unchanged product code before anything is built on
//    it (L681): one small fixture holding the tie, the production function run under two input orders,
//    and the outputs asserted DIFFERENT. Each documents today's behaviour. When Step T makes a product
//    term deterministic, its `today...` test here is CONSUMED by that change and must be retired or
//    inverted in the same commit (L373), which is why each one names the term it pins.
//    Where a dependence cannot be made to show, the test prints UNMEASURED with the reason and asserts
//    nothing, rather than passing as though it had proved something (L143, L159).
// 2. `canonical...` tests run the same fixture through `CanonicalOracle` under 100 seeded permutations
//    and require exactly ONE distinct answer. Each is the guard that `scripts/mutate.sh` removes the
//    canonical sort under and watches go red (L1).
//
// Every name and address is invented; addresses are on example.org (L155, L222). The clock is pinned
// on both ends: `now` and `today` are fixed, and every show date sits after them (L130).
@MainActor
@Suite("Order dependence reproduction (#4106 Step T0)")
final class OrderDependenceReproductionTests {
    private let container: ModelContainer
    private let context: ModelContext

    // 2027-01-15 12:00 UTC, which is 2027-01-15 in Eastern time.
    private let now = Date(timeIntervalSince1970: 1_800_014_400)
    private let today = "2027-01-15"
    private let permutationCount = 100

    init() throws {
        container = try TestModelContainer.inMemory([Prospect.self, Recipient.self])
        context = container.mainContext
    }

    // MARK: fixtures

    @discardableResult
    private func show(_ key: String, title: String, venue: String? = "Harbor Hall",
                      date: String? = "2027-03-10", fit: Int = 5,
                      status: ReviewStatus = .approved, into ctx: ModelContext? = nil) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: title, discipline: "choral", venue: venue,
                         performanceDate: date, sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: fit, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: status)
        (ctx ?? context).insert(p)
        return p
    }

    // Containment-rich filler: titles that contain one another across a few rooms, none tied with the
    // rows each test plants, so every fixture is a few dozen rows rather than just the tie.
    private static let fillerTitles = ["Lantern", "Glass Lantern", "Lantern Revue", "Harbor", "Harbor Lights",
                                       "Harbor Lights Encore", "Cedar", "Cedar Strings", "Cedar Strings Trio"]
    private static let fillerVenues = ["Harbor Hall", "Quarry Hall", "Willow Barn"]

    private func fillerShows(_ count: Int = 24) -> [Prospect] {
        (0..<count).map { index in
            let day = String(format: "2027-05-%02d", 1 + index)
            return show("filler-\(String(format: "%02d", index))",
                        title: Self.fillerTitles[index % Self.fillerTitles.count],
                        venue: Self.fillerVenues[index % Self.fillerVenues.count],
                        date: day, fit: 1 + index % 9)
        }
    }

    private func fillerShowLinkRows(_ count: Int = 24) -> [ShowLink.Row] {
        (0..<count).map { index in
            ShowLink.Row(id: "filler-\(String(format: "%02d", index))",
                         groupName: Self.fillerTitles[index % Self.fillerTitles.count],
                         venue: Self.fillerVenues[index % Self.fillerVenues.count],
                         performanceDate: String(format: "2027-05-%02d", 1 + index))
        }
    }

    private func distinctAnswers(_ render: ([Int]) -> String, size: Int, seed: UInt64) -> Set<String> {
        Set(CanonicalOracle.indexPermutations(of: size, count: permutationCount, seed: seed).map(render))
    }

    private func report(_ term: String, _ distinct: Set<String>, seed: UInt64) -> Comment {
        Comment(rawValue: "\(term): \(distinct.count) distinct outputs over \(permutationCount) orders, seed \(seed)")
    }

    // MARK: ShowLink.group member arrays and ShowLink.collapse fronts

    // Three rows of one production in one bucket (same folded title and venue, intersecting nights),
    // beside a lookalike title that contains theirs and so must stay out.
    private func showLinkRows() -> [ShowLink.Row] {
        fillerShowLinkRows() + [
            ShowLink.Row(id: "sl-a", groupName: "Glass Lantern Revue", venue: "Harbor Hall",
                         performanceDate: "2027-04-10", runNights: ["2027-04-10", "2027-04-11"]),
            ShowLink.Row(id: "sl-b", groupName: "Glass Lantern Revue", venue: "Harbor Hall",
                         performanceDate: "2027-04-11"),
            ShowLink.Row(id: "sl-c", groupName: "Glass Lantern Revue", venue: "Harbor Hall",
                         performanceDate: "2027-04-11"),
            ShowLink.Row(id: "sl-d", groupName: "Glass Lantern", venue: "Harbor Hall",
                         performanceDate: "2027-04-11"),
        ]
    }

    @Test func todayShowLinkGroupMemberOrderFollowsInputOrder() {
        let rows = showLinkRows()
        let forward = OracleRendering.keyed(ShowLink.group(rows))
        let reversed = OracleRendering.keyed(ShowLink.group(rows.reversed()))
        #expect(forward != reversed, "ShowLink.group no longer depends on input order; retire this test (L373)")
    }

    @Test func todayShowLinkCollapseFrontMembersFollowInputOrder() {
        let rows = showLinkRows()
        let forward = OracleRendering.collapse(ShowLink.collapse(rows))
        let reversed = OracleRendering.collapse(ShowLink.collapse(rows.reversed()))
        #expect(forward != reversed, "ShowLink.collapse fronts no longer depend on input order; retire this test (L373)")
    }

    @Test func canonicalShowLinkGroupIsOneAnswerOverEveryOrder() {
        let rows = showLinkRows()
        let seed: UInt64 = 4106_01
        let distinct = distinctAnswers({ order in
            OracleRendering.keyed(CanonicalOracle.showLinkGroup(order.map { rows[$0] }))
        }, size: rows.count, seed: seed)
        #expect(distinct.count == 1, report("ShowLink.group", distinct, seed: seed))
    }

    @Test func canonicalShowLinkCollapseIsOneAnswerOverEveryOrder() {
        let rows = showLinkRows()
        let seed: UInt64 = 4106_02
        let distinct = distinctAnswers({ order in
            OracleRendering.collapse(CanonicalOracle.showLinkCollapse(order.map { rows[$0] }))
        }, size: rows.count, seed: seed)
        #expect(distinct.count == 1, report("ShowLink.collapse", distinct, seed: seed))
    }

    // MARK: queueScope full ties

    // Three shows on one night at one fit, and two dateless shows at one fit: neither sort descriptor
    // can separate them, so today the position in the input list does.
    private func queueScopeRows() -> [Prospect] {
        fillerShows() + [
            show("qs-1", title: "Glass Lantern Revue", date: "2027-03-10", fit: 6),
            show("qs-2", title: "Lantern Revue", date: "2027-03-10", fit: 6),
            show("qs-3", title: "Lantern", date: "2027-03-10", fit: 6),
            show("qs-4", title: "Harbor Lights", date: nil, fit: 4),
            show("qs-5", title: "Harbor", date: nil, fit: 4),
        ]
    }

    @Test func todayQueueScopeBreaksFullTiesByInputPosition() {
        let rows = queueScopeRows()
        let forward = OracleRendering.keys(QueueModel.queueScope(rows))
        let reversed = OracleRendering.keys(QueueModel.queueScope(rows.reversed()))
        #expect(forward != reversed, "queueScope no longer breaks full ties by position; retire this test (L373)")
    }

    @Test func canonicalQueueScopeIsOneAnswerOverEveryOrder() {
        let rows = queueScopeRows()
        let seed: UInt64 = 4106_03
        let distinct = distinctAnswers({ order in
            OracleRendering.keys(CanonicalOracle.queueScope(order.map { rows[$0] }))
        }, size: rows.count, seed: seed)
        #expect(distinct.count == 1, report("queueScope", distinct, seed: seed))
    }

    // MARK: ReachedOutQueue list ties

    private let sentAt = Date(timeIntervalSince1970: 1_800_014_400 - 10 * 86_400)

    @discardableResult
    private func contacted(_ id: String, on p: Prospect, sentAt: Date, replied: Bool = false) -> Recipient {
        let r = Recipient(id: id, email: id, provenance: .act)
        r.sentAt = sentAt
        r.sendState = .sent
        r.gmailMessageId = "msg-\(id)"
        r.replied = replied
        p.setRecipients(p.recipients + [r])
        return r
    }

    // Two shows on one night, each with one contact sent at the same instant: both are due at the same
    // moment, and the list sorts by that moment alone.
    private func reachedOutRows() -> [Prospect] {
        let rows = fillerShows(12)
        let first = show("ro-a", title: "Cedar Strings", status: .contacted)
        contacted("alder@example.org", on: first, sentAt: sentAt)
        let second = show("ro-b", title: "Cedar Strings Trio", status: .contacted)
        contacted("birch@example.org", on: second, sentAt: sentAt)
        let third = show("ro-c", title: "Cedar", status: .contacted)
        contacted("cedar@example.org", on: third, sentAt: sentAt)
        return rows + [first, second, third]
    }

    @Test func todayReachedOutListBreaksEqualDatesByInputPosition() throws {
        let rows = reachedOutRows()
        let forward = ReachedOutQueue.activeWithDates(from: rows, now: now)
        try #require(forward.count == 3, "fixture: all three contacted shows must be live")
        try #require(Set(forward.map(\.next)).count == 1, "fixture: the three rows must tie on next")
        let reversed = ReachedOutQueue.activeWithDates(from: rows.reversed(), now: now)
        #expect(OracleRendering.reachedOut(forward) != OracleRendering.reachedOut(reversed),
                "ReachedOutQueue no longer breaks equal dates by position; retire this test (L373)")
    }

    @Test func canonicalReachedOutListIsOneAnswerOverEveryOrder() {
        let rows = reachedOutRows()
        let seed: UInt64 = 4106_04
        let distinct = distinctAnswers({ order in
            OracleRendering.reachedOut(CanonicalOracle.reachedOut(order.map { rows[$0] }, now: now))
        }, size: rows.count, seed: seed)
        #expect(distinct.count == 1, report("ReachedOutQueue list", distinct, seed: seed))
    }

    // MARK: ReachedOutQueue representative (relationship order, judged by tie class)

    // One show whose two contacts tie in both branches the representative rule has: `replied` picks the
    // first replied contact, and the no reply branch picks the first at the minimum `next`.
    private func representativeFixture(order: [String], replied: Bool,
                                       into ctx: ModelContext) -> Prospect {
        let p = show("rep-show", title: "Juniper Choral Society", status: .contacted, into: ctx)
        for id in order { contacted(id, on: p, sentAt: sentAt, replied: replied) }
        return p
    }

    private func representative(of p: Prospect) -> String? {
        ReachedOutQueue.activeWithDates(from: [p], now: now).first?.recipient.id
    }

    private let tiedContacts = ["hazel@example.org", "rowan@example.org"]

    // The function itself: handed the relationship in two orders, it names two different people.
    @Test(arguments: [false, true])
    func todayRepresentativeFollowsRecipientArrayOrder(replied: Bool) throws {
        let forward = representativeFixture(order: tiedContacts, replied: replied, into: ModelContext(container))
        let backward = representativeFixture(order: tiedContacts.reversed(), replied: replied,
                                             into: ModelContext(container))
        try #require(forward.recipients.map(\.id) == tiedContacts,
                     "fixture: an unsaved relationship keeps the order it was assigned")
        #expect(representative(of: forward) != representative(of: backward),
                "the representative no longer follows p.recipients order; retire this test (L373)")
    }

    // What production actually meets: the relationship as the STORE hands it back after a save. Whether
    // insertion order survives that round trip is SwiftData's to decide, so this measures rather than
    // assumes, and says UNMEASURED when the store returned one order for both insertions.
    @Test(arguments: [false, true])
    func todayRepresentativeAfterAStoreRoundTrip(replied: Bool) throws {
        func roundTrip(_ order: [String]) throws -> (order: [String], representative: String?) {
            let store = try TestModelContainer.inMemory([Prospect.self, Recipient.self])
            let writer = ModelContext(store)
            representativeFixture(order: order, replied: replied, into: writer)
            try writer.save()
            let reader = ModelContext(store)
            let fetched = try #require(try reader.fetch(FetchDescriptor<Prospect>()).first)
            return (fetched.recipients.map(\.id), representative(of: fetched))
        }
        let forward = try roundTrip(tiedContacts)
        let backward = try roundTrip(tiedContacts.reversed())
        let branch = replied ? "replied branch" : "no reply branch"
        if forward.order == backward.order {
            print("UNMEASURED: ReachedOutQueue representative, \(branch), after a store round trip:"
                  + " the store returned \(forward.order) for both insertion orders, so this fixture cannot"
                  + " make relationship order differ; the dependence is real in the function (see"
                  + " todayRepresentativeFollowsRecipientArrayOrder) but not shown through a fetch here")
            return
        }
        print("REPRODUCED: ReachedOutQueue representative, \(branch), after a store round trip: orders"
              + " \(forward.order) and \(backward.order) named \(forward.representative ?? "nil")"
              + " and \(backward.representative ?? "nil")")
        #expect(forward.representative != backward.representative)
    }

    // Plan section 6, second bullet: the representative is correct when it is a MEMBER of the oracle's tie
    // class, whatever the relationship order was. Over both branches and every order of three contacts.
    @Test func representativeIsAlwaysAMemberOfTheTieClass() throws {
        let contacts = ["hazel@example.org", "rowan@example.org", "yarrow@example.org"]
        var judged = 0
        var tieClassesWiderThanOne = 0
        for replied in [false, true] {
            for order in CanonicalOracle.permutations(contacts, count: 12, seed: 4106_05) {
                let p = show("tie-\(judged)", title: "Juniper Choral Society", status: .contacted,
                             into: ModelContext(container))
                for id in order {
                    // In the replied branch the third contact did NOT reply, so the class is the two that did.
                    contacted(id, on: p, sentAt: sentAt, replied: replied && id != "yarrow@example.org")
                }
                let row = try #require(ReachedOutQueue.activeWithDates(from: [p], now: now).first)
                let tieClass = CanonicalOracle.reachedOutTieClass(of: p, now: now)
                if tieClass.count > 1 { tieClassesWiderThanOne += 1 }
                #expect(tieClass.contains { $0 === row.recipient },
                        "representative \(row.recipient.id) is outside the tie class \(tieClass.map(\.id))")
                judged += 1
            }
        }
        #expect(judged == 24)
        print("ReachedOutQueue tie class: \(tieClassesWiderThanOne) of \(judged) fixture rows hold a tie class"
              + " wider than one contact")
    }

    // MARK: EngagementLink equal date membership

    // Two engagements of one title open on the same night at different rooms, one running three weeks
    // and one playing once, and a third room two weeks later. The chain compares each row with the row
    // appended LAST, so which of the two equal date rows lands last decides whether the third joins.
    private func engagementRows() -> [EngagementLink.Row] {
        fillerShows(18).map(EngagementLink.Row.init) + [
            EngagementLink.Row(id: "el-x", groupName: "Cedar Quartet", venue: "North Hall",
                               performanceDate: "2027-03-01", runEndDate: "2027-03-20"),
            EngagementLink.Row(id: "el-y", groupName: "Cedar Quartet", venue: "South Hall",
                               performanceDate: "2027-03-01"),
            EngagementLink.Row(id: "el-z", groupName: "Cedar Quartet", venue: "East Hall",
                               performanceDate: "2027-03-15"),
        ]
    }

    @Test func todayEngagementMembershipFollowsEqualDateInputOrder() {
        let rows = engagementRows()
        let forward = OracleRendering.engagement(EngagementLink.group(rows))
        let reversed = OracleRendering.engagement(EngagementLink.group(rows.reversed()))
        #expect(forward != reversed, "EngagementLink equal dates no longer depend on order; retire this test (L373)")
    }

    @Test func canonicalEngagementLinkIsOneAnswerOverEveryOrder() {
        let rows = engagementRows()
        let seed: UInt64 = 4106_06
        let distinct = distinctAnswers({ order in
            OracleRendering.engagement(CanonicalOracle.engagementLink(order.map { rows[$0] }))
        }, size: rows.count, seed: seed)
        #expect(distinct.count == 1, report("EngagementLink.group", distinct, seed: seed))
    }

    // MARK: FeedBreakEvent label and tie order

    // Three flagged rows at one room written two ways (the fold makes them one source), so the event's
    // label is whichever spelling the first member carried.
    private func flagged(_ key: String, venue: String, missed: Int) -> Prospect {
        let p = show(key, title: "Willow Song Cycle \(key)", venue: venue, date: "2027-02-20")
        p.missedScoutCount = missed
        return p
    }

    private func feedBreakRows() -> [Prospect] {
        fillerShows(12) + [
            flagged("fb-1", venue: "Lantern Hall", missed: 3),
            flagged("fb-2", venue: "LANTERN HALL", missed: 3),
            flagged("fb-3", venue: "LANTERN HALL", missed: 3),
        ]
    }

    @Test func todayFeedBreakLabelIsTheFirstMembersSpelling() throws {
        let rows = feedBreakRows()
        let forward = FeedBreakEvent.events(among: rows, asOf: today)
        try #require(forward.count == 1, "fixture: the three flagged rows must form one event")
        let reversed = FeedBreakEvent.events(among: rows.reversed(), asOf: today)
        #expect(OracleRendering.feedBreaks(forward) != OracleRendering.feedBreaks(reversed),
                "FeedBreakEvent's label no longer follows input order; retire this test (L373)")
    }

    @Test func canonicalFeedBreakEventsAreOneAnswerOverEveryOrder() {
        let rows = feedBreakRows()
        let seed: UInt64 = 4106_07
        let distinct = distinctAnswers({ order in
            OracleRendering.feedBreaks(CanonicalOracle.feedBreakEvents(order.map { rows[$0] }, asOf: today))
        }, size: rows.count, seed: seed)
        #expect(distinct.count == 1, report("FeedBreakEvent", distinct, seed: seed))
    }

    // The TIE half: two events at one room label with the same member count and different miss counts.
    // `sorted` leaves them in `buckets.values` order, which is a Dictionary's iteration order, and that
    // is seeded per storage allocation rather than by input order. So this measures whether the tie
    // order moves at all, over input orders AND over repeated calls on one order, and reports what it saw.
    @Test func todayFeedBreakFullTieOrder() {
        let rows = fillerShows(6) + [
            flagged("ft-1", venue: "Lantern Hall", missed: 3),
            flagged("ft-2", venue: "Lantern Hall", missed: 3),
            flagged("ft-3", venue: "Lantern Hall", missed: 3),
            flagged("ft-4", venue: "Lantern Hall", missed: 4),
            flagged("ft-5", venue: "Lantern Hall", missed: 4),
            flagged("ft-6", venue: "Lantern Hall", missed: 4),
        ]
        let canonical = rows.sorted(by: CanonicalOracle.byNaturalKey)
        var sameOrder: Set<String> = []
        var keepAlive: [[FeedBreakEvent.Event]] = []
        for _ in 0..<permutationCount {
            let events = FeedBreakEvent.events(among: canonical, asOf: today)
            keepAlive.append(events)
            sameOrder.insert(events.map { String($0.missedScoutCount) }.joined(separator: ","))
        }
        let acrossOrders = Set(CanonicalOracle.permutations(rows, count: permutationCount, seed: 4106_08).map {
            FeedBreakEvent.events(among: $0, asOf: today).map { String($0.missedScoutCount) }.joined(separator: ",")
        })
        #expect(keepAlive.allSatisfy { $0.count == 2 })
        if sameOrder.count == 1 && acrossOrders.count == 1 {
            print("UNMEASURED: FeedBreakEvent full tie order: one order (\(sameOrder.first ?? ""))"
                  + " over \(permutationCount) repeated calls and \(permutationCount) input orders. Swift seeds"
                  + " Dictionary iteration per storage allocation, so the dependence is on the hash table,"
                  + " not the input, and this process did not show it")
        } else {
            print("REPRODUCED: FeedBreakEvent full tie order: \(sameOrder.count) orders over repeated calls on"
                  + " ONE input order, \(acrossOrders.count) over input orders. A canonical INPUT order cannot"
                  + " fix this; only an output tie-break can")
        }
    }

    // MARK: laterLookalikes nil firstSeenAt ties

    // Two later rows pointing at one card, both written before #1886 (no firstSeenAt), so the sort has
    // nothing to order them by and the card names whichever arrived first in the input.
    //
    // `firstSeenAt` is CLEARED by hand: the initialiser stamps it from `ingestedAt`, which is the wall
    // clock at construction, so two rows built one after the other are never tied and the sort orders
    // them by build order. The first run of this test measured exactly that and passed the wrong way.
    private func lookalikeRows() -> [Prospect] {
        let target = show("ll-t", title: "Harbor Lights", venue: "Quarry Hall", date: "2027-03-12")
        let first = show("ll-a", title: "Harbor Lights Encore", venue: "Quarry Hall", date: "2027-03-13")
        first.arrivedLookingLike = target.naturalKey
        first.firstSeenAt = nil
        let second = show("ll-b", title: "Harbor Lights Encore Gala", venue: "Quarry Hall", date: "2027-03-14")
        second.arrivedLookingLike = target.naturalKey
        second.firstSeenAt = nil
        return fillerShows(12) + [target, first, second]
    }

    // #4349, plan v7 Step T: `todayLaterLookalikesBreakNilFirstSeenTiesByInputPosition` stood here and was
    // CONSUMED when equal sightings gained a natural key tie-break, so it is inverted rather than kept (L373).
    // The product, called with no wrapper, now gives one answer over 100 orders, the canonical oracle's, and
    // the card names the smaller key's title; a re-key that moves the other row to the front of the key
    // order moves the named title with it (L419).
    @Test(arguments: [false, true])
    func productLaterLookalikesAreTheCanonicalAnswerOverEveryOrder(rekeyed: Bool) throws {
        let rows = lookalikeRows()
        if rekeyed { rows.first { $0.naturalKey == "ll-b" }?.naturalKey = "ll-0" }
        let keys = rows.map(\.naturalKey)
        let seed: UInt64 = 4349_01
        let oracle = OracleRendering.keyed(CanonicalOracle.laterLookalikes(rows, now: now, today: today))
        let distinct = distinctAnswers({ order in
            OracleRendering.keyed(CanonicalOracle.lookalikeTitlesByCard(
                QueueModel.scope(from: order.map { rows[$0] }, now: now, today: today), keys: keys))
        }, size: rows.count, seed: seed)
        #expect(distinct == [oracle], report("laterLookalikes, product", distinct, seed: seed))
        let titles = CanonicalOracle.lookalikeTitlesByCard(QueueModel.scope(from: rows, now: now, today: today),
                                                           keys: keys)
        try #require(titles["ll-t"]?.count == 2, "fixture: the target card must name both later lookalikes")
        #expect(titles["ll-t"]?.first == (rekeyed ? "Harbor Lights Encore Gala" : "Harbor Lights Encore"))
    }

    // The sighting still decides first: a stamped row is named ahead of an unstamped one whatever the keys.
    @Test func productLaterLookalikesStillNameTheNewestSightingFirst() throws {
        let rows = lookalikeRows()
        rows.first { $0.naturalKey == "ll-b" }?.firstSeenAt = now
        let titles = CanonicalOracle.lookalikeTitlesByCard(QueueModel.scope(from: rows, now: now, today: today),
                                                           keys: rows.map(\.naturalKey))
        #expect(titles["ll-t"]?.first == "Harbor Lights Encore Gala")
    }

    @Test func canonicalLaterLookalikesAreOneAnswerOverEveryOrder() {
        let rows = lookalikeRows()
        let seed: UInt64 = 4106_09
        let distinct = distinctAnswers({ order in
            OracleRendering.keyed(CanonicalOracle.laterLookalikes(order.map { rows[$0] }, now: now, today: today))
        }, size: rows.count, seed: seed)
        #expect(distinct.count == 1, report("laterLookalikes", distinct, seed: seed))
    }

    // MARK: the ledger: equal probedAt, and the per orgKey verdict memo

    private let orgKey = "presenter:lark & finch players"
    private var probedAt: Date { now.addingTimeInterval(-86_400) }

    private func answer(presenter: String, email: String) -> OrgReachabilityAnswer {
        OrgReachabilityAnswer(orgKey: orgKey, result: .emailFound, probedAt: probedAt,
                              sourceNaturalKey: "lg-source", sourceGroupName: "Lark Suite",
                              presenterName: presenter, foundEmails: [email])
    }

    private func presented(_ key: String, by presenter: String, at venue: String) -> Prospect {
        let p = show(key, title: "Lark Suite \(key)", venue: venue, date: "2027-03-20")
        p.presenter = presenter
        return p
    }

    // A presenter at two rooms, so it qualifies as a producer.
    private func qualifyingCorpus() -> [Prospect] {
        fillerShows(12) + [
            presented("lg-1", by: "Lark & Finch Players", at: "Quarry Hall"),
            presented("lg-2", by: "Lark & Finch Players", at: "Willow Barn"),
        ]
    }

    // Two stored answers for one organisation at the same instant. The unique constraint on orgKey makes
    // this impossible in a saved store; the ledger's own comment names it anyway, and the plan's canonical
    // order includes it, so the fixture holds it directly.
    @Test func todayLedgerEqualProbedAtKeepsTheFirstAnswerSeen() {
        let corpus = qualifyingCorpus()
        let answers = [answer(presenter: "Lark & Finch Players", email: "box@example.org"),
                       answer(presenter: "Lark and Finch Players", email: "desk@example.org")]
        let forward = QueueModel.inheritedAnswers(answers, corpus: corpus, overrides: .none, refusals: .none,
                                                  heldKeys: [], now: now)
        let reversed = QueueModel.inheritedAnswers(answers.reversed(), corpus: corpus, overrides: .none,
                                                   refusals: .none, heldKeys: [], now: now)
        #expect(!forward.isEmpty)
        #expect(OracleRendering.inherited(forward) != OracleRendering.inherited(reversed),
                "the ledger no longer keeps the first equal probedAt answer; retire this test (L373)")
    }

    // Two spellings of one organisation that fold to ONE orgKey but to two producer keys: `&amp;` is
    // decoded by `OrgKey`'s canonicalize and not by `ProducerGate.key`. One spelling plays two rooms and
    // qualifies; the other plays one and does not. The memo keeps the verdict of whichever show came first.
    private func memoCorpus() -> [Prospect] {
        qualifyingCorpus() + [presented("lg-3", by: "Lark &amp; Finch Players", at: "Harbor Hall")]
    }

    @Test func todayLedgerVerdictMemoFollowsTheFirstPresenterMet() throws {
        try #require(OrgKey.stored(for: "Lark & Finch Players") == orgKey)
        try #require(OrgKey.stored(for: "Lark &amp; Finch Players") == orgKey)
        try #require(ProducerGate.key("Lark & Finch Players") != ProducerGate.key("Lark &amp; Finch Players"),
                     "fixture: the two spellings must be two producer keys")
        let corpus = memoCorpus()
        let answers = [answer(presenter: "Lark & Finch Players", email: "box@example.org")]
        let qualifyingFirst = QueueModel.inheritedAnswers(answers, corpus: corpus, overrides: .none,
                                                          refusals: .none, heldKeys: [], now: now)
        let lonelyFirst = QueueModel.inheritedAnswers(answers, corpus: corpus.reversed(), overrides: .none,
                                                      refusals: .none, heldKeys: [], now: now)
        #expect(OracleRendering.inherited(qualifyingFirst) != OracleRendering.inherited(lonelyFirst),
                "the verdict memo no longer follows show order; retire this test (L373)")
    }

    @Test func canonicalLedgerIsOneAnswerOverEveryOrder() {
        let corpus = memoCorpus()
        let answers = [answer(presenter: "Lark & Finch Players", email: "box@example.org"),
                       answer(presenter: "Lark and Finch Players", email: "desk@example.org")]
        let seed: UInt64 = 4106_10
        var generator = SeededGenerator(seed: seed)
        var distinct: Set<String> = []
        for _ in 0..<permutationCount {
            let shuffledCorpus = corpus.shuffled(using: &generator)
            let shuffledAnswers = answers.shuffled(using: &generator)
            distinct.insert(OracleRendering.inherited(
                CanonicalOracle.inheritedAnswers(shuffledAnswers, corpus: shuffledCorpus, now: now)))
        }
        #expect(distinct.count == 1, report("OrgAnswerLedger", distinct, seed: seed))
    }

    // MARK: bookings (date, kind, groupName) ties

    private let sendDay = Date(timeIntervalSince1970: 1_751_328_000 - 30 * 86_400)
    private let sharedBooking = OvertureBooking(id: "B-shared", clientId: "C-juniper",
                                                clientDisplayName: "Juniper Choral Society",
                                                shootName: "Gala", startDate: "2026-07-01", endDate: "2026-07-01",
                                                venueId: nil, venueName: "Harbor Hall")

    // Two contacted shows of one group on one date, both an exact match for ONE booking. The first in
    // the sorted order claims it and auto-books; the other is left a suggestion.
    private func bookingRows(into ctx: ModelContext) -> [Prospect] {
        let rows = ["bk-1", "bk-2", "bk-3"].map { key -> Prospect in
            let p = show(key, title: "Juniper Choral Society", date: "2026-07-01", into: ctx)
            p.sentAt = sendDay
            p.gmailMessageId = "msg-\(key)"
            p.downbeatClientId = "C-juniper"
            return p
        }
        return rows
    }

    @Test func todayBookingTieIsClaimedByTheFirstInInputOrder() {
        let forward = bookingRows(into: ModelContext(container))
        DownbeatBooking.reconcileBooked(prospects: forward, clients: [], bookings: [sharedBooking],
                                        health: .ok, now: now)
        let backward = bookingRows(into: ModelContext(container))
        DownbeatBooking.reconcileBooked(prospects: backward.reversed(), clients: [], bookings: [sharedBooking],
                                        health: .ok, now: now)
        #expect(forward.filter { $0.outcome == .booked }.count == 1)
        #expect(OracleRendering.booked(forward) != OracleRendering.booked(backward),
                "the booking tie no longer follows input order; retire this test (L373)")
    }

    @Test func canonicalBookingsAreOneAnswerOverEveryOrder() {
        let seed: UInt64 = 4106_11
        let distinct = distinctAnswers({ order in
            let rows = bookingRows(into: ModelContext(container))
            CanonicalOracle.reconcileBooked(order.map { rows[$0] }, bookings: [sharedBooking], now: now)
            return OracleRendering.booked(rows)
        }, size: 3, seed: seed)
        #expect(distinct.count == 1, report("DownbeatBooking.reconcileBooked", distinct, seed: seed))
    }
}
