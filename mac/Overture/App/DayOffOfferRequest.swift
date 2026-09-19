import Foundation
import Observation

// #924: the channel that carries a "let Dan pick which days to block" request from a dismiss (deep in a
// row) up to RootView, which owns the date-picker sheet. Injected like ActionFeedback rather than threaded
// as a closure through every layer between the row and the window, so the row need not know the sheet
// exists. Every calendar-reason dismissal opens this picker, single-night or multi-night alike (revised
// after Dan walked the first build, 2026-07-15): there is no one-tap banner path anymore.
@MainActor
@Observable
final class DayOffOfferRequest {
    struct Pending: Identifiable, Equatable {
        // Stable so .sheet(item:) keys cleanly: the show's natural key, or for a whole night (#1743) a
        // night-shaped id, since a night holds many shows and no single one is the subject.
        let id: String
        // The picker's sentence, composed by `DayOffOffer` (the #863 rule: never in the view).
        let subtitle: String
        // #1473: the key of the undo entry the block folds into, so one Cmd+Z takes back both. For one
        // show it is that show; for a night it is the batch entry's first row, which is what
        // `QueueUndoStack.attachBlockedDaysOff` matches on.
        let dismissKey: String
        let start: String     // yyyy-MM-dd, the night that was dismissed
        let end: String       // yyyy-MM-dd, the same night (#2373)

        // #1743: the whole-night offer.
        static func night(date: String, dateLabel: String, count: Int, dismissKey: String,
                          offer: DayOffOffer.Offer) -> Pending {
            Pending(id: "night|\(date)",
                    subtitle: DayOffOffer.nightPickerSubtitle(count: count, dateLabel: dateLabel),
                    dismissKey: dismissKey, start: offer.start, end: offer.end)
        }
    }

    var pending: Pending?

    func request(key: String, org: String, start: String, end: String) {
        request(Pending(id: key, subtitle: DayOffOffer.pickerSubtitle(org: org), dismissKey: key,
                        start: start, end: end))
    }

    func request(_ offer: Pending) {
        QueueWriteTrace.note(QueueWriteTrace.dayOffOffer)
        pending = offer
    }

    func clear() {
        QueueWriteTrace.note(QueueWriteTrace.dayOffOffer)
        pending = nil
    }
}
