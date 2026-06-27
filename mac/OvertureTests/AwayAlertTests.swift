import Testing
import Foundation
@testable import Overture

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

    @Test func diffReturnsOnlyItemsNotPresentBefore() {
        let before: Set<String> = ["a|2026|v"]
        let after = [(key: "a|2026|v", name: "Old"), (key: "b|2026|v", name: "New One")]
        let fresh = AwayAlert.newNames(before: before, after: after)
        #expect(fresh == ["New One"])
    }

    // #301: the same diff exposes the natural KEYS of the new leads, so the away alert can deep-link
    // to one. Order matches newNames so a name and its key align.
    @Test func newKeysReturnsKeysNotPresentBefore() {
        let before: Set<String> = ["a|2026|v"]
        let after = [(key: "a|2026|v", name: "Old"), (key: "b|2026|v", name: "New One")]
        #expect(AwayAlert.newKeys(before: before, after: after) == ["b|2026|v"])
    }
}
