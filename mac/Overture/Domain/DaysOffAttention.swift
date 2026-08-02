import Foundation

// #901 / #925: making the absence of booked-shoot data legible, and letting Dan put it away.
//
// This is the trap that produced #901. Dan asked for vacation days on the reasonable belief that Overture
// already knew his booked shoots, because that is what a conflict guard implies. It did not. The export
// has always carried `bookings: []`, no prospect has ever been marked booked, and the guard has not fired
// once in the app's life. Every show it ever showed him was unchecked against his real schedule.
//
// Nothing said so, and nothing WOULD have: `DownbeatExport.health` asks only whether the file exists,
// decodes, and is recent, so a four-day-old export with zero bookings reports `.ok`. Health is about the
// file. This is about what is INSIDE it, which is a different question, and the one that mattered.
//
// #925 corrected it twice over, both from Dan:
//
//   It asks about UPCOMING shoots. It used to ask whether Downbeat had EVER exported a booking, and
//   Downbeat exports every committed booking it has ever held, so one shoot booked in March turned the
//   warning off forever, including in September when that shoot was long past and he was again protected
//   by nothing. A past shoot proves the pipe once worked. It proves nothing about now.
//
//   And he can put it away, for a week at a time. A warning with no honest answer to it is a warning that
//   gets ignored, and an ignored warning is worse than none: he would learn to read past the one thing on
//   the toolbar that is telling him the truth.
enum DaysOffAttention {

    static let snoozeKey = "daysOffNoShootsSnoozedUntil"
    static let snoozeDuration: TimeInterval = 7 * 86_400

    // Overture knows of no shoot from today onward, so it cannot keep clear of Dan's real schedule, and
    // he has not told it to be quiet about that this week.
    //
    // The snooze hides a WARNING, never a fact: a genuine upcoming shoot silences this on its own merits,
    // so a stale snooze sitting underneath one changes nothing and cannot mask a later gap.
    // #1456: the mark now covers two ways Overture's picture of Dan's schedule can be off, not one. Both
    // show the same quiet "Days off" toolbar word (#1430); the sentence that explains which one lives in the
    // help and the sheet, which have room.
    enum Reason: Equatable, Sendable {
        case none
        case noUpcomingShoots   // #901/#925: Downbeat has handed over nothing upcoming to keep clear of.
        case feedStalled        // #1456: it HAS upcoming shoots, but no new one has appeared in a long while.
    }

    // The no-shoots case wins when both could apply: it is the more fundamental "Overture is blind" state,
    // and it is the one with a direct action (block the days yourself). The stalled-feed nudge is only
    // meaningful while there ARE upcoming shoots. The snooze silences the whole mark for a week.
    // #1960: the calendar is an @autoclosure because the snooze guard below refuses without reading it,
    // and an argument is evaluated BEFORE the call. Building one reads and decodes the Downbeat export
    // and fetches the stored days off, so a snoozed mark was paying for a calendar it then ignored.
    static func reason(_ calendar: @autoclosure () -> BlockedCalendar, feedStalled: Bool = false,
                       today: String = QueueModel.easternToday(), now: Date = Date(),
                       defaults: UserDefaults = .standard) -> Reason {
        guard !isSnoozed(now: now, defaults: defaults) else { return .none }
        if !calendar().hasUpcomingBookedShoot(today: today) { return .noUpcomingShoots }
        return feedStalled ? .feedStalled : .none
    }

    static func needsALook(_ calendar: @autoclosure () -> BlockedCalendar, feedStalled: Bool = false,
                           today: String = QueueModel.easternToday(),
                           now: Date = Date(),
                           defaults: UserDefaults = .standard) -> Bool {
        reason(calendar(), feedStalled: feedStalled, today: today, now: now, defaults: defaults) != .none
    }

    static func isSnoozed(now: Date, defaults: UserDefaults = .standard) -> Bool {
        let until = defaults.double(forKey: snoozeKey)
        guard until > 0 else { return false }
        return now.timeIntervalSince1970 < until
    }

    // Each dismissal buys a fresh week from the moment he pressed it, rather than counting from the first
    // time he ever dismissed it, which would make the second press do nothing at all.
    static func snooze(now: Date, into defaults: UserDefaults = .standard) {
        defaults.set(now.addingTimeInterval(snoozeDuration).timeIntervalSince1970, forKey: snoozeKey)
    }

    // #1430: it used to read "Days off (no shoots)" in the app's gold attention colour, and Dan read the
    // whole thing as an alarm: "this is too urgent. Not having any days off isn't a bad thing."
    //
    // He was right on both counts. Neither "you have no days off" nor "you have no shoots" is a problem,
    // and this state is neither of those things: it is that Downbeat has handed Overture nothing upcoming,
    // so there is nothing for it to keep clear of. The toolbar now says the same two words whatever the
    // state, and the difference is carried by the icon's colour alone (RootView). Dan's second call,
    // 2026-07-24: no words unless something is wrong, and this is not wrong.
    //
    // The MARK stays, though, because this is the only thing in the app watching for a dry pipe:
    // DownbeatExport.health asks whether the file exists, parses, and is recent, so a fresh export holding
    // zero upcoming bookings reports .ok. That is the #901 trap exactly, and it cost Dan his evenings twice.
    // The sentence explaining it lives in `help` and in the sheet, which have room to say it properly; a
    // toolbar has room only to be noticed.
    static func badgeTitle(_ reason: Reason) -> String { "Days off" }

    static func help(_ reason: Reason) -> String {
        switch reason {
        case .none:
            return "The days Overture won't pitch you for: your booked shoots, and the days you block."
        case .noUpcomingShoots:
            // The consequence, not just the fact: what he can do about it is block the days himself.
            return "Overture knows of no upcoming shoots from Downbeat, so it can't keep clear of them. Block those days here."
        case .feedStalled:
            return "No new shoots have come through from Downbeat in the last four weeks. If you've booked one, check that Downbeat is still exporting to Overture."
        }
    }

    // The sentence in the sheet itself, where the promise is made. An empty list with no explanation reads
    // as "you have no shoots booked", which is a different claim, and a false one.
    //
    // Dan uses Downbeat for everything (2026-07-14), so this does NOT hedge about shoots booked outside
    // Downbeat: to him that is a case that never happens, and warning about it is noise that buries the
    // one thing he needs to know, which is that Downbeat has handed over nothing upcoming.
    static let noBookedShootsExplanation =
        "Overture knows of no upcoming shoots from Downbeat, so the only days it keeps clear are the ones you add here."

    // #1456: the stalled-feed sentence in the sheet. It carries the reassurance the toolbar has no room for,
    // because this is a soft nudge, not an error: a broken export and a genuinely quiet booking spell look
    // identical from the data, so it must not accuse the feed of being broken when Dan simply hasn't booked.
    static let feedStalledExplanation =
        "No new shoots have come through from Downbeat in the last four weeks. If you simply haven't booked, nothing is wrong; if you have, check that Downbeat is still exporting to Overture."

    static let snoozeButtonTitle = "Hide this for a week"
}
