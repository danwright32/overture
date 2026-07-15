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
        let id: String        // the show's natural key, stable so .sheet(item:) keys cleanly
        let org: String
        let start: String     // yyyy-MM-dd, pre-filled into the picker as the run's opening night
        let end: String       // yyyy-MM-dd, its closing night
    }

    var pending: Pending?

    func request(key: String, org: String, start: String, end: String) {
        pending = Pending(id: key, org: org, start: start, end: end)
    }

    func clear() { pending = nil }
}
