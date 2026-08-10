import Testing
import Foundation

// #2371, Dan looking at Scout on 2026-08-09: "now that we have the ability to check reachability again,
// we shouldn't hide the checkbox on nights that have already been checked."
//
// The part that is not just unhiding it: the tick box only ever meant "add this date's OUTSTANDING shows
// to a run", and a finished date has none, so a tick on one would have moved the selection bar's count by
// zero and priced the date at nothing. What ticking a date contributes and whether the date offers a tick
// are therefore one question, asked in one place (L16), and answered here.
@MainActor
@Suite("Ticking a Scout date that is already checked (#2371)")
struct TickAlreadyCheckedDateTests {

    private let probedAt = Date(timeIntervalSince1970: 1_780_000_000)
    private var now: Date { probedAt.addingTimeInterval(100) }
    private let today = "2026-09-01"

    private func item(_ key: String, date: String = "2026-09-12", presenter: String? = nil,
                      status: ReviewStatus = .new, probed: Bool = false,
                      discipline: String = "theater", location: String? = nil) -> QueueItem {
        var i = QueueItem(id: key, groupName: key, discipline: discipline, venue: "Under St Marks",
                          performanceDate: date, sourceListingURL: nil, websiteURL: nil,
                          priorRelationship: "none", production: "self", profile: "strong",
                          coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                          matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                          status: status)
        i.presenter = presenter
        i.location = location
        if probed { i.reachabilityProbedAt = probedAt }
        return i
    }

    // The case Dan is looking at: every show on the night has an answer, so the heading reads
    // "Reachability checked". Ticking it has to carry those shows, or the tick is inert.
    @Test func aFullyCheckedDateContributesItsAnsweredShows() {
        let night = [item("a", probed: true), item("b", probed: true)]
        #expect(QueueModel.dateReachabilityIsFullyChecked(night, now: now, today: today))
        #expect(Set(QueueModel.probeKeysForTickedDate(night, now: now, today: today)) == ["a", "b"])
    }

    // And a date with work left is unchanged: it contributes exactly that work, and its answered shows
    // ride along free, which is #1597's deliberate pricing. Re-checking them is not what ticking a night
    // with outstanding shows has ever meant, and making it so would silently charge for them.
    @Test func aPartlyCheckedDateStillContributesOnlyTheOutstandingShows() {
        let night = [item("answered", probed: true), item("open")]
        #expect(QueueModel.probeKeysForTickedDate(night, now: now, today: today) == ["open"])
    }

    // The heading that is bare because nothing on it was ever the check's business gets no tick box, for
    // the same reason it gets no marker (#1617): there is nothing for a run to do.
    @Test func aDateWithNothingStillOpenContributesNothing() {
        let settled = [item("kept", status: .queued, probed: true),
                       item("gone", status: .dismissed)]
        #expect(QueueModel.probeKeysForTickedDate(settled, now: now, today: today).isEmpty)
    }

    // Nor does a night Dan has refused to travel to, answered or not: the tick would offer to spend on
    // shows the run may not include at all (#1609).
    @Test func aRefusedTownContributesNothingEvenWhenAnswered() {
        let refusals = GeoRefusals(userExcludedTowns: ["larchmont"])
        let night = [item("far", probed: true, location: "Larchmont, NY")]
        #expect(QueueModel.probeKeysForTickedDate(night, now: now, today: today, geo: refusals).isEmpty)
        #expect(!QueueModel.probeKeysForTickedDate(night, now: now, today: today).isEmpty,
                "without the refusal it is an ordinary answered night")
    }

    // A stale answer is already a candidate again (#1332), so it arrives by the ordinary route rather
    // than the re-check one, and the date is not "checked" at all.
    @Test func aStaleAnswerIsOutstandingRatherThanReoffered() {
        var old = item("s", probed: true)
        old.reachabilityProbedAt = now.addingTimeInterval(-(Reachability.probeFreshness + 1))
        #expect(!QueueModel.dateReachabilityIsFullyChecked([old], now: now, today: today))
        #expect(QueueModel.probeKeysForTickedDate([old], now: now, today: today) == ["s"])
    }

    // The point of the whole thing, at the surface Dan reads: the selection bar's count and the confirm's
    // cost move by that date's shows, not by zero.
    @Test func tickingACheckedDateMovesTheCountAndTheCost() throws {
        let night = [item("a", presenter: "FRIGID New York", probed: true),
                     item("b", presenter: "Solo Co", probed: true)]
        let (summary, keys) = try #require(
            QueueModel.probeSelection(dates: ["2026-09-12"], in: night, among: night,
                                      today: today, stage: .scout, now: now))
        #expect(keys == ["a", "b"])
        #expect(summary.showCount == 2)
        #expect(summary.researchCount == 2)
        #expect(summary.alreadyAnsweredCount == 0, "these shows are what the run is for, not free riders")
        #expect(!summary.isEmpty)
    }

    // Unticking is the whole of the undo: the selection is the only thing a tick touched, so the date
    // goes back to reading as checked with nothing outstanding anywhere. This is what #2375 asked
    // somebody to go and observe about the "Check again" link it replaces, which marked every answered
    // show in the store BEFORE the run was even priced.
    @Test func untickingLeavesTheDateExactlyAsItWas() {
        let night = [item("a", probed: true), item("b", probed: true)]
        let selection = ProbeSelectionState()

        selection.toggle("2026-09-12")
        #expect(selection.contains("2026-09-12"))
        selection.toggle("2026-09-12")

        #expect(!selection.contains("2026-09-12"))
        #expect(QueueModel.probeSelection(dates: selection.dates, in: night, among: night,
                                          today: today, stage: .scout, now: now) == nil)
        // The store was never asked for anything, so the heading re-derives to exactly what it was.
        #expect(QueueModel.dateReachabilityIsFullyChecked(night, now: now, today: today))
        #expect(night.allSatisfy { $0.reachabilityRecheckRequestedAt == nil })
    }
}

// The tick box's presence and its payload must stay one question. A view that gated the box on the old
// candidates-only rule would put a tick on every night EXCEPT the ones this issue is about, and no model
// test can see which rule the view asked.
@Suite("The Scout heading offers a tick wherever one would contribute (#2371)")
struct ProbeTickBoxGateTests {
    private var queueView: String { SourceGuardHelper.source("Overture/UI/QueueView.swift") }

    @Test func theCheckboxIsGatedOnWhatTickingWouldContribute() {
        #expect(!queueView.isEmpty)
        #expect(queueView.contains("!QueueModel.probeKeysForTickedDate(group.items, geo: geo).isEmpty"))
    }

    // #2375: the date heading writes nothing to the store any more. The per-CARD "Check again" still
    // does, deliberately (#2267: it survives a cancelled confirm and says the question is outstanding),
    // and that call lives in ProspectRowFactory, not here.
    @Test func theDateHeadingWritesNoRecheckRequest() {
        #expect(!queueView.contains("requestReachabilityRecheck"))
    }
}
