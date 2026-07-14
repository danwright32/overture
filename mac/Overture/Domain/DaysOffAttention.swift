import Foundation

// #901 part 3: making the absence of booked-shoot data legible.
//
// This is the trap that produced the issue. Dan asked for vacation days on the reasonable belief that
// Overture already knew his booked shoots, because that is what a conflict guard implies. It did not. The
// export has always carried `bookings: []`, no prospect has ever been marked booked, and the guard has not
// fired once in the app's life. Every show it ever showed him was unchecked against his real schedule.
//
// Nothing said so, and nothing WOULD have: `DownbeatExport.health` asks only whether the file exists,
// decodes, and is recent, so a four-day-old export with zero bookings reports `.ok`. Health is about the
// file. This is about what is INSIDE it, which is a different question, and the one that mattered.
//
// So it gets its own verdict, and Dan sees it on the toolbar rather than only inside a sheet he has no
// reason to open (the #805 lesson, in the same words: a symptom only a man already looking for it can find
// is not a symptom).
enum DaysOffAttention {

    // Overture holds no booked shoots at all, so the only days it can protect are the ones Dan types in.
    // His own days off deliberately do NOT clear this: a vacation says nothing about the shoots he has
    // taken, and treating it as coverage would hide the gap the moment he blocked his first week.
    static func needsALook(_ calendar: BlockedCalendar) -> Bool {
        !calendar.hasBookedShootData
    }

    static func badgeTitle(needsALook: Bool) -> String {
        needsALook ? "Days off (no shoots)" : "Days off"
    }

    static func help(needsALook: Bool) -> String {
        guard needsALook else {
            return "The days Overture won't pitch you for: your booked shoots, and the days you block."
        }
        // The consequence, not just the fact: what he can do about it is block the days himself.
        return "Overture has no booked shoots from Downbeat, so it can't keep clear of them. Block those days here."
    }

    // The sentence in the sheet itself, where the promise is made. An empty list with no explanation reads
    // as "you have no shoots booked", which is a different claim, and a false one.
    static let noBookedShootsExplanation =
        "Overture has no booked shoots from Downbeat, so the only days it knows about are the ones you add here. Downbeat only records shoots booked through it, from now on, and a shoot booked outside it never appears at all."
}
