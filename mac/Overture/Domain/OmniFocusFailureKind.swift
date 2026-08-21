import Foundation

// #2883 / #2884: what an OmniFocus sync failure IS.
//
// The masthead said one sentence for every failure ("OmniFocus sync failing, so follow-up tasks may not
// be getting created") and always offered "Sync now". For a deterministic fault that button re-runs
// identical work against identical state and fails identically, and the line does not change, so from
// Dan's side it looks like it did nothing at all (L148). A durable control that refuses and leaves no
// trace of refusing means pressing it again is the only diagnosis available.
//
// And the real reason was already stored under `omniFocusLastSyncError`, reachable only by reading the
// app's preferences from a terminal. A message that names a fault without naming its cause tells Dan
// something is wrong and gives him nowhere to go (L80).
//
// Classified ONCE here rather than each surface reading the stored message its own way (L35). The line,
// the help and whether a retry is offered all follow from the kind, so they cannot disagree.
enum OmniFocusFailureKind: Equatable, Sendable, CaseIterable {
    /// Overture is not allowed to control OmniFocus. Recorded as its own flag, so this is evidence.
    case permissionNeeded
    /// OmniFocus is not open, so nothing could be asked of it.
    case omniFocusNotRunning
    /// The run got through and OmniFocus refused specific shows (#2882). Deterministic: nothing about
    /// those shows changes on a retry.
    case refusedSomeShows
    /// Something else. NOT a claim that it is transient, only that nothing here established otherwise.
    case unexplained

    /// The permission flag is asked FIRST and outranks the stored text: a denial recorded while an older
    /// message is still stored must not read as that older message.
    ///
    /// Everything else is read off the message, and the fall-through is `unexplained` rather than any
    /// specific kind, because guessing a cause is how a message comes to claim what its check never
    /// measured (L11).
    // copy-inventory:ignore-start  the enum case's own name, as `"\(error)"` renders it. Read, never said.
    static let notRunningMarker = "notRunning"
    // copy-inventory:ignore-end

    static func of(message: String, permissionNeeded: Bool) -> OmniFocusFailureKind {
        if permissionNeeded { return .permissionNeeded }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .unexplained }
        // Keyed off the WRITER's own phrase rather than one retyped here, so the two cannot drift (L26).
        if text.contains(OmniFocusSync.couldNotUpdatePhrase) { return .refusedSomeShows }
        // OUR OWN case name first. The client types this at the source now (#2883), where the AppleScript
        // code is known, so what is stored is `notRunning` rather than whatever wording macOS used. A
        // string is still what reaches here, because the failure is stored as text, but it is a string
        // this codebase produces rather than one it has to interpret (L35).
        if text.contains(notRunningMarker) { return .omniFocusNotRunning }
        // copy-inventory:ignore-start  AppleScript's own wordings, kept only for failures RECORDED BEFORE
        // the case above existed. Not Overture's voice: these are needles read out of a message macOS
        // produced, and listing them as sentences the app can SAY would put fragments nobody wrote into
        // the list Dan cold reads. Not a fallback for a NEW failure, which arrives typed.
        let lowered = text.lowercased()
        if lowered.contains("isn't running") || lowered.contains("is not running")
            || lowered.contains("can't get application") || lowered.contains("-600") {
            return .omniFocusNotRunning
        }
        // copy-inventory:ignore-end
        return .unexplained
    }

    /// Whether pressing "Sync now" could plausibly change the outcome.
    ///
    /// Only the deterministic kind says no. `unexplained` keeps the button, not because a retry will
    /// work, but because nothing established that it cannot, and withholding the one remedy Dan has on a
    /// guess is the worse error of the two.
    var aRetryCouldClearIt: Bool {
        switch self {
        case .refusedSomeShows: return false
        case .permissionNeeded, .omniFocusNotRunning, .unexplained: return true
        }
    }

    /// What the masthead says. `reason` is the stored failure text, used only where it adds something
    /// the kind does not already say.
    func line(reason: String) -> String {
        switch self {
        case .permissionNeeded:
            return "OmniFocus sync is failing because Overture is not allowed to control OmniFocus, so "
                + "follow-up tasks are not being created."
        case .omniFocusNotRunning:
            return "OmniFocus sync is failing because OmniFocus is not open, so follow-up tasks are not "
                + "being created."
        case .refusedSomeShows:
            // The stored reason already names the shows, which is the only part that can be acted on.
            return "\(reason) Those reminders are not there, and running the sync again will not change it."
        case .unexplained:
            return "OmniFocus sync is failing, so follow-up tasks may not be getting created."
        }
    }

    /// What to do about it, kept apart from the line for the reason the old tooltip already was: the line
    /// states the fault, this instructs.
    func help(reason: String) -> String {
        switch self {
        case .permissionNeeded:
            return "Allow Overture to control OmniFocus in System Settings, Privacy and Security, "
                + "Automation. Then sync again."
        case .omniFocusNotRunning:
            return "Open OmniFocus, then sync again."
        case .refusedSomeShows:
            return "OmniFocus refused those shows, and it will refuse them the same way next time. The "
                + "stored reason is: \(reason)"
        case .unexplained:
            return "A sync may clear it. If it does not, the stored reason is: \(reason)"
        }
    }
}
