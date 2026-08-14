import Testing

// #1669 / #1648 Phase A2: the shared builder is the ONE place a row's stored strings become a
// scoreable candidate, and it exists so an axis added later cannot be silently forgotten by one
// caller. It was forgotten once: the masthead's merit split hand-built a Candidate, omitted
// `passedOnThisShow`, and measured a show Dan had turned down as if he never had, for months.
//
// #2638 moved this guard HERE. It used to live in `QueuePriorityBreakdownTests`, on the one caller
// that had got it wrong, and that file was deleted with the unused merit split it tested. A guard
// belonging to the builder cannot live on one of its callers: deleting that caller takes the guard
// with it, which is exactly what was about to happen.
//
// It is also stronger than the version it replaces, which asserted only that `passedOnThisShow`
// survived the trip. Every axis is asserted, and the count of axes is asserted too, so adding one
// to `Candidate` without covering it here goes red rather than passing quietly (L96: derive the
// registry from the code, because the entries somebody remembered are the ones already safe).
@Suite("The shared Candidate builder carries every axis (#1669)")
struct CandidateBuilderCarriesEveryAxisTests {

    // A show that scores identically on every axis, so a test can move exactly one of them and read
    // the difference. Deliberately built THROUGH the shared builder, from raw strings, because that
    // trip is the thing under test.
    private func candidate(discipline: String = "music", production: String = "unknown",
                           prior: String = "none", profile: String = "neutral",
                           coverage: String = "unknown", passedOnThisShow: Bool = false,
                           route: ContactRoute = .unchecked,
                           tier: ContactTier? = nil) -> Candidate {
        Candidate(rawDiscipline: discipline, rawProduction: production, rawPriorRelationship: prior,
                  rawProfile: profile, rawCoverage: coverage, passedOnThisShow: passedOnThisShow,
                  contactRoute: route, contactTier: tier)
    }

    private func score(_ c: Candidate) -> Int { Ranker.scoreFit(c).score }

    // MARK: - Every axis reaches the score

    // The axis the original defect was about. A show Dan turned down must score lower than the same
    // show he did not, and the ONLY way that can be true is if the builder carried the flag.
    @Test func theShowDanPassedOnReachesTheScore() {
        #expect(score(candidate(passedOnThisShow: true)) < score(candidate()))
    }

    @Test func everyOtherAxisReachesTheScoreToo() {
        let base = score(candidate())
        #expect(score(candidate(discipline: "dance")) != base, "discipline was dropped")
        #expect(score(candidate(production: "self")) != base, "production was dropped")
        #expect(score(candidate(prior: "booked")) != base, "priorRelationship was dropped")
        #expect(score(candidate(profile: "strong")) != base, "profile was dropped")
        #expect(score(candidate(coverage: "likely_uncovered")) != base, "coverage was dropped")
        #expect(score(candidate(route: .emailFound)) != base, "contactRoute was dropped")
        // The tier only means anything beside a found address, which is the rule `contactRoutePoints`
        // encodes, so it is moved against `emailFound` rather than against the unchecked base.
        #expect(score(candidate(route: .emailFound, tier: .primary))
                != score(candidate(route: .emailFound, tier: .tertiary)), "contactTier was dropped")
    }

    // An unrecognised raw string is not a crash and not a silent zero: it falls to the documented
    // default for its axis, which is what lets a row written by an older build still score.
    @Test func anUnrecognisedRawValueFallsToItsDocumentedDefault() {
        let unknown = candidate(discipline: "underwater basket weaving", production: "sorcery",
                                prior: "enchanted", profile: "ineffable", coverage: "quantum")
        #expect(score(unknown) == score(candidate(discipline: "other", production: "unknown",
                                                  prior: "none", profile: "neutral",
                                                  coverage: "unknown")))
    }

    // MARK: - The list above cannot go stale

    // The half that makes this guard self-maintaining. `Candidate` has nine stored properties: the
    // eight moved above plus `reachable`, which the builder sets itself because any row that reached
    // the store is reachable. Adding a ninth axis without adding it to `everyOtherAxisReachesTheScore`
    // breaks this test, which is the point: a hand-written list of axes only ever checks the ones
    // somebody remembered.
    @Test func thereAreExactlyTheAxesThisSuiteCovers() {
        let axes = Mirror(reflecting: candidate()).children.compactMap(\.label)
        #expect(Set(axes) == ["reachable", "priorRelationship", "production", "profile", "coverage",
                              "discipline", "passedOnThisShow", "contactRoute", "contactTier"],
                "Candidate gained or lost an axis. Add it to everyOtherAxisReachesTheScoreToo above, or this suite stops covering the thing it exists for.")
    }
}
