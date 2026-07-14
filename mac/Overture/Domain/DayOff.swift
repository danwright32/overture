import Foundation
import SwiftData

// #901: a stretch of days Dan is away, typed into Overture by him.
//
// Stored as the RANGE he entered ("the 14th through the 22nd"), not as nine rows, so removing a vacation
// is one click rather than nine, and the list reads back the way he wrote it. The days themselves are
// expanded on read, by BlockedCalendar.
//
// This replaces `overture-blocked-dates.json`, a local override file the scout has always read and
// nothing has ever written: there was no editor, no settings screen, and no writer anywhere in the app,
// so the one conflict source that could have worked was inert for the app's whole life (#901).
@Model
final class DayOff {
    // Not `id`: PersistentModel already refines Identifiable through persistentModelID, and a stored
    // `var id` collides with that conformance (the same convention as Prospect.naturalKey and
    // WatchedSource.sourceId).
    var startDate: String       // yyyy-MM-dd, inclusive
    var endDate: String         // yyyy-MM-dd, inclusive
    var note: String?           // "Vacation". Optional: a blocked day needs no excuse.
    var createdAt: Date

    init(startDate: String, endDate: String, note: String? = nil, createdAt: Date = Date()) {
        self.startDate = startDate
        self.endDate = endDate
        self.note = note
        self.createdAt = createdAt
    }
}

// The rules for adding and removing days off, kept OUT of the sheet that draws them.
//
// Same reason WatchlistEditing exists rather than living in SourcesView: a rule stated in a view is a
// rule that lasts until the next view, and #863 is this repo's proof that logic computed in a SwiftUI
// body drifts under a fully green test suite because nothing can reach it.
@MainActor
enum DayOffEditing {

    enum Result: Equatable, Sendable {
        case added
        case endsBeforeItStarts
        case tooLong
        case invalidDate
    }

    // A year. Overture only ever looks four months ahead (#858), so a decade-long block is a typo rather
    // than a plan, and quietly accepting it would block every show Dan will ever be shown.
    static let maxDays = EasternDate.maxRangeDays

    // The add-a-range button's two states, kept out of the sheet for the same reason WatchlistEditing owns
    // its own (#885): copy computed in a view body is copy no test can read.
    static func addButtonTitle(isOpen: Bool) -> String { isOpen ? "Cancel" : "Block some days" }

    static func message(for result: Result) -> String? {
        switch result {
        case .added: return nil                 // the row appearing in the list is the receipt
        case .endsBeforeItStarts: return "The last day is before the first day."
        case .tooLong: return "That's longer than a year. Block a shorter stretch."
        case .invalidDate: return "That isn't a date Overture can read."
        }
    }

    @discardableResult
    static func add(start: String, end: String, note: String?, into context: ModelContext) -> Result {
        guard let startDate = EasternDate.date(from: start),
              let endDate = EasternDate.date(from: end) else { return .invalidDate }
        guard endDate >= startDate else { return .endsBeforeItStarts }
        guard let span = EasternDate.daysUntil(from: start, to: end), span < maxDays else { return .tooLong }

        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        context.insert(DayOff(startDate: start, endDate: end,
                              note: (trimmed?.isEmpty ?? true) ? nil : trimmed))
        try? context.save()
        return .added
    }

    static func remove(_ dayOff: DayOff, in context: ModelContext) {
        context.delete(dayOff)
        try? context.save()
    }

    // What the scout reads: the stored rows as pure ranges, so BlockedCalendar (and every test of it)
    // never touches SwiftData.
    static func ranges(in context: ModelContext) -> [DayOffRange] {
        let rows = (try? context.fetch(FetchDescriptor<DayOff>(sortBy: [SortDescriptor(\.startDate)]))) ?? []
        return rows.map { DayOffRange(startDate: $0.startDate, endDate: $0.endDate, note: $0.note) }
    }
}
