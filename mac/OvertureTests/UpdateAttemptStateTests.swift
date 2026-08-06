import Testing
import Foundation

// #2188: Overture watching for the outcome of an update it started.
//
// The press opens a Terminal window and the app carries on. Nothing came back, so a refusal looked
// exactly like a success from inside the app, which on 2026-08-06 meant Dan pressed Update, the run
// refused because another session had work in progress, and Overture said nothing at all for the rest of
// the launch about a copy that was still out of date.
//
// Every rule about WHEN to look and what an absence means lives here, and the whole file is driven with
// an injected clock, an injected wait, and an injected read, so a thirty second grace period and a run
// that never starts both take no real time and never touch Dan's Application Support folder (L2).
@MainActor
@Suite("Overture watches the update it asked for (#2188)")
struct UpdateAttemptStateTests {
    // Counts the waits the watch loop makes and lets the test move the world between them, so a whole
    // update is driven without a real second passing.
    @MainActor private final class Sleeper {
        private(set) var waits = 0
        private var onWait: @MainActor (Int) -> Void = { _ in }
        func setOnWait(_ block: @escaping @MainActor (Int) -> Void) { onWait = block }
        func sleep(_ seconds: TimeInterval) async {
            waits += 1
            onWait(waits)
        }
    }

    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    private func failed(press: String, reason: String) -> UpdateAttemptRecord {
        UpdateAttemptRecord(press: press, outcome: "failed", reason: reason)
    }

    // Nothing has been pressed, so there is nothing to report. Not "waiting", which would be a state
    // about a run that does not exist.
    @Test func itShowsNothingBeforeAnyPress() {
        let state = UpdateAttemptState(reader: { nil })
        state.check(now: date("2026-08-06T14:00:00Z"))
        #expect(state.progress == nil)
        #expect(state.shouldShow == false)
    }

    @Test func aPressWithNoOutcomeYetSaysNothing() {
        let state = UpdateAttemptState(reader: { nil })
        state.pressed("p1", at: date("2026-08-06T14:00:00Z"))
        state.check(now: date("2026-08-06T14:00:05Z"))
        #expect(state.progress == .waiting)
        #expect(state.shouldShow == false)
    }

    // THE CASE. The run refused, and the app has to say so in the run's own words.
    @Test func aRefusalReachesTheApp() {
        let reason = "Overture did not update: there is unsaved work in progress in the code folder."
        let state = UpdateAttemptState(reader: { self.failed(press: "p1", reason: reason) })
        state.pressed("p1", at: date("2026-08-06T14:00:00Z"))
        state.check(now: date("2026-08-06T14:00:05Z"))
        #expect(state.progress == .failed(reason: reason))
        #expect(state.shouldShow)
    }

    // A run that never started. The file was written and handed to macOS, and nothing ever ran it.
    @Test func aRunThatNeverStartsIsReportedOnceTheGraceIsUp() {
        let state = UpdateAttemptState(reader: { nil })
        state.pressed("p1", at: date("2026-08-06T14:00:00Z"))
        state.check(now: date("2026-08-06T14:00:20Z"))
        #expect(state.progress == .waiting)
        state.check(now: date("2026-08-06T14:00:40Z"))
        #expect(state.progress == .neverStarted)
        #expect(state.shouldShow)
    }

    // An earlier press's leftover must not answer for this one, or a refusal from this morning is shown
    // over an update that is working right now.
    @Test func anEarlierPressesOutcomeIsNotThisOnes() {
        let state = UpdateAttemptState(reader: { self.failed(press: "yesterday", reason: "old news") })
        state.pressed("p1", at: date("2026-08-06T14:00:00Z"))
        state.check(now: date("2026-08-06T14:00:05Z"))
        #expect(state.progress == .waiting)
    }

    @Test func dismissingStopsItShowing() {
        let state = UpdateAttemptState(reader: { self.failed(press: "p1", reason: "because") })
        state.pressed("p1", at: date("2026-08-06T14:00:00Z"))
        state.check(now: date("2026-08-06T14:00:05Z"))
        #expect(state.shouldShow)

        state.dismiss()
        #expect(state.shouldShow == false)

        // And it stays gone rather than being re-raised by the next tick, which would make Not now a
        // button that does nothing (#1684).
        state.check(now: date("2026-08-06T14:00:10Z"))
        #expect(state.shouldShow == false)
    }

    // MARK: - What it costs

    // An idle app pays nothing for this (#1916). The loop reads only while a press is outstanding: not
    // before the first press, and not once the outcome is known.
    @Test func itReadsOnlyWhileAPressIsOutstanding() async {
        var reads = 0
        var record: UpdateAttemptRecord?
        var now = date("2026-08-06T14:00:00Z")
        let state = UpdateAttemptState(reader: { reads += 1; return record },
                                       sleep: { _ in },
                                       now: { now })

        // Ticks before any press cost nothing at all.
        state.check(now: now)
        state.check(now: now)
        #expect(reads == 0)

        state.pressed("p1", at: now)
        now = now.addingTimeInterval(5)
        state.check(now: now)
        #expect(reads == 1)

        record = failed(press: "p1", reason: "because")
        now = now.addingTimeInterval(5)
        state.check(now: now)
        #expect(reads == 2)

        // Resolved. Every later tick is free, including the ones the watch loop makes.
        now = now.addingTimeInterval(5)
        state.check(now: now)
        #expect(reads == 2)
    }

    // The loop itself, driven through a fake wait: it keeps looking until the outcome arrives and then
    // stops, without a real thirty seconds passing. Stopping is the half worth pinning: a loop that
    // carried on would read a small file every few seconds for the rest of the day.
    @Test func theWatchKeepsLookingUntilTheOutcomeArrivesAndThenStops() async {
        var record: UpdateAttemptRecord?
        let now = date("2026-08-06T14:00:00Z")
        let sleeper = Sleeper()
        let state = UpdateAttemptState(reader: { record },
                                       sleep: { _ in await sleeper.sleep(0) },
                                       now: { now })
        // The record lands on the third wait, as it would while the run works.
        sleeper.setOnWait { n in if n == 3 { record = self.failed(press: "p1", reason: "because") } }
        state.pressed("p1", at: now)

        await state.watch()

        #expect(state.progress == .failed(reason: "because"))
        #expect(sleeper.waits == 3, "it stops the moment the outcome is known")
    }

    // Nothing outstanding, nothing to watch. Without this the loop started at launch would spin against
    // a press that never happened.
    @Test func theWatchReturnsAtOnceWhenNothingWasPressed() async {
        let sleeper = Sleeper()
        let state = UpdateAttemptState(reader: { nil }, sleep: { _ in await sleeper.sleep(0) })
        await state.watch()
        #expect(sleeper.waits == 0)
    }
}
