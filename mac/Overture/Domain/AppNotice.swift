import Foundation

// #2204: what Overture has to say for itself right now, and how loudly.
//
// These lines used to live in the toolbar's single `ToolbarItem(placement: .status)`. Dan runs Overture
// at about half screen width, and at that width macOS moves that slot into the toolbar's overflow
// chevron, so its message was not on screen at all unless he clicked it. He never has, so he has never
// seen any of them.
//
// That slot is not decoration. It carries the do-not-contact receipt (#802, the guard he specifically
// asked to SEE working), the unattended scout's "N sources couldn't be checked" warning, the
// reply-classify save failure and shortfall notes, and #2104's run-died message. Several of those are
// `.warning` precisely because they report silent degradation on a run he did not watch, and StatusLine's
// whole priority rule exists to stop them being overwritten. Protecting a message from being overwritten
// is worth nothing while the surface showing it is invisible at his normal window size (L79).
//
// Two changes come out of that, and both are about a message being able to lose to something else.
//
// The OmniFocus failure and the status line are SEPARATE notices now, not two branches of one slot. In
// the toolbar the failure won outright and the status line was simply not drawn, which meant an
// unattended scout's warning could be hidden by an unrelated sync problem: the same silent-erasure
// failure StatusLine's priority rule was written to prevent, from outside the rule. A stack of lines has
// room for both, so both show.
//
// And a warning does not look like a receipt. They were one faint grey line in one slot, so "your
// contact guard stopped an email" and "12 sources couldn't be checked" arrived identically.
enum AppNoticeTone: Equatable, Sendable {
    // Something is degraded and Dan may need to act. Drawn in rust, like the possible-match and
    // watch-gap lines it sits beside: not a status, but Overture saying something is wrong.
    case warning
    // A receipt or summary: worth seeing, safe to miss. Faint, like the scouted-freshness line.
    case receipt
}

struct AppNotice: Equatable, Identifiable, Sendable {
    var text: String
    var tone: AppNoticeTone
    // The longer explanation, where one exists. A tooltip is a poor place for anything Dan must read
    // (L49), so this only ever carries detail that expands on a line already saying the actionable part.
    var help: String? = nil

    var id: String { text }
}

enum AppNotices {
    // #239/#306: the automatic OmniFocus sync is failing, so follow-up tasks may not be getting created.
    // Persistent rather than momentary: it stays until a sync succeeds, which is what makes it a notice
    // rather than a receipt.
    static let omniFocusFailing = AppNotice(
        text: "OmniFocus sync failing",
        tone: .warning,
        help: "The automatic OmniFocus sync last failed, so follow-up tasks may not be getting created. "
            + "Click \"Sync to OmniFocus\" to retry, and check that OmniFocus is installed and has "
            + "Automation permission. A successful sync clears this.")

    // Everything the app has to say, in the order it should be read: the standing fault first, then
    // whatever the last run had to report. Never a placeholder and never an empty line, so a quiet app
    // adds no rows to the masthead at all.
    static func current(omniFocusFailing isFailing: Bool, status: StatusLine) -> [AppNotice] {
        var notices: [AppNotice] = []
        if isFailing { notices.append(omniFocusFailing) }
        if let text = status.text {
            notices.append(AppNotice(text: text,
                                     tone: status.priority == .warning ? .warning : .receipt))
        }
        return notices
    }
}
