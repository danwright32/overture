import Testing
import Foundation

// #269 / Phase 5: when a reconcile detects new replies or new bookings while Dan is away, it posts one
// coalesced notification naming them — not silence, and not one per item. The message builder and the
// before/after diff that finds what's NEW this tick are pure and tested; delivery goes through the
// NotificationService shim (#289). Reply/booking detection itself is covered by GmailReplyChecker /
// DownbeatBooking tests.
@Suite("Away alert (#269)")
struct AwayAlertTests {
    @Test func nothingNewProducesNoMessage() {
        #expect(AwayAlert.message(newReplies: [], newBookings: []) == nil)
    }

    @Test func oneReplyNamesIt() {
        let m = AwayAlert.message(newReplies: ["Aurora Strings"], newBookings: [])
        #expect(m?.contains("1 new reply") == true)
        #expect(m?.contains("Aurora Strings") == true)
    }

    @Test func severalRepliesArePluralizedAndCounted() {
        let m = AwayAlert.message(newReplies: ["Aurora Strings", "The Knights"], newBookings: [])
        #expect(m?.contains("2 new replies") == true)
    }

    @Test func oneBookingNamesIt() {
        let m = AwayAlert.message(newReplies: [], newBookings: ["Carnegie Hall"])
        #expect(m?.contains("1 new booking") == true)
        #expect(m?.contains("Carnegie Hall") == true)
    }

    @Test func bothRepliesAndBookingsAreReported() {
        let m = AwayAlert.message(newReplies: ["Aurora Strings"], newBookings: ["Carnegie Hall"])
        #expect(m?.contains("new reply") == true)
        #expect(m?.contains("new booking") == true)
    }

    private struct Show: Equatable { let id: Int; let key: String; let name: String }

    // #301: the diff returns the whole show, so the names and the deep link keys come from one list and
    // stay aligned.
    @Test func diffReturnsOnlyItemsNotPresentBefore() {
        let after = [Show(id: 1, key: "a|2026|v", name: "Old"), Show(id: 2, key: "b|2026|v", name: "New One")]
        let fresh = AwayAlert.newShows(before: [1], after: after, id: \.id)
        #expect(fresh == [Show(id: 2, key: "b|2026|v", name: "New One")])
    }

    // #4417: the diff is by identity. A show whose key moved since the snapshot (a scout landing re-keyed
    // it) is the same show, and a new show that happens to hold a key the snapshot had is still new.
    @Test func diffComparesIdentityNotKey() {
        let after = [Show(id: 1, key: "a|2026-09-11|v", name: "Re-keyed"), Show(id: 2, key: "a|2026-09-29|v", name: "New")]
        #expect(AwayAlert.newShows(before: [1], after: after, id: \.id).map(\.name) == ["New"])
    }
}
