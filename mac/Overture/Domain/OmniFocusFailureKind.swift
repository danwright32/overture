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
    /// #3419: the tick stopped WAITING for OmniFocus. Distinct from every kind below it because the
    /// sync was neither refused nor completed: the Apple event was sent and no answer came back inside
    /// the deadline, so nothing is known about what OmniFocus did with it.
    case didNotAnswer
    /// #3419: an earlier tick is still out, so this one was never submitted. Not a fault of this tick
    /// at all, and reading it as one would report a queue that is working exactly as designed as a
    /// failure of the thing it is protecting.
    case stillRunning
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
    // #3419: the two waiting outcomes, typed at the point that knows which one happened rather than
    // re-derived downstream from a message substring (L35). Deliberately NOT the raw
    // `"\(BlockingWorkError.busy)"`, which is the word "busy": a word that common can appear in an
    // AppleScript failure macOS wrote, and a classifier keyed on it would put somebody else's message
    // in this bucket.
    static let didNotAnswerMarker = "overtureOmniFocusDidNotAnswer"
    static let stillRunningMarker = "overtureOmniFocusStillRunning"
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
        // #3419: asked before the AppleScript wordings below, for the same reason `notRunningMarker` is:
        // these are tokens this codebase wrote, so they are evidence rather than interpretation.
        if text.contains(didNotAnswerMarker) { return .didNotAnswer }
        if text.contains(stillRunningMarker) { return .stillRunning }
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

    /// #3419: what a thrown error is RECORDED as. One derivation, because both sync paths catch the
    /// same errors and a second copy of this switch in the other one is how two call sites come to
    /// classify the same failure differently (L263).
    static func storedMessage(for error: Error) -> String {
        guard let waiting = error as? BlockingWorkError else { return "\(error)" }
        switch waiting {
        case .timedOut: return didNotAnswerMarker
        case .busy: return stillRunningMarker
        }
    }

    /// #3419: what a FORCED sync says in its own alert. The stored message is a marker for the two
    /// waiting kinds, so reporting it the ordinary way would show Dan a token nobody wrote. Every
    /// other error keeps the wording it had, so this narrows one case rather than rewording them all.
    static func reportedSentence(for error: Error) -> String {
        let stored = storedMessage(for: error)
        let kind = of(message: stored, permissionNeeded: false)
        switch kind {
        case .didNotAnswer, .stillRunning: return kind.line(reason: stored)
        case .permissionNeeded, .omniFocusNotRunning, .refusedSomeShows, .unexplained:
            return OmniFocusSync.failureMessage(reason: stored)
        }
    }

    /// Whether pressing "Sync now" could plausibly change the outcome.
    ///
    /// Only the deterministic kind says no. `unexplained` keeps the button, not because a retry will
    /// work, but because nothing established that it cannot, and withholding the one remedy Dan has on a
    /// guess is the worse error of the two.
    var aRetryCouldClearIt: Bool {
        switch self {
        case .refusedSomeShows: return false
        // #3419: `stillRunning` keeps the button on purpose. The outstanding sync may well have come
        // back between the tick that was refused and Dan reading the masthead, in which case a press
        // works; withholding the one remedy he has on a guess is the worse error (L109).
        case .permissionNeeded, .omniFocusNotRunning, .didNotAnswer, .stillRunning, .unexplained:
            return true
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
        case .didNotAnswer:
            return "OmniFocus did not answer the last sync, so follow-up tasks may not be up to date."
        case .stillRunning:
            return "OmniFocus has not finished the previous sync, so this one was skipped."
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
        case .didNotAnswer:
            // No stored reason here, and that is the point: the marker is a token for the classifier,
            // and the deadline passing establishes nothing about what OmniFocus was doing.
            return "OmniFocus may be busy rebuilding or syncing. Check it is responding, then sync again."
        case .stillRunning:
            return "Wait for the previous sync to finish, then sync again."
        case .unexplained:
            return "A sync may clear it. If it does not, the stored reason is: \(reason)"
        }
    }
}
