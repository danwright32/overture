import Testing
import Foundation
@testable import Overture

// #285: a manual "Run reconcile now" must never look like it did nothing. The reconcile returns a
// summary whose message acknowledges the run even when nothing changed, so the menu action always has
// visible feedback (Dan's no-silent-no-op rule).
@Suite("Reconcile summary (#285)")
struct ReconcileSummaryTests {
    @Test func emptyRunStillAcknowledgesItself() {
        let m = ReconcileSummary(omniFocusChanged: 0).message
        #expect(m.contains("nothing was due"))
    }

    // #297: bookings are named on the manual ack too, matching the while-away alert.
    @Test func reportsNewBookingsByName() {
        let m = ReconcileSummary(omniFocusChanged: 0,
                                 newBookings: ["Joe's Pub", "The Knights"]).message
        #expect(m.contains("2 new bookings (Joe's Pub, The Knights)"))
        #expect(!m.contains("nothing was due"))
    }

    @Test func reportsFollowUpUpdates() {
        let m = ReconcileSummary(omniFocusChanged: 3).message
        #expect(m.contains("3"))
        #expect(m.lowercased().contains("follow-up"))
    }

    @Test func reportsBothWhenBothChanged() {
        let m = ReconcileSummary(omniFocusChanged: 2, newBookings: ["Carnegie Hall"]).message
        #expect(m.contains("1 new booking (Carnegie Hall)"))
        #expect(m.contains("2"))
        #expect(!m.contains("nothing was due"))
    }

    // #287: a reply found this pass must be acknowledged too, so a reply-only run never reads as
    // "nothing was due".
    @Test func reportsASingleNewReplyAndNamesTheOrg() {
        let m = ReconcileSummary(omniFocusChanged: 0, newReplies: ["Carnegie Hall"]).message
        #expect(m.contains("1 new reply (Carnegie Hall)"))
        #expect(!m.contains("nothing was due"))
    }

    @Test func pluralizesCountsAndNamesSeveralReplies() {
        let m = ReconcileSummary(omniFocusChanged: 0,
                                 newReplies: ["Carnegie Hall", "Joe's Pub"]).message
        #expect(m.contains("2 new replies (Carnegie Hall, Joe's Pub)"))
        #expect(!m.contains("nothing was due"))
    }

    @Test func reportsRepliesAlongsideBookingsAndFollowUps() {
        let m = ReconcileSummary(omniFocusChanged: 2,
                                 newReplies: ["Carnegie Hall"], newBookings: ["Joe's Pub"]).message
        #expect(m.contains("1 new reply (Carnegie Hall)"))
        #expect(m.contains("1 new booking (Joe's Pub)"))
        #expect(m.contains("follow-up"))
        #expect(!m.contains("nothing was due"))
    }
}
