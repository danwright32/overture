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

// #2250: what a notice offers to DO about what it says.
//
// Named by the domain and performed by the view. A closure here would make a notice neither Equatable nor
// Sendable, and the masthead diffs these values on every write; a named case keeps the notice a plain
// value a test can read and leaves the view holding the how.
//
// This exists because no message on this surface could carry an action at all. That is L80 (a message
// identifying a specific fault must carry the action for it) and it is why the OmniFocus failure hid its
// remedy in a tooltip nobody hovers, and why #1805's shortfall report can name a set of shows and offer
// nothing to do with them.
enum AppNoticeAction: Equatable, Sendable {
    case retryOmniFocusSync
    // #1805: a paid check came home short. The report names how many shows never got an answer, and this
    // is the offer to finish exactly those, rather than leaving Dan to work out which dates they sit on
    // and re-select them by hand while the app holds the list.
    case finishShowsACheckMissed
    // #2478: re-read Downbeat's export now, so the line reporting a broken one clears the moment a good
    // one lands rather than waiting for the next reconcile tick.
    case recheckDownbeatExport

    // What the control says. Short, because it sits at the end of a sentence that has just said what is
    // wrong, and repeating that would be the same thing twice (#843).
    var title: String {
        switch self {
        case .retryOmniFocusSync: return "Sync now"
        // Deliberately not "Re-export": Overture cannot make Downbeat export anything, it can only read
        // the file again. The remedy that IS Dan's is in the sentence's tooltip, where it belongs.
        // And deliberately not "Check again", which is already a control in this app: the one on an
        // answered show's card, which spends a lookup researching its contacts (ReachabilityCopy). Two
        // buttons reading the same and doing different things, one of them paid, is worse than a longer
        // label (#843).
        case .recheckDownbeatExport: return "Re-read the export"
        // Deliberately not "Retry". A Prep run's shortfall genuinely re-queues itself, and this does not:
        // it starts a new paid run over a set of shows, through the same confirmation as any other check.
        case .finishShowsACheckMissed: return "Check the rest"
        }
    }
}

struct AppNotice: Equatable, Identifiable, Sendable {
    var text: String
    var tone: AppNoticeTone
    // The longer explanation, where one exists. A tooltip is a poor place for anything Dan must read
    // (L49), so this only ever carries detail that expands on a line already saying the actionable part.
    var help: String? = nil
    // #2250: the control this line offers, where it offers one. Absent on a receipt, so a quiet message
    // never grows a button.
    var action: AppNoticeAction? = nil

    var id: String { text }
}

enum AppNotices {
    // #239/#306: the automatic OmniFocus sync is failing, so follow-up tasks may not be getting created.
    // Persistent rather than momentary: it stays until a sync succeeds, which is what makes it a notice
    // rather than a receipt.
    // #2250: the line now says what is at stake and carries the retry beside it. The remedy used to live
    // entirely in the tooltip, so the screen named a fault and hid its fix behind a hover (L49, L80), and
    // follow-up tasks could be silently going uncreated the whole time.
    //
    // What stays in the tooltip is the part that EXPLAINS rather than instructs: the retry is the control,
    // and the permission check is what to look at if the retry does not clear it.
    static let omniFocusFailing = AppNotice(
        text: "OmniFocus sync failing, so follow-up tasks may not be getting created.",
        tone: .warning,
        help: "If a sync doesn't clear this, check that OmniFocus is installed and has Automation "
            + "permission. A successful sync clears it.",
        action: .retryOmniFocusSync)

    // #1805: an offer nothing can serve is not shown. Whether a shortfall report still has shows left to
    // finish depends on the queue's rows, which the writer of that report does not have, so the decision
    // is made where the rows are and applied here. The SENTENCE always stays: what the run did is still
    // true and still worth reading; only the control goes, because a control that cannot do its job is
    // worse than none at all (L44).
    //
    // Scoped to that one action by name, so this can never quietly disarm an unrelated control.
    static func servable(_ notices: [AppNotice], canFinishMissedShows: Bool) -> [AppNotice] {
        guard !canFinishMissedShows else { return notices }
        return notices.map { notice in
            guard notice.action == .finishShowsACheckMissed else { return notice }
            var stripped = notice
            stripped.action = nil
            return stripped
        }
    }

    // Everything the app has to say, in the order it should be read: the standing fault first, then
    // whatever the last run had to report. Never a placeholder and never an empty line, so a quiet app
    // adds no rows to the masthead at all.
    // #2478: Downbeat's export has lost every shoot it was carrying. A warning, and a standing one: it
    // stays until an export arrives with shoots in it again, because for as long as it is true, three
    // features are doing nothing and saying nothing about it.
    //
    // The line states the EVIDENCE (how many went, and that they went together), not just that something
    // is wrong, because that is the one thing that tells Dan in a single read whether he is looking at his
    // own diary or at a broken export. The tooltip carries the part that explains rather than instructs:
    // why all of them going at once is read as a break, dated by the furthest night, and the half of the
    // remedy Overture cannot perform.
    static func downbeatShootsVanished(_ vanished: DownbeatBookingFeed.Vanished) -> AppNotice {
        let furthest = EasternDate.date(from: vanished.lastEndDate)
            .map { EasternDate.dayLabelWithYear($0) } ?? vanished.lastEndDate
        return AppNotice(
            text: "Every one of the \(Plural.count(vanished.bookingCount, "shoot")) Downbeat was exporting "
                + "has gone at once, so Overture can't keep clear of your booked nights or spot a booking.",
            tone: .warning,
            help: "Shoots leave the export one at a time, as their dates pass, and the furthest of these "
                + "was not until \(furthest), so all of them going together reads as a broken export "
                + "rather than an empty diary. Re-export it from Downbeat, then re-read it here.",
            action: .recheckDownbeatExport)
    }

    static func current(omniFocusFailing isFailing: Bool,
                        bookingsVanished: DownbeatBookingFeed.Vanished? = nil,
                        status: StatusLine) -> [AppNotice] {
        var notices: [AppNotice] = []
        if let bookingsVanished { notices.append(downbeatShootsVanished(bookingsVanished)) }
        if isFailing { notices.append(omniFocusFailing) }
        if let text = status.text {
            notices.append(AppNotice(text: text,
                                     tone: status.priority == .warning ? .warning : .receipt,
                                     action: status.action))
        }
        return notices
    }
}
