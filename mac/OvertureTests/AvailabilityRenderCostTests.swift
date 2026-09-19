import Testing
import Foundation
import SwiftData

// #1421: what the blocked calendar cost the render path, measured before and after it moved into
// `AvailabilitySnapshot`.
//
// BEFORE, `RootView.daysOffReason` built it on every body evaluation of the main window, and the Days off
// sheet built it on every body evaluation of the sheet. One build is a decode of the Downbeat export from
// disk plus a fetch of every `DayOff` and `CancelledShoot`. AFTER, a body evaluation reads a stored value
// and builds nothing: `AvailabilitySnapshotTests.readingTheCalendarBuildsNothing` pins that on every push,
// as a count rather than a time.
//
// THE READING, 2026-09-18, over a clone of the live store and the live export (20 bookings, 17 flat blocked
// dates, 31 clients, 21.5 KB; 103 blocked days once expanded), mean of 50 after a warm pass:
//
//   BEFORE  1.148 ms per body evaluation of the main window, for the toolbar mark alone
//   AFTER   0.0031 ms, and 0 builds across 50 redraws
//
// A millisecond is not a freeze on its own. What made it one is the multiplier: RootView's body runs on
// every change to anything it observes, and the sheet paid the same again per redraw. It is printed rather
// than asserted, because a time depends on what else the Mac is doing (L224) and the claim that matters,
// zero builds per redraw, is the count above.
@Suite("What the blocked calendar costs a redraw (#1421)")
struct AvailabilityRenderCostTests {
    private static var liveStoreURL: URL {
        StoreLocation.storeURL(appSupport: StoreLocation.appSupport, isDebugBuild: false)
    }
    private static var liveStoreExists: Bool {
        FileManager.default.fileExists(atPath: liveStoreURL.path)
    }

    private static func milliseconds(rounds: Int, _ body: () -> Void) -> Double {
        let started = Date()
        for _ in 0..<rounds { body() }
        return Date().timeIntervalSince(started) / Double(rounds) * 1000
    }

    // THE READING. Opt in, because it clones the live store and runs a stopwatch.
    //
    //   TEST_RUNNER_MEASURE_AVAILABILITY=1 mac/scripts/run-tests-locked.sh \
    //     -only-testing:OvertureTests/AvailabilityRenderCostTests
    @MainActor
    @Test(.enabled(if: liveStoreExists, "no live store on this machine"))
    func measureWhatARedrawPaysForTheCalendar() async throws {
        guard ProcessInfo.processInfo.environment["MEASURE_AVAILABILITY"] != nil else {
            print("availability-cost: not measured. Set TEST_RUNNER_MEASURE_AVAILABILITY=1 to run it.")
            return
        }
        await RealStoreTestLock.shared.acquire()   // #2198: released inline on both paths, never a Task
        do {
            let fm = FileManager.default
            let dir = fm.temporaryDirectory
                .appendingPathComponent("availability-cost-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: dir) }

            guard let clone = try LiveStoreClone.makeClone(in: dir) else {
                throw LiveStoreClone.Refusal.backupFailed("no live store on this machine")
            }
            let schema = Schema([Prospect.self, Recipient.self, DayOff.self, CancelledShoot.self])
            let ctx = ModelContext(try ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(schema: schema, url: clone, cloudKitDatabase: .none)]))
            let exportURL = StoreLocation.handoffDirectory(appSupport: StoreLocation.appSupport,
                                                           isDebugBuild: false)
                .appendingPathComponent("downbeat-export.json")
            let read: () -> DayOffEditing.Export = {
                let l = DownbeatBridge.loadWithHealth(from: exportURL, now: Date())
                return (l.bookings, l.blockedDates, l.health)
            }
            let rounds = 50

            // BEFORE: what one body evaluation paid, exactly as `daysOffReason` spelled it.
            _ = ScoutService.blockedCalendar(export: read(), context: ctx)
            let before = Self.milliseconds(rounds: rounds) {
                _ = DaysOffAttention.reason(ScoutService.blockedCalendar(export: read(), context: ctx),
                                           feedStalled: false)
            }

            // AFTER: what one body evaluation pays now.
            let snapshot = AvailabilitySnapshot(loadExport: read)
            snapshot.attach(to: ctx)
            defer { snapshot.detach() }
            let buildsBefore = snapshot.builds
            let after = Self.milliseconds(rounds: rounds) {
                _ = DaysOffAttention.reason(snapshot.calendar, feedStalled: false)
            }

            let health = read().health
            print(String(format: "availability-cost: export %@, %d blocked days. One redraw of the "
                         + "toolbar mark paid %.3f ms BEFORE (a build per body evaluation) and %.4f ms "
                         + "AFTER (a read), with %d builds across %d redraws.",
                         String(describing: health), snapshot.calendar.days.count, before, after,
                         snapshot.builds - buildsBefore, rounds))

            #expect(snapshot.builds == buildsBefore, "a redraw built the calendar")
            #expect(!snapshot.calendar.days.isEmpty,
                    "the live calendar is empty, so the BEFORE figure timed an empty build (L102)")
            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }
}
