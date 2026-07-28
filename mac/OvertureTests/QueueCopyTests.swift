import Testing
import Foundation
@testable import Overture

// #885: the queue's own copy, out of the view.
//
// Pluralization was being done by hand in six places, in five files, with an inline ternary each time,
// while AgentRoster had a private pluralizer of its own the whole time. That is the shape of the rule
// this issue is about: not one dramatic bug, but the same small decision restated everywhere until one
// copy of it is wrong and nothing can tell.
@Suite("Queue copy (#885)")
struct QueueCopyTests {

    // MARK: - One pluralizer

    @Test func aCountAndItsNounAgree() {
        #expect(Plural.count(1, "show") == "1 show")
        #expect(Plural.count(2, "show") == "2 shows")
        #expect(Plural.count(0, "show") == "0 shows")
    }

    // Zero is plural in English ("0 shows"), which is the case a hand-written `n == 1 ? "" : "s"` gets
    // right by accident and a hand-written `n > 1` gets wrong.
    @Test func anIrregularPluralIsSpelledOutRatherThanGuessed() {
        #expect(Plural.count(1, "person", "people") == "1 person")
        #expect(Plural.count(3, "person", "people") == "3 people")
    }

    // MARK: - The counts that are promises about rows (#863)

    @Test func theNewLeadsHeadingCountsTheLeadsItIsAboutToShow() {
        #expect(QueueModel.newLeadsHeading(count: 1) == "1 new lead while you were away")
        #expect(QueueModel.newLeadsHeading(count: 4) == "4 new leads while you were away")
    }

    // The verb agrees with the count, and it inverts: ONE needs you, THREE need you. The inline version
    // wrote this backwards from every other pluralization in the app (`n == 1 ? "s" : ""`), which is
    // exactly the kind of thing that is right until somebody "tidies" it.
    @Test func theNeedsYouLineAgreesWithItsCount() {
        #expect(AgentRoster.needsYouLabel(1) == "1 needs you")
        #expect(AgentRoster.needsYouLabel(3) == "3 need you")
    }

    @Test func nothingNeedingYouSaysNothing() {
        #expect(AgentRoster.needsYouLabel(0) == nil)
    }

    // MARK: - The pending-bookings filter
    //
    // Two entirely different sentences depending on whether the filter is on, and the ON one carries a
    // count. It explains why rows have disappeared, which is the one thing a filter must never leave Dan
    // guessing about.

    @Test func theBookingFilterExplainsWhyRowsAreHiddenWhenItIsOn() {
        let help = QueueModel.pendingBookingsHelp(showingOnly: true, count: 2)

        #expect(help == "Showing only the 2 pending bookings. Click to show the whole queue again.")
    }

    @Test func theBookingFilterExplainsWhatItWouldDoWhenItIsOff() {
        let help = QueueModel.pendingBookingsHelp(showingOnly: false, count: 2)

        #expect(help.contains("Show only prospects where Downbeat detected a booking"))
        #expect(!help.contains("Click to show the whole queue again"))
    }

    // MARK: - The filter feeding the "To send" count
    //
    // The pill's number is a promise about rows (#863). The windowing that produces it was already
    // tested (QueueModel.toSendQueue); the three-clause filter feeding that windowing was written in the
    // view body, so the number was only ever as correct as its untested half.

    private func item(_ id: String, discipline: String = "choral", highFit: Bool = false,
                      bookingSuggested: Bool = false) -> QueueItem {
        var i = QueueItem(
            id: id, groupName: "G", discipline: discipline, venue: "V",
            performanceDate: "2027-01-01", sourceListingURL: nil, websiteURL: nil,
            priorRelationship: "none", production: "unknown", profile: "neutral",
            coverage: "unknown", fitScore: highFit ? 8 : 3,
            tier: highFit ? "high" : "longshot", fitReason: "reason",
            matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
            status: .new)
        i.bookingSuggested = bookingSuggested
        return i
    }

    @Test func noFilterKeepsEverything() {
        let items = [item("a"), item("b", discipline: "opera")]

        let kept = QueueModel.filter(items, discipline: nil, highOnly: false, pendingBookingsOnly: false)

        #expect(kept.count == 2)
    }

    @Test func eachFilterNarrowsAndTheyCompose() {
        let items = [item("a", highFit: true), item("b", discipline: "opera", highFit: true),
                     item("c", highFit: false)]

        #expect(QueueModel.filter(items, discipline: "opera", highOnly: false,
                                  pendingBookingsOnly: false).map(\.id) == ["b"])
        #expect(QueueModel.filter(items, discipline: nil, highOnly: true,
                                  pendingBookingsOnly: false).map(\.id) == ["a", "b"])
        #expect(QueueModel.filter(items, discipline: "choral", highOnly: true,
                                  pendingBookingsOnly: false).map(\.id) == ["a"])
    }

    @Test func thePendingBookingsFilterKeepsOnlyTheSuggestedOnes() {
        let items = [item("a", bookingSuggested: true), item("b")]

        let kept = QueueModel.filter(items, discipline: nil, highOnly: false, pendingBookingsOnly: true)

        #expect(kept.map(\.id) == ["a"])
    }

    // MARK: - The row

    @Test func theFitBadgeSaysWhichSideOfTheLineTheShowIsOn() {
        #expect(QueueModel.fitLabel(isHighFit: true) == "HIGH FIT")
        #expect(QueueModel.fitLabel(isHighFit: false) == "LONG SHOT")
    }

    // Both branches are promises about what the DRAFT will do, which makes them worth a test: one says a
    // returning-client draft is now allowed, the other says it is not yet.
    @Test func thePerformerMatchHelpSaysWhatConfirmingActuallyChanges() {
        #expect(QueueModel.performerMatchHelp(confirmed: true).contains("can write to them as a returning client"))
        #expect(QueueModel.performerMatchHelp(confirmed: false).contains("won't treat them as a returning client until you confirm"))
    }

}
