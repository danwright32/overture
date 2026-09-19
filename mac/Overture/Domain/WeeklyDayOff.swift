import Foundation
import SwiftData

// #3620: one weekday Dan is never free, every week, as ONE stored rule.
//
// The evidence it was built from is in his own store: three `DayOff` rows for one weekly rehearsal, typed
// one Wednesday at a time, with a week missing and nothing after the last one, so from then on Overture
// believed his Wednesday evenings were free. A standing commitment could only be said one row per week, and
// the gap in the data shows nobody does that.
//
// A THIRD stored shape beside `DayOff` and `CancelledShoot`, stored the way Dan says it ("every Wednesday
// from February 1"), never as a generator that writes 52 rows, so the Days off sheet reads it back as one
// row and removing it is one click.
//
// Independent of every other model (no relationship, no new column on an existing one), so adding it is a
// purely additive lightweight migration, rehearsed against a clone of the live store in
// `WeeklyDayOffMigrationDryRunTests` before it ships (the `CancelledShoot` precedent).
@Model
final class WeeklyDayOff {
    // Gregorian weekday in Eastern time, as `Calendar` numbers it: 1 is Sunday, 7 is Saturday.
    var weekday: Int
    // Both optional, and all four combinations are wanted (Dan named the bounded ones himself): absent first
    // means it has always applied, absent last means it never stops. yyyy-MM-dd, inclusive.
    var firstDate: String?
    var lastDate: String?
    var note: String?
    // Single dates Dan has freed from the rule: the rehearsal is cancelled that week, and the night has to
    // read as genuinely free on every surface, not merely cleared on one show (Dan's call, 2026-09-07).
    var freedDates: [String] = []
    var createdAt: Date

    init(weekday: Int, firstDate: String? = nil, lastDate: String? = nil, note: String? = nil,
         freedDates: [String] = [], createdAt: Date = Date()) {
        self.weekday = weekday
        self.firstDate = firstDate
        self.lastDate = lastDate
        self.note = note
        self.freedDates = freedDates
        self.createdAt = createdAt
    }
}

// The pure mirror of a `WeeklyDayOff` row, so `BlockedCalendar` and every test of it never touch SwiftData
// (`DayOffRange`'s pattern).
//
// THE HORIZON QUESTION, and why there is none. `BlockedCalendar.build` materialises every range into a
// list of dates, and a rule with no last date has no date to expand to. Expanding to some bound would make
// every night past it read as FREE on a rule that says otherwise, with nothing reporting it: the one year
// cap in `EasternDate.days` is exactly that trap, silently returning a short list (the 2026-09-07 comment
// on #3620). So a rule is never expanded. "Is this date blocked by a rule" is answered by `blocks`, a
// predicate over the one date asked about, which has no horizon and cannot stop early. Nothing in the app
// needs the rule as a list of dates: the sheet lists the stored rule as one row, and every other consumer
// asks about a date.
struct WeeklyBlock: Equatable, Sendable {
    var weekday: Int
    var firstDate: String?
    var lastDate: String?
    var note: String?
    var freedDates: Set<String>

    init(weekday: Int, firstDate: String? = nil, lastDate: String? = nil, note: String? = nil,
         freedDates: Set<String> = []) {
        self.weekday = weekday
        self.firstDate = firstDate
        self.lastDate = lastDate
        self.note = note
        self.freedDates = freedDates
    }

    // The whole rule, asked of one date.
    //
    // A date that cannot be read is NOT blocked by a rule, because no weekday can be read off it either;
    // the same string reaches `BlockedCalendar`'s range half unread and blocks nothing there too, so the two
    // halves agree about it rather than one of them guessing.
    func blocks(_ date: String) -> Bool {
        if let firstDate, date < firstDate { return false }
        if let lastDate, date > lastDate { return false }
        guard !freedDates.contains(date), let day = EasternDate.date(from: date) else { return false }
        return EasternDate.calendar.component(.weekday, from: day) == weekday
    }

    // Whether the rule has nothing left to block: its last date is behind today. A standing rule never
    // expires. Used by the sheet, which lists what is still ahead (#3406).
    func hasEnded(today: String) -> Bool {
        guard let lastDate else { return false }
        return lastDate < today
    }
}

// The rules for adding, removing and freeing a date from a weekly block, kept out of the sheet for the
// reason `DayOffEditing` is (#863). Every one of them re-judges the queue on the spot through the same
// sweep `DayOffEditing.add` runs, or Dan blocks his Wednesdays, sees nothing change, and concludes it did
// not work.
@MainActor
enum WeeklyDayOffEditing {

    enum Result: Equatable, Sendable {
        case added
        case notAWeekday
        case invalidDate
        case endsBeforeItStarts
    }

    // The weekdays in the order a week is read in New York, Monday first, with `Calendar`'s numbers.
    nonisolated static let weekdays: [(number: Int, name: String)] = [
        (2, "Monday"), (3, "Tuesday"), (4, "Wednesday"), (5, "Thursday"), (6, "Friday"),
        (7, "Saturday"), (1, "Sunday"),
    ]

    nonisolated static func weekdayName(_ number: Int) -> String? {
        weekdays.first { $0.number == number }?.name
    }

