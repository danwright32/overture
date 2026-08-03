import Testing

// #1597 Phase 4.4 to 4.6: the arithmetic behind the multi-date selection bar and its confirm.
//
// The number shown while Dan is ticking dates and the number he approves come from ONE place, so they
// cannot drift apart. And past a ceiling the run is refused rather than warned about, because the
// failure mode is a familiar-looking confirm clicked through on a week.
@Suite("What a multi-date reachability check costs (#1597)")
struct ProbeSelectionTests {

    private func show(_ key: String, _ presenter: String?, _ venue: String) -> ProbeBatch.Show {
        ProbeBatch.Show(key: key, presenter: presenter, venue: venue)
    }

    // One producer across three rooms: three shows, ONE lookup, and the cost reflects the one lookup.
    private var frigid: [ProbeBatch.Show] {
        [show("a", "FRIGID New York", "Under St Marks"),
         show("b", "FRIGID New York", "The Kraine Theater"),
         show("c", "FRIGID New York", "Under St Marks")]
    }

    @Test func theCostFollowsTheLookupsNotTheShows() {
        let s = ProbeSelection.summarize(dateCount: 3, candidates: frigid, alreadyAnswered: 0, among: frigid)
        #expect(s.showCount == 3)
        #expect(s.researchCount == 1)
        #expect(s.organisationCount == 1)
        // One lookup is one round, so the wait is one lookup long.
        #expect(s.estimatedSeconds == ProbeSelection.measuredSecondsPerLookup)
    }

    // Dan runs this on a Max plan, where the tool's dollar figure is an API-equivalent number and not a
    // bill he ever receives. Showing money implied a charge that does not exist; what he actually spends
    // is time and his rolling usage window, so that is what the estimate is in.
    @Test func theEstimateIsTimeAndNamesNoMoney() {
        let s = ProbeSelection.summarize(dateCount: 3, candidates: frigid, alreadyAnswered: 0, among: frigid)
        #expect(!ProbeSelectionCopy.costLine(s).contains("$"))
        #expect(ProbeSelectionCopy.costLine(s).contains("minute"))
        // #1765: and the same holds for a big selection, which used to be refused with its own sentence
        // and now goes through the ordinary confirm. Money must not creep back in on the large path.
        let big = ProbeSelection.summarize(
            dateCount: 7, candidates: (0..<41).map { show("k\($0)", "Solo \($0)", "Room \($0)") },
            alreadyAnswered: 0, among: (0..<41).map { show("k\($0)", "Solo \($0)", "Room \($0)") })
        #expect(!ProbeSelectionCopy.multiDateMessage(big).contains("$"))
    }

    // Lookups run up to ten at a time, so the wait is the number of ROUNDS, not the number of lookups.
    // Estimating it as the sum would tell Dan a 4-minute check takes 100 minutes and he would never run it.
    @Test func theWaitIsTheRoundsNotTheSumBecauseLookupsOverlap() {
        let ten = (0..<10).map { show("k\($0)", "Solo \($0)", "Room \($0)") }
        let s10 = ProbeSelection.summarize(dateCount: 1, candidates: ten, alreadyAnswered: 0, among: ten)
        #expect(s10.researchCount == 10)
        #expect(s10.estimatedSeconds == ProbeSelection.measuredSecondsPerLookup)   // one full round

        let eleven = (0..<11).map { show("k\($0)", "Solo \($0)", "Room \($0)") }
        let s11 = ProbeSelection.summarize(dateCount: 2, candidates: eleven, alreadyAnswered: 0, among: eleven)
        #expect(s11.estimatedSeconds == ProbeSelection.measuredSecondsPerLookup * 2)   // spills to a second
    }

    // A night of one-off productions shares nothing, so it costs per show. This is the expensive case,
    // and the estimate has to say so rather than flattering it.
    @Test func aNightOfOneOffsCostsPerShow() {
        let rented = [show("a", "Green Room 42", "Green Room 42"),
                      show("b", "Green Room 42", "Green Room 42"),
                      show("c", "Green Room 42", "Green Room 42")]
        let s = ProbeSelection.summarize(dateCount: 1, candidates: rented, alreadyAnswered: 0, among: rented)
        #expect(s.researchCount == 3)
        #expect(s.performerHuntCount == 3)
        #expect(s.organisationCount == 0)
        // Three lookups fit in one round, so this is the ~3 minutes the first real check took, not the
        // 8 minutes it took when they ran one after another.
        #expect(s.estimatedSeconds == ProbeSelection.measuredSecondsPerLookup)
    }

