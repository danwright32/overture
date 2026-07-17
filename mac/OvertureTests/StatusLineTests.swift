import Testing
import Foundation
@testable import Overture

// #1047: the center status slot enforces its own precedence, so an informational write (a Prep
// summary, an OmniFocus receipt, a reply-classify note) can never silently erase an unacknowledged
// scout warning that landed first on the same launch. Pure, so the rule is pinned by a test rather
// than left to drift inside the view (#863).
@Suite("Status line precedence (#1047)")
struct StatusLineTests {
    // The bug this issue exists to fix: the auto scout leaves its quiet warning, then a later
    // informational job overwrites the same slot. The warning must survive.
    @Test func infoDoesNotEraseAPendingWarning() {
        var slot = StatusLine()
        slot.set("3 sources couldn't be checked. Open Sources to fix or confirm them.", priority: .warning)
        let applied = slot.set("Prep: 2 drafted, 1 didn't come back.", priority: .info)
        #expect(applied == false)
        #expect(slot.text == "3 sources couldn't be checked. Open Sources to fix or confirm them.")
        #expect(slot.priority == .warning)
    }

    // #887: the guard must not fail closed. When no warning is pending, an informational line shows.
    @Test func infoShowsWhenNothingIsPending() {
        var slot = StatusLine()
        let applied = slot.set("Prep: 2 drafted.", priority: .info)
        #expect(applied == true)
        #expect(slot.text == "Prep: 2 drafted.")
        #expect(slot.priority == .info)
    }

    // An equal-or-higher priority write still lands: a fresh warning replaces a stale one, so the
    // slot is never permanently stuck on the first warning it ever saw.
    @Test func aFreshWarningReplacesAStaleWarning() {
        var slot = StatusLine()
        slot.set("An established calendar came back empty this run.", priority: .warning)
        let applied = slot.set("2 sources couldn't be checked. Open Sources to fix or confirm them.", priority: .warning)
        #expect(applied == true)
        #expect(slot.text == "2 sources couldn't be checked. Open Sources to fix or confirm them.")
    }

    // A warning may take over the slot from a lower-priority informational line.
    @Test func aWarningReplacesInfo() {
        var slot = StatusLine()
        slot.set("Gmail connected. You can now send approved emails.", priority: .info)
        let applied = slot.set("The scout couldn't save its results. Run it again.", priority: .warning)
        #expect(applied == true)
        #expect(slot.text == "The scout couldn't save its results. Run it again.")
        #expect(slot.priority == .warning)
    }

    // Clearing is the explicit reset (an acknowledgment, not a competing message): it always applies,
    // and afterwards a normal informational line shows again.
    @Test func clearingResetsThenInfoShowsAgain() {
        var slot = StatusLine()
        slot.set("A source couldn't be checked. Open Sources to fix or confirm it.", priority: .warning)
        #expect(slot.set(nil) == true)
        #expect(slot.text == nil)
        #expect(slot.priority == .info)
        #expect(slot.set("Gmail connected. You can now send approved emails.", priority: .info) == true)
        #expect(slot.text == "Gmail connected. You can now send approved emails.")
    }
}
