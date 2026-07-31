import Testing
import Foundation
@testable import Overture

// #1887: the card line that lets Dan check what the pitch is about to claim on his behalf.
@Suite("Venue history card line")
struct VenueHistoryCopyTests {

    private func shoot(_ date: String) -> VenueShootHistory.Shoot {
        VenueShootHistory.Shoot(date: date, titles: ["A show"])
    }

    // Both halves in one line: the claim the email will make, and the evidence it rests on. The
    // dates are the whole point, because the band on its own would just be the same assertion
    // twice and Dan could not tell a folding error from the truth (#843's trap).
    @Test func itStatesTheClaimAndTheDatesBehindIt() {
        let line = VenueHistoryCopy.line(band: .aFew,
                                         shoots: [shoot("2018-06-22"), shoot("2026-01-24")])
        #expect(line == "Pitch will say you've photographed a few shows here: Jan 24 2026, Jun 22 2018")
    }

    @Test func oneShootReadsAsHavingBeenThere() {
        #expect(VenueHistoryCopy.line(band: .shotBefore, shoots: [shoot("2024-05-25")])
                == "Pitch will say you've photographed here before: May 25 2024")
    }

    // Most recent first, and a long history is summarised rather than turned into a list.
    @Test func alongHistoryShowsTheLatestFewAndCountsTheRest() {
        let dates = ["2024-01-05", "2024-02-05", "2024-03-05", "2024-04-05", "2024-05-05"]
        #expect(VenueHistoryCopy.line(band: .regularly, shoots: dates.map(shoot))
                == "Pitch will say you shoot here regularly: May 5 2024, Apr 5 2024, Mar 5 2024 and 2 more")
    }

    // No band means the email says nothing, so the card must say nothing too. This is also the
    // Carnegie case: VenueShootHistory returns no band there deliberately, and a card line claiming
    // history the email will not mention would be worse than silence.
    @Test func noBandMeansNoLine() {
        #expect(VenueHistoryCopy.line(band: nil, shoots: [shoot("2024-05-25")]) == nil)
    }

    // A claim with no evidence behind it defeats the entire purpose of the line, so it is not shown
    // even though the band says something.
    @Test func abandWithNoDatesShowsNothingRatherThanAnUncheckableClaim() {
        #expect(VenueHistoryCopy.line(band: .regularly, shoots: []) == nil)
    }

    // An unparseable stored date still names itself rather than being dropped or rendered as a
    // plausible wrong day (EasternDate.dayLabel returns nil rather than guessing).
    @Test func anUnreadableDateIsShownRawRatherThanInvented() {
        let line = VenueHistoryCopy.line(band: .shotBefore, shoots: [shoot("not-a-date")])
        #expect(line?.contains("not-a-date") == true)
    }
}
