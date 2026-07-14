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
    static func needsALook(_ calendar: BlockedCalendar,
                           today: String = QueueModel.easternToday(),
                           now: Date = Date(),
                           defaults: UserDefaults = .standard) -> Bool {
        guard !calendar.hasUpcomingBookedShoot(today: today) else { return false }
        return !isSnoozed(now: now, defaults: defaults)
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

    static func badgeTitle(needsALook: Bool) -> String {
        needsALook ? "Days off (no shoots)" : "Days off"
    }

    static func help(needsALook: Bool) -> String {
        guard needsALook else {
            return "The days Overture won't pitch you for: your booked shoots, and the days you block."
        }
        // The consequence, not just the fact: what he can do about it is block the days himself.
        return "Overture knows of no upcoming shoots from Downbeat, so it can't keep clear of them. Block those days here."
    }

    // The sentence in the sheet itself, where the promise is made. An empty list with no explanation reads
    // as "you have no shoots booked", which is a different claim, and a false one.
    static let noBookedShootsExplanation =
        "Overture knows of no upcoming shoots from Downbeat, so the only days it keeps clear are the ones you add here. Downbeat only records shoots booked through it, and a shoot booked outside it never appears at all."

    static let snoozeButtonTitle = "Hide this for a week"
}
