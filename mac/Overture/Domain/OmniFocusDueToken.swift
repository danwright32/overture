import Foundation

// #3422: the due instant as it is written into an OmniFocus task's note, and read back out.
//
// It used to be a bare Eastern day (`Due: 2026-08-31`), rebuilt by the client at a hardcoded 6:00 PM.
// That held only while every due WAS 6:00 PM. Once a reply triage due varies with the hour the reply
// arrived, a day-only token can never compare equal to the instant it stands for, so `reconcile`
// would call every task stale on every pass, complete it and recreate it, for ever, with nothing
// anywhere reporting it. OmniFocus would simply churn.
//
// ONE definition, used by the writer (`OmniFocusSync.note`), by the reader
// (`AppleScriptOmniFocusClient.parseExistingTasks`) and by the AppleScript that matches a task for
// completion (`completionMatchClause`). Three separate spellings of the same instant is how a round
// trip comes to disagree with itself (L26).
//
// copy-inventory:ignore-start  a token written into an OmniFocus note, read by this parser, never by Dan
enum OmniFocusDueToken {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = EasternDate.timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.isLenient = false
        return f
    }()

    static func string(from date: Date) -> String {
        formatter.string(from: date)
    }

    // Reads the current shape, and the LEGACY day-only shape that Dan's OmniFocus is full of right
    // now, at the fixed hour those tasks were actually written with. A legacy task then compares as
    // stale against its new deadline and is completed and recreated once, on the first sync after
    // this ships, on the same precedent as #653's legacy recipient id transition.
    //
    // Anything else is nil rather than a guess: a token that parsed whatever it was handed would turn
    // a corrupted note into a confident date, and the task would be completed against it (L257).
    static func date(from token: String) -> Date? {
        let text = token.trimmingCharacters(in: .whitespaces)
        if let exact = formatter.date(from: text) { return exact }
        guard let day = EasternDate.date(from: text) else { return nil }
        return EasternDate.calendar.date(bySettingHour: legacyDueHour, minute: 0, second: 0, of: day)
    }

    // The hour every task written before #3422 carries. Deliberately its own constant rather than
    // `OmniFocusSync.dueHour`: that one is the hour a POST EVENT prompt is still due at today, and the
    // two only happen to be equal. Tying the legacy reading to it would mean a later change to the
    // live hour silently reinterpreted every task already sitting in Dan's OmniFocus (L318).
    static let legacyDueHour = 18
}
// copy-inventory:ignore-end
