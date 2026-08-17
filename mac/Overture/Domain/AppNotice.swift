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
    // #1900: Dan reports that he has run the shoot-history import, so Overture reads the file again.
    // It cannot export his Shoots calendar or run the import for him (it holds no calendar permission
    // and asks for none); without this the line would stand until the next launch even after he had
    // done both. See `title` for why it is phrased as his report rather than as a re-read.
    case recheckShootHistory

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
        // Dan's own words, like "I sent it" and "I turned them down", NOT another "Re-read the ..." in
        // Overture's. The label has to survive being read by someone who has not re-exported anything,
        // and every "Re-read"/"Re-check" wording fails that test: it sits directly beneath a sentence
        // telling him to re-export his calendar and run the import, so its position promises it IS that
        // remedy, while all it can do is read the file already on disk. Pressed before the import, it
        // re-reads the same stale file and reports the same staleness, which is a control that visibly
        // does nothing sitting under the instruction it appears to carry out (L44).
        //
        // What it is genuinely for is the moment AFTER: he has run the import in the terminal and wants
        // the line to clear without relaunching. So the label states the thing only he can know, and the
        // re-read is what Overture does about it. True of a first import and a fourth, which is what
        // lets one label serve the missing state as well as stale and unreadable.
        case .recheckShootHistory: return "I've run the import"
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
    // The half both wordings end on, written once so the two can never drift apart (#843): what Dan
    // loses while this is true is the same either way.
    static let downbeatShootsVanishedStake =
        "so Overture can't keep clear of your booked nights or spot a booking."

    static func downbeatShootsVanished(_ vanished: DownbeatBookingFeed.Vanished) -> AppNotice {
        switch vanished.evidence {
        case .theExportCarriedThemUntil(let lastEndDate):
            let furthest = EasternDate.date(from: lastEndDate)
                .map { EasternDate.dayLabelWithYear($0) } ?? lastEndDate
            return AppNotice(
                text: "Every one of the \(Plural.count(vanished.bookingCount, "shoot")) Downbeat was "
                    + "exporting has gone at once, " + downbeatShootsVanishedStake,
                tone: .warning,
                help: "Shoots leave the export one at a time, as their dates pass, and the furthest of "
                    + "these was not until \(furthest), so all of them going together reads as a broken "
                    + "export rather than an empty diary. Re-export it from Downbeat, then re-read it "
                    + "here.",
                action: .recheckDownbeatExport)
        case .seenBeforeTheirDatesWereKept(let lastNewAt):
            // A weaker claim, in weaker words, because the evidence is weaker (L11). These ids arrived
            // one at a time over months and carry no dates, so this must never say they were being
            // carried together, and must never date them.
            let arrived = EasternDate.dayLabelWithYear(Date(timeIntervalSince1970: lastNewAt))
            return AppNotice(
                text: "Downbeat's export carries no shoots at all, though \(vanished.bookingCount) have "
                    + "come through it before, " + downbeatShootsVanishedStake,
                tone: .warning,
                help: "Overture recorded those before it kept their dates, so it can't say which have "
                    + "already happened. What it can say is that a new shoot came through as recently as "
                    + "\(arrived), and the export now holds none at all. Re-export it from Downbeat, "
                    + "then re-read it here.",
                action: .recheckDownbeatExport)
        }
    }

    // #1900: the shoot history file is missing, unreadable, or months past its window.
    //
    // The verdict has existed since #1895 and reached nobody: `VenueShootHistory.current()` took the
    // shoots out of `loadWithHealth`'s tuple and dropped the health, so the check ran on every prep queue
    // build and nothing displayed any of it (L3, L46). What it costs while silent is invisible by
    // construction: the file is refreshed by a manual export Dan has to remember to redo, so an old one
    // simply under-reports the rooms he has worked, and a pitch that could say he has shot this room
    // before says nothing instead. A stale count and an accurate one look identical.
    //
    // The SENTENCE is `ShootHistory.warningText`'s, not a second wording written here, for the reason
    // ScoutWarnings gives about the strings it carries as-is: one fault must have one wording. Each of
    // the three states keeps its own, because "we could not read it" and "it is old" call for different
    // things from Dan (L11).
    //
    // A warning rather than a receipt in all three states, including `missing`, which the domain type
    // rightly calls a normal state rather than a fault. Normal is not the same as harmless: while it is
    // true, a whole drafting input is empty and nothing else on this screen would ever say so.
    static func shootHistoryWarning(_ health: ShootHistory.Health) -> AppNotice? {
        guard let text = ShootHistory.warningText(for: health) else { return nil }
        return AppNotice(text: text, tone: .warning, action: .recheckShootHistory)
    }

    // #2879: files Overture is reading and cannot read. One line for all of them rather than one each,
    // because they share a cause far more often than not (a run that wrote a shape this build does not
    // know), and because most of these reads happen on a poll, so a line per file per tick would be the
    // surface that gets ignored (L36).
    //
    // The line states what is LOST, not just that a read failed, since the filename alone means nothing
    // to Dan. There is no action: nothing in the app can repair a file written by something else, and a
    // button that cannot do its job is worse than none (L44). The help carries what he can actually look
    // at, which is the file itself and the run log beside it.
    static func couldNotRead(_ failures: [HandoffReadFailures.Failure]) -> AppNotice? {
        guard let first = failures.first else { return nil }
        let text: String
        if failures.count == 1 {
            text = "Overture couldn't read \(first.file), so whatever it held has not been used."
        } else {
            text = "Overture couldn't read \(failures.count) of the files it works from, so whatever "
                + "they held has not been used."
        }
        let detail = failures.map { "\($0.file): \($0.reason)" }.joined(separator: "\n")
        return AppNotice(
            text: text,
            tone: .warning,
            help: "These are files written by something outside the app, a detached run or an install "
                + "script, and they're still on disk in Overture's own folder. Nothing here can repair "
                + "one. A line clears as soon as its file reads cleanly again.\n\n\(detail)")
    }

    // `shootHistory` is OPTIONAL, and nil means nothing has looked yet rather than a clean bill of
    // health. A verdict is a measurement, and defaulting to `.ok` before the read would put the
    // reassuring answer on the one state nobody has checked (L11).
    static func current(omniFocusFailing isFailing: Bool,
                        bookingsVanished: DownbeatBookingFeed.Vanished? = nil,
                        shootHistory: ShootHistory.Health? = nil,
                        unreadableFiles: [HandoffReadFailures.Failure] = [],
                        status: StatusLine) -> [AppNotice] {
        var notices: [AppNotice] = []
        if let bookingsVanished { notices.append(downbeatShootsVanished(bookingsVanished)) }
        if isFailing { notices.append(omniFocusFailing) }
        if let notice = couldNotRead(unreadableFiles) { notices.append(notice) }
        if let shootHistory, let notice = shootHistoryWarning(shootHistory) { notices.append(notice) }
        if let text = status.text {
            notices.append(AppNotice(text: text,
                                     tone: status.priority == .warning ? .warning : .receipt,
                                     action: status.action))
        }
        return notices
    }
}