    // The two date refusals are the range form's own sentences, asked of it rather than copied (#843).
    static func message(for result: Result) -> String? {
        switch result {
        case .added: return nil                  // the row appearing in the list is the receipt
        case .notAWeekday: return "Pick a day of the week."
        case .invalidDate: return DayOffEditing.message(for: .invalidDate)
        case .endsBeforeItStarts: return DayOffEditing.message(for: .endsBeforeItStarts)
        }
    }

    // `freedDates` is for the Undo of a removal, which puts the whole rule back; a new rule frees nothing.
    @discardableResult
    static func add(weekday: Int, firstDate: String?, lastDate: String?, note: String?,
                    freedDates: [String] = [],
                    export: DayOffEditing.Export = DownbeatBridge.loadedExport(),
                    into context: ModelContext) -> Result {
        guard weekdayName(weekday) != nil else { return .notAWeekday }
        for date in [firstDate, lastDate].compactMap({ $0 }) where EasternDate.date(from: date) == nil {
            return .invalidDate
        }
        if let firstDate, let lastDate, lastDate < firstDate { return .endsBeforeItStarts }

        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        context.insert(WeeklyDayOff(weekday: weekday, firstDate: firstDate, lastDate: lastDate,
                                    note: (trimmed?.isEmpty ?? true) ? nil : trimmed, freedDates: freedDates))
        try? context.save()
        ConflictSweep.reapplyAll(export: export, in: context)
        return .added
    }

    static func remove(_ rule: WeeklyDayOff, export: DayOffEditing.Export = DownbeatBridge.loadedExport(),
                       in context: ModelContext) {
        context.delete(rule)
        try? context.save()
        ConflictSweep.reapplyAll(export: export, in: context)
    }

    enum FreeResult: Equatable, Sendable {
        case freed
        case notBlockedByThisRule
    }

    // Frees one date from the rule. Refused where the rule does not block that date (the wrong weekday,
    // outside its first and last date, or already freed), because a freed date the rule never blocked would
    // sit on the row claiming a night was freed when nothing about it changed.
    @discardableResult
    static func free(_ date: String, from rule: WeeklyDayOff,
                     export: DayOffEditing.Export = DownbeatBridge.loadedExport(),
                     in context: ModelContext) -> FreeResult {
        guard block(rule).blocks(date) else { return .notBlockedByThisRule }
        rule.freedDates.append(date)
        try? context.save()
        ConflictSweep.reapplyAll(export: export, in: context)
        return .freed
    }

    // The row's "free one date" control, which is its own Cancel while the picker is open (the #885 rule:
    // copy computed in a view body is copy no test can read).
    nonisolated static func freeButtonTitle(isOpen: Bool) -> String { isOpen ? "Cancel" : "Free one date" }

    // A date freed from the rule, as the line under its row says it.
    nonisolated static func freedLine(_ date: String) -> String {
        "Free on \(EasternDate.dayLabel(date) ?? date)"
    }

    // Why a date could not be freed, naming the weekday, since the usual cause is a date on the wrong one.
    nonisolated static func freeRefusal(date: String, weekday: Int) -> String {
        let day = EasternDate.dayLabel(date) ?? date
        let weekdayName = weekdayName(weekday) ?? "day"
        return "\(day) isn't one of the \(weekdayName)s this blocks."
    }

    // Puts a freed date back under the rule: the Undo of `free`, and "block it again" on the row.
    static func reblock(_ date: String, on rule: WeeklyDayOff,
                        export: DayOffEditing.Export = DownbeatBridge.loadedExport(),
                        in context: ModelContext) {
        rule.freedDates.removeAll { $0 == date }
        try? context.save()
        ConflictSweep.reapplyAll(export: export, in: context)
    }

    static func rows(in context: ModelContext) -> [WeeklyDayOff] {
        (try? context.fetch(FetchDescriptor<WeeklyDayOff>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
    }

    nonisolated static func block(_ rule: WeeklyDayOff) -> WeeklyBlock {
        WeeklyBlock(weekday: rule.weekday, firstDate: rule.firstDate, lastDate: rule.lastDate,
                    note: rule.note, freedDates: Set(rule.freedDates))
    }

    // What the scout reads: the stored rules as pure values.
    static func blocks(in context: ModelContext) -> [WeeklyBlock] {
        rows(in: context).map(block)
    }

    // #3406's filter for this third list: a bounded rule whose last date has passed has nothing left to
    // block, so the sheet stops listing it. Filtered, never deleted.
    nonisolated static func upcoming(_ rules: [WeeklyDayOff], today: String) -> [WeeklyDayOff] {
        rules.filter { !block($0).hasEnded(today: today) }
    }

    // The row's own words: the weekday and its bounds, as Dan would say them.
    nonisolated static func label(weekday: Int, firstDate: String?, lastDate: String?) -> String {
        let day = weekdayName(weekday) ?? "week"
        let first = firstDate.flatMap { EasternDate.dayLabel($0) }
        let last = lastDate.flatMap { EasternDate.dayLabel($0) }
        switch (first, last) {
        case (nil, nil): return "Every \(day)"
        case (nil, let last?): return "Every \(day) until \(last)"
        case (let first?, nil): return "Every \(day) from \(first)"
        case (let first?, let last?): return "Every \(day), \(first) to \(last)"
        }
    }
}
