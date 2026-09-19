import Foundation
import Observation
import SwiftData

// #1421: the blocked calendar, built ONCE for the whole app and read by the surfaces that draw it.
//
// WHY THIS IS OWNED BY THE APP rather than built where it is read. Building the calendar decodes the whole
// Downbeat export from disk and fetches every `DayOff` and `CancelledShoot` row. The toolbar's Days off
// mark did that inside `RootView`'s body, so every redraw of the main window paid for it, and the Days off
// sheet did it inside a computed property read on every render of the sheet. That is the shape #1374,
// #1429 and #2365 each had to take off a render path after it froze a surface; `ClientRoster` is the same
// fix for the client list, one file over.
//
// WHEN IT IS REBUILT. Every change to what the calendar is built from already runs through ONE function,
// `ConflictSweep.reapplyAll`: adding or removing a day off (`DayOffEditing`), cancelling or restoring a
// booked shoot (`CancelledShootEditing`), and a reconcile tick that read the export
// (`ReconcileScheduler.reapplyConflicts`). The sweep builds a fresh calendar to judge the queue against,
// and then HANDS THAT CALENDAR here, synchronously, before it returns. So the calendar on screen is the
// very value the queue was just judged against rather than a second build that could come out differently
// (L16), and a mutation's caller reads the new calendar on its very next line. It is handed over by
// notification rather than by a parameter because those callers are reached from a dozen places, tests
// included, and a parameter that could be left out would be the forgettable wire this repo keeps losing.
//
// The notification carries the store's CONTAINER as its object, and a snapshot accepts only its own. A
// test sweeping an in-memory store therefore cannot repaint the calendar of the app hosting the tests.
//
// What still builds its own calendar, deliberately: the scout, a pasted lead and the scout extract ingest.
// None of them is on a render path (each builds once per run), and each is about to WRITE a verdict into
// the store, so a fresh read is the safer direction there: a stale cache could only ever let a night
// through that is taken (L42's direction).
@MainActor
@Observable
final class AvailabilitySnapshot {
    // What every surface reads. Empty until the first build, which `attach` does at once.
    private(set) var calendar: BlockedCalendar = .empty
    // The export's bookings, beside the calendar built from them, because the sheet's unblock control has
    // to say WHICH booking a row stands for and must not decode the export again to find out (#2692).
    private(set) var bookings: [OvertureBooking] = []
    // #3311: whether the export this calendar was built from could be READ. An unreadable export builds a
    // calendar with no booked shoots in it, which looks exactly like a free diary, so a surface marking
    // nights as clear or blocked has to be able to say "could not check" instead (L98). The Prep picker is
    // the first reader.
    private(set) var readability: BlockedCalendar.Availability = .measured
    // How many times this snapshot has been built or handed a calendar. The render path's measurement
    // reads it: a surface that redraws a hundred times and leaves this unmoved is paying nothing per redraw.
    private(set) var builds = 0

    @ObservationIgnored private var context: ModelContext?
    @ObservationIgnored private var tokens = WindowCensus.TokenBox([])
    // Injected so a test never reaches Dan's real export (L2). The default is the shipped read.
    @ObservationIgnored private let loadExport: () -> DayOffEditing.Export

    init(loadExport: @escaping () -> DayOffEditing.Export = { DownbeatBridge.loadedExport() }) {
        self.loadExport = loadExport
    }

    // Binds the snapshot to the store it describes, builds it, and from then on accepts the sweep's
    // calendars for that store alone. Attaching again replaces the earlier binding rather than adding a
    // second observer beside it.
    func attach(to context: ModelContext) {
        detach()
        self.context = context
        let token = NotificationCenter.default.addObserver(
            forName: Self.rebuilt, object: context.container, queue: nil
        ) { [weak self] note in
            // The sweep is @MainActor and posts synchronously, so this runs on the main actor before the
            // sweep returns. Asserted rather than hopped: a hop would make the hand over ASYNC and give the
            // mutation's caller the old calendar on its next line.
            let published = note.userInfo?[Self.payloadKey] as? Published
            MainActor.assumeIsolated {
                guard let self else { return }
                if let published { self.adopt(published) } else { self.rebuildNow() }
            }
        }
        tokens = WindowCensus.TokenBox([token])
        rebuildNow()
    }

    func detach() {
        for token in tokens.take() { NotificationCenter.default.removeObserver(token) }
        context = nil
    }

    // For a view's `.task`: attached for as long as the task lives, and detached when it is cancelled, so a
    // window scene that is torn down and rebuilt does not leave an observer behind (`WindowCensus`'s L86).
    func attachUntilCancelled(to context: ModelContext) async {
        attach(to: context)
        await WindowCensus.suspendUntilCancelled()
        detach()
    }

    // Builds it now, from the export on disk and the attached store. The one place this type builds.
    func rebuildNow() {
        guard let context else { return }
        let export = loadExport()
        adopt(Published(calendar: ScoutService.blockedCalendar(export: export, context: context),
                        bookings: export.bookings,
                        readability: BlockedCalendar.Availability(health: export.health)))
    }

    private func adopt(_ published: Published) {
        calendar = published.calendar
        bookings = published.bookings
        readability = published.readability
        builds += 1
    }

    // MARK: - The hand over from the sweep

    struct Published: Sendable {
        let calendar: BlockedCalendar
        let bookings: [OvertureBooking]
        let readability: BlockedCalendar.Availability
    }

    static let rebuilt = Notification.Name("Overture.AvailabilitySnapshot.rebuilt")
    static let payloadKey = "published"

    // Called by `ConflictSweep.reapplyAll` with the calendar it just judged the queue against.
    static func publish(_ calendar: BlockedCalendar, bookings: [OvertureBooking],
                        readability: BlockedCalendar.Availability, for context: ModelContext) {
        NotificationCenter.default.post(
            name: rebuilt, object: context.container,
            userInfo: [payloadKey: Published(calendar: calendar, bookings: bookings, readability: readability)])
    }
}
