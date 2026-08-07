import Foundation

// #2202: one way to raise something Dan has to answer, that whatever is already on screen cannot
// swallow.
//
// macOS presents a SwiftUI `.alert` and a SwiftUI `.sheet` the same way, as a window sheet. Two of them
// on one window do not stack: the second queues behind the first and is simply not on screen. RootView
// carries four alerts and roughly fifteen sheets on the same view, so every one of those alerts can be
// raised into a window that is already presenting something.
//
// Observed 2026-08-06 (#2200): a manual scout suspended to ask Dan how many calendars to read, the
// question queued behind the progress takeover, and the sweep waited on an answer that could never
// arrive. All 68 sources fetched, the takeover froze at "68 of 68 done" and kept counting. Nothing was
// spent, but the run could not finish and nothing said why.
//
// That was the instance. The class is worse: the generic "Something went wrong" alert has the same
// shape, so a real error raised during a scout, a Prep run, or any open sheet vanishes silently. An
// error nobody can see is the failure L10 and L13 are both about, and it arrives exactly when something
// has already gone wrong.
//
// So anything that has to be ANSWERED goes through here, and raising closes what is presented first.
// Closing rather than layering because layering is the thing macOS will not do; there is no version of
// this where both are on screen. What Dan loses is a sheet he can reopen; what he gains is the question.
//
// Deliberately not a queue of requests. A second question raised while one is up would hit the very
// limitation this exists for, so the ordering is the caller's problem to avoid and this makes it visible
// (`isPresenting`) rather than silently dropping the second one.
@MainActor
@Observable
final class AppModals {
    // How to close everything currently presented. Injected rather than known here, because the sheets
    // are RootView's own @State and nothing outside that view can reach them.
    private var closePresentedSheets: () -> Void = {}

    // Set once by the view that owns the sheets.
    func closesSheetsWith(_ close: @escaping () -> Void) {
        closePresentedSheets = close
    }

    // Whether a question raised through here is currently up. Read by callers that must not raise a
    // second one on top of it, and by the tests.
    private(set) var isPresenting = false

    // Raise something Dan has to answer. The ordering is the whole point: everything presented is closed
    // BEFORE the alert's own state is set, because setting it first is exactly what produces a question
    // queued behind a sheet.
    func raise(_ present: () -> Void) {
        closePresentedSheets()
        isPresenting = true
        present()
    }

    // The answer landed (or Dan dismissed it), so the next question may be raised.
    func settled() {
        isPresenting = false
    }
}
