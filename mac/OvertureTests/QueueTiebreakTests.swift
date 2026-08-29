import Testing
import Foundation

// #1716: two shows on one night with the same fit score appear in whatever order the store returned.
//
// The queue is already ordered: `QueueView`'s `@Query` sorts by `performanceDate` forward then
// `fitScore` REVERSE, so best fit first within a night has always happened. What has never happened is
// anything below that. Measured during #1648 Phase B across 559 untriaged shows, 280 sit at exactly 0
// and 58 high-fit shows at exactly 8, so ties are the ordinary case rather than the exception, and the
// order inside one is incidental. Dan, 2026-08-18: a stated tiebreak, and the weights are not touched.
//
// The key he proposed was a reachable contact then the soonest date. The second half cannot work and
// that is worth recording: every row in a date group already shares its date, so a date key there is
// consulted only on an exact tie of everything above it and then decides nothing, which is the trap his
// own note named (L170). Shown that, his call on 2026-08-28: reachable contact, then VENUE.
//
// The final key is the natural key, and it is not decoration. Without it two shows alike in fit,
// reachability and venue keep the store's own order, which is not stable between launches, so the queue
// would reorder under him for no change in his data.
@Suite("A tie within one night has a stated order (#1716)")
struct QueueTiebreakTests {

    // `reachability` is the PROBE's verdict, or nil for a show nothing has checked. Deliberately not a
    // boolean: an unchecked show is UNKNOWN, not unreachable, and ranking it with the shows a check
    // proved have no route would state something no check ever measured (L11).
    private func item(_ key: String, fit: Int, reachability: Reachability.ProbeResult?, venue: String?,
                      date: String = "2026-11-02") -> QueueItem {
        var i = QueueItem(id: key, groupName: key, discipline: "theatre", venue: venue,
                          performanceDate: date, sourceListingURL: nil,
                          priorRelationship: "none", production: "unknown", profile: "neutral",
                          coverage: "unknown", fitScore: fit, tier: "longshot", fitReason: "r",
                          matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                          status: .new)
        i.reachabilityResult = reachability
        return i
    }

    // The primary, which was already true through the query and must stay true through the ordering
    // function: a better fit comes first. Asserted here because the function now owns the whole order,
    // so an implementation that only applied the tiebreak would silently drop this.
    @Test func betterFitStillComesFirst() {
        let rows = QueueModel.orderedWithinNight([
            item("low", fit: 2, reachability: .emailFound, venue: "A Room"),
            item("high", fit: 9, reachability: .noEmailFound, venue: "B Room"),
        ])
        #expect(rows.map(\.id) == ["high", "low"],
                "and note the loser here is reachable, so fit really is above the tiebreak")
    }

    // The first tiebreak key, on an exact tie of fit.
    @Test func onAnEqualScoreAReachableContactComesFirst() {
        let rows = QueueModel.orderedWithinNight([
            item("unreachable", fit: 5, reachability: .noEmailFound, venue: "A Room"),
            item("reachable", fit: 5, reachability: .emailFound, venue: "Z Room"),
        ])
        #expect(rows.map(\.id) == ["reachable", "unreachable"])
    }

    // The SECOND key, exercised in its own case, because a fixture that differs on the first key never
    // reaches it and would leave this criterion inert while reading as one that ranks (L170). Dan's note
    // asked for exactly this test.
    @Test func onAnEqualScoreAndEqualReachabilityTheVenueDecides() {
        let rows = QueueModel.orderedWithinNight([
            item("zeta", fit: 5, reachability: .emailFound, venue: "Zankel Hall"),
            item("alpha", fit: 5, reachability: .emailFound, venue: "Abrons Arts Center"),
        ])
        #expect(rows.map(\.id) == ["alpha", "zeta"])
    }

    // And the last resort, which is what makes the order STABLE rather than merely stated. Two shows
    // alike on every key above keep a deterministic order instead of the store's, which changes.
    @Test func aCompleteTieIsStillDeterministic() {
        let forwards = QueueModel.orderedWithinNight([
            item("bbb", fit: 5, reachability: .emailFound, venue: "One Room"),
            item("aaa", fit: 5, reachability: .emailFound, venue: "One Room"),
        ])
        let backwards = QueueModel.orderedWithinNight([
            item("aaa", fit: 5, reachability: .emailFound, venue: "One Room"),
            item("bbb", fit: 5, reachability: .emailFound, venue: "One Room"),
        ])
        #expect(forwards.map(\.id) == ["aaa", "bbb"])
        #expect(forwards.map(\.id) == backwards.map(\.id),
                "the same night in either input order reads the same way round")
    }

    // An UNCHECKED show is unknown, not unreachable, so it sits between the two. Ranking it with the
    // shows a check proved have no route would state something no check ever measured (L11), and Dan
    // triages these on Scout before any check has run, so this is the common case rather than an edge.
    @Test func anUncheckedShowSitsBetweenReachableAndProvenUnreachable() {
        let rows = QueueModel.orderedWithinNight([
            item("proven none", fit: 5, reachability: .noEmailFound, venue: "A Room"),
            item("unchecked", fit: 5, reachability: nil, venue: "B Room"),
            item("reachable", fit: 5, reachability: .contactFormOnly, venue: "C Room"),
        ])
        #expect(rows.map(\.id) == ["reachable", "unchecked", "proven none"])
    }

    // A row with no venue at all must not jump the queue or crash the comparison. It sorts last among
    // its equals rather than first, because a nameless room tells Dan less than a named one.
    @Test func aShowWithNoVenueSortsAfterOneWithA() {
        let rows = QueueModel.orderedWithinNight([
            item("nameless", fit: 5, reachability: .emailFound, venue: nil),
            item("named", fit: 5, reachability: .emailFound, venue: "Zankel Hall"),
        ])
        #expect(rows.map(\.id) == ["named", "nameless"])
    }

    // The whole point, end to end: the order Dan reads on screen is this order. `groupByDate` used to
    // append rows in whatever order it received them, so the tiebreak had to be applied where the groups
    // are built or it would never reach a screen.
    @Test func theDateGroupsOnScreenCarryThatOrder() {
        let groups = QueueModel.groupByDate([
            item("unreachable", fit: 5, reachability: .noEmailFound, venue: "A Room"),
            item("reachable", fit: 5, reachability: .emailFound, venue: "Z Room"),
            item("best", fit: 9, reachability: .noEmailFound, venue: "M Room"),
        ])
        #expect(groups.count == 1)
        #expect(groups.first?.items.map(\.id) == ["best", "reachable", "unreachable"])
    }

    // And it does not reshuffle across nights: the grouping still decides the nights, and this decides
    // only the order inside one.
    @Test func itNeverMovesAShowToADifferentNight() {
        let groups = QueueModel.groupByDate([
            item("second night", fit: 1, reachability: .emailFound, venue: "A Room", date: "2026-11-03"),
            item("first night", fit: 9, reachability: .noEmailFound, venue: "Z Room", date: "2026-11-02"),
        ])
        #expect(groups.map(\.id) == ["2026-11-03", "2026-11-02"],
                "grouping order is the caller's, untouched: this only orders within a group")
        #expect(groups.allSatisfy { $0.items.count == 1 })
    }
}
