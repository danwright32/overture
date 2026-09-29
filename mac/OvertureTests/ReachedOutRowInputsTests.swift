import Testing
import Foundation
import SwiftUI

// #4320: what decides whether a Reached out row redraws. The row is `.equatable()` on these inputs, so an
// input missing from the equality is a row that goes stale on it (L14) and an input that moves on every
// evaluation is a row that redraws for nothing, which is the cost the issue measured. Each field is moved
// alone here and must make the inputs unequal; the clock inside one minute must not.
@MainActor
@Suite("A Reached out row's redraw inputs move only with what it draws (#4320)")
struct ReachedOutRowInputsTests {
    private final class Thing {}
    private let show = Thing(), contact = Thing(), other = Thing()
    private let next = Date(timeIntervalSinceReferenceDate: 800_000_000)
    // The start of a minute, so "inside the minute" and "the next minute" are both pinned (L130).
    private let minute = Date(timeIntervalSinceReferenceDate: 60 * 13_000_000)

    private func inputs(show: AnyObject? = nil, contact: AnyObject? = nil, next: Date? = nil, now: Date? = nil,
                        calendars: [String: String] = ["src-a": "https://a.example/calendar"]) -> ReachedOutRowInputs {
        ReachedOutRowInputs(show: ObjectIdentifier(show ?? self.show), contact: ObjectIdentifier(contact ?? self.contact),
                            next: next ?? self.next, now: now ?? minute, sourceCalendars: calendars)
    }

    @Test func theSameRowInsideOneMinuteIsUnchanged() {
        #expect(inputs() == inputs(now: minute.addingTimeInterval(59)),
                "two passes seconds apart would redraw every row for a label that cannot have changed")
    }

    @Test func everyInputMovesTheRowOnItsOwn() {
        let base = inputs()
        #expect(base != inputs(now: minute.addingTimeInterval(60)), "the clock crossed a minute and the row kept its old time")
        #expect(base != inputs(show: other), "a different show object and the row kept the old one")
        #expect(base != inputs(contact: other), "a different contact object and the row kept the old one")
        #expect(base != inputs(next: next.addingTimeInterval(86_400)), "the reach out date moved and the row kept it")
        #expect(base != inputs(calendars: [:]), "the calendar table changed and the row's source link kept the old one")
    }

    @Test func theWrapperComparesTheInputsAndNothingElse() {
        let state = SendProgressState()
        func row(_ key: String, _ i: ReachedOutRowInputs) -> ReachedOutSendAwareRow<EmptyView> {
            ReachedOutSendAwareRow(sendState: state, key: key, redrawsOn: i) { _, _, _ in EmptyView() }
        }
        #expect(row("a", inputs()) == row("a", inputs()), "two fresh closures over the same inputs must compare equal")
        #expect(row("a", inputs()) != row("b", inputs()))
        #expect(row("a", inputs()) != row("a", inputs(contact: other)))
        #expect(row("a", inputs()) != ReachedOutSendAwareRow(sendState: SendProgressState(), key: "a",
                                                             redrawsOn: inputs()) { _, _, _ in EmptyView() })
    }
}
