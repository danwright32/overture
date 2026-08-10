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

    // The add form's editable state, snapshotted when it opens and again when Done is pressed, so the
    // sheet can tell a real edit from a form Dan merely opened and left alone (#928). Days are the ISO
    // strings the pickers resolve to, so a time-of-day drift can never read as a date change.
    struct AddDraft: Equatable, Sendable {
        var startDay: String
        var endDay: String
        var note: String
    }

    // #901 walk fix / #928: whether closing the sheet should ask first. It should when the add form is
    // open AND Dan actually edited it since it opened (moved a picker or typed a note), because that is
    // work Done would otherwise discard silently, which is what lost his range once. An open form he
    // changed nothing in has nothing to lose, so it closes without a nag. In the tested helper rather than
    // the view so the rule can't quietly regress to a bare dismiss(), the way #863 taught us about logic
    // living in a view body. A missing baseline (should not happen) asks, so no edit is ever dropped.
    static func closeNeedsConfirmation(addFormOpen: Bool, draft: AddDraft, baseline: AddDraft?) -> Bool {
        guard addFormOpen else { return false }
        guard let baseline else { return true }
        func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        return draft.startDay != baseline.startDay
            || draft.endDay != baseline.endDay
            || trimmed(draft.note) != trimmed(baseline.note)
    }

    // #2254, from Dan's walk of the days off form on 2026-08-07: moving First day forward to 8/10 left
    // Last day sitting at 8/7, three days before the range starts, with both fields looking perfectly
    // normal. The refusal below catches it at the press, but a form that looks correct while holding an
    // impossible range has already misled him.
    //
    // The last day follows the first: when the first day moves past it, it comes with it. Never the other
    // way round, so extending a trip by moving Last day out is untouched.
    //
    // Compared as EASTERN DAYS rather than as instants, through the one date helper (L39): the pickers
    // carry a time component, so an instant comparison would drag Last day forward for a first day
    // LATER IN THE SAME DAY, which is not a backwards range at all. Lives here, not in the fields view,
    // so it is testable and so the two sheets that embed those fields cannot drift apart on it.
    static func endMovedWithStart(start: Date, end: Date) -> Date {
        EasternDate.dayString(from: end) < EasternDate.dayString(from: start) ? start : end
    }

    static func message(for result: Result) -> String? {
        switch result {
        case .added: return nil                 // the row appearing in the list is the receipt
        case .endsBeforeItStarts: return "The last day is before the first day."
        case .tooLong: return "That's longer than a year. Block a shorter stretch."
        case .invalidDate: return "That isn't a date Overture can read."
        }
    }

    // `export` is a parameter, not a hidden read, so the sweep below is testable without a file on disk.
    // It defaults to the real one, so no call site can accidentally sweep against an empty calendar and
    // quietly drop every booked shoot from the verdict.
    typealias Export = (bookings: [OvertureBooking], blockedDates: [String])

    @discardableResult
    static func add(start: String, end: String, note: String?,
                    export: Export = DownbeatBridge.loadedExport(),
                    into context: ModelContext) -> Result {
        guard let startDate = EasternDate.date(from: start),
              let endDate = EasternDate.date(from: end) else { return .invalidDate }
        guard endDate >= startDate else { return .endsBeforeItStarts }
        guard let span = EasternDate.daysUntil(from: start, to: end), span < maxDays else { return .tooLong }

        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        context.insert(DayOff(startDate: start, endDate: end,
                              note: (trimmed?.isEmpty ?? true) ? nil : trimmed))
        try? context.save()
        // Blocking a week flags the shows in that week NOW, not on the next scout. Without this Dan blocks
        // his vacation, sees nothing change in the queue, and reasonably concludes it did not work, while
        // every show in that week stays draftable and sendable in the meantime.
        ConflictSweep.reapplyAll(export: export, in: context)
        return .added
    }

    static func remove(_ dayOff: DayOff, export: Export = DownbeatBridge.loadedExport(),
                       in context: ModelContext) {
        context.delete(dayOff)
        try? context.save()
        ConflictSweep.reapplyAll(export: export, in: context)
    }

    // The stored rows themselves, for the sheet that lists them.
    static func rows(in context: ModelContext) -> [DayOff] {
        (try? context.fetch(FetchDescriptor<DayOff>(sortBy: [SortDescriptor(\.startDate)]))) ?? []
    }

    // What the scout reads: the stored rows as pure ranges, so BlockedCalendar (and every test of it)
    // never touches SwiftData.
    static func ranges(in context: ModelContext) -> [DayOffRange] {
        rows(in: context).map { DayOffRange(startDate: $0.startDate, endDate: $0.endDate, note: $0.note) }
    }
}

// #901: re-judging the shows already in the store against a calendar that just CHANGED.
//
// The scout computes a show's conflict when the show arrives. That is only half the story, because the
// other input is the calendar, and Dan edits that one himself. Without this, he blocks his vacation, looks
// at the queue, sees nothing flagged, and reasonably concludes it did not work, while every show in that
// week stays draftable and sendable until the next scout happens to run.
//
// It is called from DayOffEditing.add and .remove, which are the two things Dan actually touches, rather
// than from the sheet that draws them: a guard and its wiring are two separate claims (#887), and a wire
// that lives in a view is a wire no test can pull.
@MainActor
enum ConflictSweep {

    // Every stored prospect, re-judged. Returns how many CHANGED, so a caller can say so if it wants to.
    //
    // Dan's own clearances survive by construction: setScoutConflict compares the new key against the one
    // he cleared, so a show he already waved through stays waved through, and one whose clash has changed
    // under him blocks again. That is the same rule the scout applies, because it is the same call.
    @discardableResult
    static func reapplyAll(export: DayOffEditing.Export, in context: ModelContext) -> Int {
        let calendar = ScoutService.blockedCalendar(export: export, context: context)
        let prospects = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []

        var changed = 0
        for p in prospects {
            let key = calendar.conflict(performanceDate: p.performanceDate, runEndDate: p.runEndDate,
                                        nights: p.runNights)?.key
            guard key != p.conflictKey else { continue }
            p.setScoutConflict(key)
            changed += 1
        }
        if changed > 0 { try? context.save() }
        return changed
    }
}
