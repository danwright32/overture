import Testing
import Foundation

// #1587, folded into milestone 32 Phase 2 (#1595). "Is Dan still deciding about this show" was spelled
// out in two places that disagreed, and the disagreement is half the cause of #1585: the reachability
// candidate rule admitted kept shows and ignored whether a run had already opened, while the Scout stage
// list did the opposite. Two homes for one rule is what #1570 cost, so there is one home now and both
// sides call it.
@Suite("OpenForDecision")
struct OpenForDecisionTests {

    private let today = "2026-07-27"

    @Test("an untriaged show whose run has not opened is still open for a decision")
    func untriagedFutureShowIsOpen() {
        #expect(OpenForDecision.isOpen(status: .new, performanceDate: "2026-08-15",
                                       isBooked: false, sentAt: nil, today: today))
    }

    // The arm the reachability rule was missing. A run that has already started is work Dan will not
    // pitch, so the Scout list drops it (#1540) and paying to research it would be money on a show
    // Overture refuses to show him.
    @Test("a run that has already opened is not open for a decision")
    func openedRunIsNotOpen() {
        #expect(OpenForDecision.isOpen(status: .new, performanceDate: "2026-07-01",
                                       isBooked: false, sentAt: nil, today: today) == false)
    }

    // The arm the Scout list was missing. Dropping .queued is deliberate: a kept show is past the
    // keep-or-dismiss moment and Prep is about to find its contact anyway.
    @Test("a kept show is past the decision", arguments: [ReviewStatus.queued, .drafted, .approved])
    func keptShowIsNotOpen(_ status: ReviewStatus) {
        #expect(OpenForDecision.isOpen(status: status, performanceDate: "2026-08-15",
                                       isBooked: false, sentAt: nil, today: today) == false)
    }

    @Test("a dismissed show is not open for a decision")
    func dismissedShowIsNotOpen() {
        #expect(OpenForDecision.isOpen(status: .dismissed, performanceDate: "2026-08-15",
                                       isBooked: false, sentAt: nil, today: today) == false)
    }

    @Test("a booked show is not open for a decision")
    func bookedShowIsNotOpen() {
        #expect(OpenForDecision.isOpen(status: .new, performanceDate: "2026-08-15",
                                       isBooked: true, sentAt: nil, today: today) == false)
    }

    @Test("a show already pitched is not open for a decision")
    func sentShowIsNotOpen() {
        #expect(OpenForDecision.isOpen(status: .new, performanceDate: "2026-08-15",
                                       isBooked: false, sentAt: Date(), today: today) == false)
    }

    // A show with no date cannot be judged against the lead window, and dropping it would hide it from
    // triage entirely. It stays open, matching how the queue already treats an undated row.
    @Test("a show with no date stays open for a decision")
    func undatedShowIsOpen() {
        #expect(OpenForDecision.isOpen(status: .new, performanceDate: nil,
                                       isBooked: false, sentAt: nil, today: today))
    }
}
