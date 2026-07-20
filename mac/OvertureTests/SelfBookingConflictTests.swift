import Testing
import Foundation
@testable import Overture

@Suite("Self double-booking conflict (#1219)")
struct SelfBookingConflictTests {
    private func show(_ key: String, _ date: String?, emailed: Bool = false, drafted: Bool = false,
                      engagement: String? = nil) -> SelfBookingConflict.Show {
        SelfBookingConflict.Show(key: key, date: date, emailed: emailed, drafted: drafted, engagementKey: engagement)
    }

    // An already-EMAILED different show on the same date is the STRONG conflict (blocks prep and send).
    @Test func anEmailedShowOnTheSameDateIsAStrongConflict() {
        let target = show("b", "2026-08-01")
        let others = [show("a", "2026-08-01", emailed: true)]
        #expect(SelfBookingConflict.conflict(for: target, among: others + [target]) == .emailed)
    }

    // A DRAFTED-but-not-emailed different show on the same date is the SOFT conflict (a note, no block).
    @Test func aDraftedShowOnTheSameDateIsASoftConflict() {
        let target = show("b", "2026-08-01")
        let others = [show("a", "2026-08-01", drafted: true)]
        #expect(SelfBookingConflict.conflict(for: target, among: others + [target]) == .drafted)
    }

    // Emailed outranks drafted when both share the date: the strongest wins.
    @Test func emailedOutranksDraftedOnTheSameDate() {
        let target = show("c", "2026-08-01")
        let others = [show("a", "2026-08-01", drafted: true), show("b", "2026-08-01", emailed: true)]
        #expect(SelfBookingConflict.conflict(for: target, among: others + [target]) == .emailed)
    }

    // No other pitched show on that date means no conflict.
    @Test func noOtherPitchedShowOnTheDateIsNil() {
        let target = show("b", "2026-08-01")
        let others = [show("a", "2026-08-02", emailed: true),   // different date
                      show("c", "2026-08-01")]                   // same date but neither emailed nor drafted
        #expect(SelfBookingConflict.conflict(for: target, among: others + [target]) == nil)
    }

    // A show never conflicts with itself, even once it is emailed.
    @Test func aShowDoesNotConflictWithItself() {
        let target = show("a", "2026-08-01", emailed: true)
        #expect(SelfBookingConflict.conflict(for: target, among: [target]) == nil)
    }

    // Exact date only: a show a day apart does not conflict (no run-span expansion, #1219 decision 3).
    @Test func aDifferentDateDoesNotConflict() {
        let target = show("b", "2026-08-01")
        let others = [show("a", "2026-08-02", emailed: true)]
        #expect(SelfBookingConflict.conflict(for: target, among: others + [target]) == nil)
    }

    // Two rows of the SAME linked production (a run touring venues) are one show, not a double-booking,
    // so a shared engagement key on the same date does not conflict.
    @Test func theSameLinkedProductionIsNotADoubleBooking() {
        let target = show("b", "2026-08-01", engagement: "run-1")
        let others = [show("a", "2026-08-01", emailed: true, engagement: "run-1")]
        #expect(SelfBookingConflict.conflict(for: target, among: others + [target]) == nil)
    }

    // A show with no date can't collide with anything.
    @Test func aShowWithNoDateNeverConflicts() {
        let target = show("b", nil)
        let others = [show("a", "2026-08-01", emailed: true)]
        #expect(SelfBookingConflict.conflict(for: target, among: others + [target]) == nil)
    }
}
