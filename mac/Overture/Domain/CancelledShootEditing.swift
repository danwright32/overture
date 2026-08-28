import Foundation
import SwiftData

// #2692: cancelling a booked shoot, putting it back, and working out which booking a row on the days off
// sheet is about. Kept out of the view so every rule here is testable (#863).
enum CancelledShootEditing {

    static func cancelledIds(in context: ModelContext) -> Set<String> {
        Set(rows(in: context).map(\.bookingId))
    }

    static func rows(in context: ModelContext) -> [CancelledShoot] {
        (try? context.fetch(FetchDescriptor<CancelledShoot>())) ?? []
    }

    // Which bookings a row on the sheet is about.
    //
    // The sheet draws `BlockedCalendar.Day`s, which carry a date and a shoot NAME and deliberately not a
    // booking id: `Day.key` is what a prospect stores as its conflict, so widening it would re-key every
    // flagged card on Dan's live store, which is a migration rather than a feature. So the row resolves
    // back to the export instead.
    //
    // It can answer with MORE THAN ONE, and that is correct rather than a loose match. `build` collapses
    // two bookings alike in name and date into one Day on purpose ("ONE fact to everything downstream:
    // the same key, the same sentence, the same row"), so a row standing for two indistinguishable
    // bookings cancels both. What it can never do is reach a booking with a DIFFERENT name on the same
    // night, which is the case Dan's call was about: Firebird Pops Orchestra shares 2027-02-14 with
    // another shoot and is its own row.
    //
    // A Day with no name is the flat `blockedDates` entry, which has no booking behind it and so nothing
    // to cancel. It answers empty rather than guessing at the date.
    static func bookingIds(for day: BlockedCalendar.Day,
                           in bookings: [OvertureBooking]) -> [String] {
        guard day.kind == .bookedShoot, let name = day.name else { return [] }
        return bookings
            .filter { $0.shootName == name
                && EasternDate.days(from: $0.startDate, through: $0.endDate).contains(day.date) }
            .map(\.id)
            .sorted()
    }

    // What is still holding a date after a cancellation, so the sheet can say so rather than showing an
    // unblock that appears not to have worked. Names the shoots by the words Downbeat gave them.
    static func stillBlocking(date: String, bookings: [OvertureBooking],
                              cancelledIds: Set<String>) -> [String] {
        bookings
            .filter { !cancelledIds.contains($0.id)
                && EasternDate.days(from: $0.startDate, through: $0.endDate).contains(date) }
            .map(\.shootName)
            .sorted()
    }

    // Both of these re-judge the shows already in the store, on `DayOffEditing`'s precedent and for its
    // reason: the calendar just changed, and a card carrying a conflict Dan has since waved through would
    // otherwise keep it until the next reconcile tick, up to half an hour later. That is Dan's own
    // acceptance line ("prospects already flagged for that night clear on the next reconcile, with no
    // rescout"), met immediately rather than eventually.
    // @MainActor on these two ONLY, and not on the enum: `ConflictSweep.reapplyAll` is isolated, and
    // these are the two that call it. The rules above (which booking a row is about, what is still holding
    // a night) are pure and stay reachable from anywhere, which is also what lets them be tested without a
    // container.
    @MainActor
    @discardableResult
    static func cancel(bookingIds: [String], named name: String, on date: String,
                       export: DayOffEditing.Export = DownbeatBridge.loadedExport(),
                       in context: ModelContext, now: Date = Date()) -> Int {
        let existing = cancelledIds(in: context)
        var added = 0
        for id in bookingIds where !existing.contains(id) {
            context.insert(CancelledShoot(bookingId: id, shootName: name, startDate: date,
                                          cancelledAt: now))
            added += 1
        }
        try? context.save()
        if added > 0 { ConflictSweep.reapplyAll(export: export, in: context) }
        return added
    }

    @MainActor
    @discardableResult
    static func restore(bookingIds: [String],
                        export: DayOffEditing.Export = DownbeatBridge.loadedExport(),
                        in context: ModelContext) -> Int {
        let wanted = Set(bookingIds)
        var removed = 0
        for row in rows(in: context) where wanted.contains(row.bookingId) {
            context.delete(row)
            removed += 1
        }
        try? context.save()
        // The direction that matters most: putting a shoot back must RE-FLAG the shows on that night, or
        // Dan restores a block and the cards he was protecting stay clear until something else sweeps.
        if removed > 0 { ConflictSweep.reapplyAll(export: export, in: context) }
        return removed
    }

    // Hygiene, not a correctness guard, and the difference matters before anybody changes it. A booking id
    // is Downbeat's own, so a row left behind after Downbeat drops the booking cannot suppress anything: a
    // future booking on the same date carries a different id. What it can do is sit in the store forever
    // as a rule nobody can see, so it is swept once the export stops carrying its booking.
    //
    // It sweeps against the bookings the export ACTUALLY carried, so it must never run on an export that
    // failed to load: an unreadable export yields no bookings, and treating that as "Downbeat dropped
    // every booking" would delete every one of Dan's cancellations at once (L214, and the #663 shape).
    // The caller proves the export was read; this refuses an empty list outright rather than trusting it.
    @discardableResult
    static func sweep(against bookings: [OvertureBooking], in context: ModelContext) -> Int {
        guard !bookings.isEmpty else { return 0 }
        let known = Set(bookings.map(\.id))
        var removed = 0
        for row in rows(in: context) where !known.contains(row.bookingId) {
            context.delete(row)
            removed += 1
        }
        if removed > 0 { try? context.save() }
        return removed
    }
}
