import Foundation

// #1047: the app's single center status slot (the masthead line beside the toolbar) is written by
// several launch-time jobs that finish minutes apart, in an order the app does not control: an
// unattended scout leaves its quiet warning ("N sources couldn't be checked"), then a Prep summary,
// an OmniFocus receipt, or a reply-classify note can land AFTER it and silently erase it. That warning
// is the ONE signal that surfaces a silently degraded run Dan never watched, so losing it to a routine
// receipt defeats its whole purpose.
//
// The fix is a priority the slot itself enforces, kept pure so the rule is tested rather than buried in
// the view (#863: logic that lived in a view drifted twice under a green suite). A warning is never
// overwritten by a lower-priority informational write; an equal-or-higher write still lands (a fresh
// warning replaces a stale one), and when nothing is pending an informational line shows normally
// (#887: never a guard that fails closed and hides legitimate info in the common case).
enum StatusPriority: Int, Comparable, Sendable {
    case info = 0        // a receipt or summary: useful to see, safe to lose
    case warning = 1     // silent degradation on a run Dan did not watch; must not be erased by info

    static func < (lhs: StatusPriority, rhs: StatusPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct StatusLine: Equatable, Sendable {
    private(set) var text: String?
    private(set) var priority: StatusPriority = .info

    // The one rule every writer of the status slot goes through. Returns whether the write was applied,
    // so a caller (or a test) can tell a refused informational write apart from one that landed.
    @discardableResult
    mutating func set(_ newText: String?, priority newPriority: StatusPriority = .info) -> Bool {
        // Clearing is always allowed: it is the explicit reset/acknowledgment, not a competing message.
        guard let newText else {
            text = nil
            priority = .info
            return true
        }
        // Refuse ONLY a strictly lower-priority write over a message already showing: informational copy
        // must never silently erase a pending warning. Equal-or-higher always applies, so a fresh warning
        // still lands and, when nothing is pending, an informational line shows normally (#887).
        if text != nil && newPriority < priority { return false }
        text = newText
        priority = newPriority
        return true
    }
}