    // #1765: THE BRAKE IS GONE. A big selection is a decision Dan is allowed to make, and the sheet states
    // what it costs rather than refusing it. The size-specific behaviour is pinned in
    // ProbeSelectionRunnableTests; here the only claim is that a large selection still produces an honest
    // summary and an honest sentence, with no trace of the old refusal in either.
    @Test func aBigSelectionIsSummarisedHonestlyAndNotRefused() {
        let many = (0..<41).map { show("k\($0)", "Solo Co \($0)", "Room \($0)") }
        let s = ProbeSelection.summarize(dateCount: 7, candidates: many, alreadyAnswered: 0, among: many)
        #expect(s.researchCount == 41)
        let message = ProbeSelectionCopy.multiDateMessage(s)
        #expect(message.contains("41 lookups"))
        #expect(!message.contains("Select fewer dates"))
        #expect(!message.contains("Overture stops at"))
    }

    // A big night of one producer's shows is CHEAP: one lookup answers for all sixty. Kept from when a
    // ceiling counted lookups rather than shows, because the dedupe it proves is what makes such a night
    // cost three minutes, and that arithmetic is the whole basis of the wait the confirm now quotes.
    @Test func aBigNightOfOneProducerIsOneLookup() {
        let manyFromOne = (0..<60).map { show("k\($0)", "FRIGID New York", $0 % 2 == 0 ? "Under St Marks" : "The Kraine Theater") }
        let s = ProbeSelection.summarize(dateCount: 5, candidates: manyFromOne, alreadyAnswered: 0, among: manyFromOne)
        #expect(s.showCount == 60)
        #expect(s.researchCount == 1)
    }

    // Shows already answered cost nothing, and must be counted out loud rather than dropped: a number
    // that quietly omits rows stops being a promise about what is on screen.
    @Test func alreadyAnsweredShowsAreNamedNotDropped() {
        let s = ProbeSelection.summarize(dateCount: 2, candidates: frigid, alreadyAnswered: 4, among: frigid)
        #expect(s.alreadyAnsweredCount == 4)
        #expect(s.researchCount == 1)   // they are not re-researched
        #expect(ProbeSelectionCopy.multiDateMessage(s).contains("4 more shows were checked recently"))
    }

    @Test func theRunningBarNamesDatesAndShows() {
        let s = ProbeSelection.summarize(dateCount: 3, candidates: frigid, alreadyAnswered: 0, among: frigid)
        #expect(ProbeSelectionCopy.selectionSummary(s) == "3 dates, 3 shows")
    }

    // Singulars, because "1 dates, 1 shows" is the kind of line that makes the whole surface look unfinished.
    @Test func oneDateAndOneShowReadAsSingular() {
        let one = [show("a", "Solo Co", "The Tank")]
        let s = ProbeSelection.summarize(dateCount: 1, candidates: one, alreadyAnswered: 0, among: one)
        #expect(ProbeSelectionCopy.selectionSummary(s) == "1 date, 1 show")
        #expect(ProbeSelectionCopy.costLine(s) == "1 lookup, about 3 minutes.")
    }

    // The saving is only mentioned when there is one. On a night where every show is its own hunt,
    // "3 lookups ... shows by the same producer share one" would be false as well as noise.
    @Test func theSharingLineAppearsOnlyWhenSomethingIsActuallyShared() {
        let shared = ProbeSelection.summarize(dateCount: 1, candidates: frigid, alreadyAnswered: 0, among: frigid)
        #expect(ProbeSelectionCopy.costLine(shared).contains("share one"))

        let one = [show("a", "Solo Co", "The Tank")]
        let unshared = ProbeSelection.summarize(dateCount: 1, candidates: one, alreadyAnswered: 0, among: one)
        #expect(!ProbeSelectionCopy.costLine(unshared).contains("share one"))
    }

    @Test func anEmptySelectionKnowsItIsEmpty() {
        let s = ProbeSelection.summarize(dateCount: 0, candidates: [], alreadyAnswered: 0, among: [])
        #expect(s.isEmpty)
        #expect(s.estimatedSeconds == 0)
        #expect(ProbeSelection.outcome(for: s) == .nothing)
    }

    // The bar and the confirm must be reading the same arithmetic. If they ever diverge, Dan approves a
    // number he was not shown.
    @Test func theBarAndTheConfirmAgreeAboutTheCost() {
        let s = ProbeSelection.summarize(dateCount: 2, candidates: frigid, alreadyAnswered: 1, among: frigid)
        #expect(ProbeSelectionCopy.multiDateMessage(s).contains(ProbeSelectionCopy.costLine(s)))
    }
}
