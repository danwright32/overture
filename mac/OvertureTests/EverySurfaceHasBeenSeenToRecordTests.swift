import Testing
import Foundation

// #3827: five surfaces were given a counted render pass by #3762, and for two months no record in Dan's
// log had ever named one of them.
//
// WHAT THE LIVE LOG SAID WHEN THIS ISSUE WAS FILED, 2026-09-11: 1,041 records across the live file and its
// archive, every single one `surface: queue`. Two readings fit that evidence and nothing separated them.
// Either Dan simply never had a sheet open during a stall, which is plausible because a sheet is open for
// minutes a day and the queue is open all day, or something stopped `presentedSurface` reaching the
// watchdog, in which case #3762's five bumps shipped inert. A monitor that has never once been seen to
// fire is measuring nothing until it has (L557, L3).
//
// WHAT IT SAYS NOW, re-read 2026-09-12 on the same two files: 1,659 records, 1,562 `queue` and 97
// `followUps`, 64 of the latter carrying a non-zero pass count. So the stamp reaches the watchdog and the record carries
// it, observed rather than argued, and the second reading is refuted for the mechanism as a whole. What is
// still true is that four of the six cases have never been observed in the wild, and they never will be
// on any schedule anybody controls: they are the surfaces Dan opens for minutes a day.
//
// SO THE OBSERVATION IS TAKEN HERE INSTEAD, for every case, on every run. That is the whole point of this
// file. A surface seen to fire once on Dan's Mac in September is not a property of the app; a surface seen
// to fire on every push is. And it is enumerated from `StallSurface.allCases` rather than from a list
// somebody maintains, so a seventh surface added next year is covered on the day it is declared and
// cannot arrive with nobody having watched it work (L96).
//
// WHAT IT DOES NOT COVER, said plainly rather than left for a reader to discover. This drives the box the
// main thread stamps, so it proves the watchdog reads what was stamped and writes it into the record. It
// does NOT prove that opening the Archive sheet sets `showArchive`, nor that `presentedSurface` maps that
// flag onto `.archive`: that half is source-derived and lives in `EveryRenderPassIsCountedTests`, which
// reads the `(flag, surface)` pairs straight out of `presentedSurface` and checks the view each one names.
// The two halves are deliberately in different files and derived from different things, because two guards
// drawing on one lookup can only ever prove that lookup is self-consistent (L70).
//
// HOW THE STALL IS MADE, and it is deliberately NOT the shape its two sibling suites use.
// `TheWatchdogCountsPassesTests` and `OneFreezeIsOneRecordTests` occupy the main queue with a real sleep,
// because what each of those is measuring IS a real span of main-thread time. Nothing here is: this asks
// only which surface a record carries, so a real freeze would be paying for the machine's load in the one
// place it buys nothing (L290, L524). The watchdog's `now` seam is set instead, to a clock that reads one
// step later on every call, so the ping's own arithmetic (`ran - posted - interval`) makes every ping late
// by `step - interval` with the main thread never blocked at all. Six surfaces cost about a tenth of a
// second rather than two and a half, and the reading cannot move with what else the Mac is doing (L224).
//
// WHAT THAT GIVES UP, named rather than left implicit: with a clock this obliging, this suite could not
// tell a watchdog that measures real main-thread lateness from one that records on every ping. It is not
// asked to. That is exactly what the two suites above hold, with a real sleep and a real main queue, and
// a proof of it here would be a second guard drawing on the same lookup (L70).
//
// Everything this suite WAITS for is waited on as a condition, never as a duration (L290).
@MainActor
@Suite("Every surface has been seen to reach a record (#3827)")
struct EverySurfaceHasBeenSeenToRecordTests {

    private final class Records: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [StallRecord] = []
        func add(_ r: StallRecord) { lock.withLock { items.append(r) } }
        var all: [StallRecord] { lock.withLock { items } }
    }

    // The clock the watchdog is given. Every reading is one STEP later than the last, which is what makes
    // a ping late without anything being slow: the watchdog reads `now()` once when it posts a ping and
    // once when that ping runs, so the delay it computes is always `step - interval`.
    //
    // A lock rather than a plain counter because the two reads happen on two different queues, which is
    // the whole arrangement being driven here.
    private final class SteppingClock: @unchecked Sendable {
        private let lock = NSLock()
        private var reading = Date(timeIntervalSince1970: 1_800_000_000)
        private let step: TimeInterval
        init(step: TimeInterval) { self.step = step }
        // Advances as it is read, deliberately. A clock a test advances by hand would need the advance to
        // land between the watchdog's two reads, which is a race this has no way to win.
        func take() -> Date { lock.withLock { reading += step; return reading } }
    }

    private static let interval = 0.02

    // Sized against the floor rather than picked, because a stall too short to be STORED would leave this
    // suite green while observing nothing (L98). The delay each ping records is `step - interval`, so at
    // 1.0 and 0.02 that is 0.98s against `StallLog.floorSeconds` of 0.1. Nothing about it is a duration
    // anybody waits through: this clock is read, not slept on.
    private static let step = 1.0

    private func watchdog(session: String, records: Records) -> MainThreadWatchdog {
        let clock = SteppingClock(step: Self.step)
        return MainThreadWatchdog(session: session, interval: Self.interval,
                                  now: { clock.take() },
                                  loadReading: { (.baseline, 0) },
                                  record: { records.add($0) })
    }

    // Every surface the app can attribute a stall to, from the enum rather than from a list here.
    //
    // `.notRecorded` is subtracted because it is the ABSENCE of a stamp rather than a surface anybody can
    // be looking at, and the test below drives it as exactly that: by never stamping. Written as the
    // reason for the exclusion rather than as one named case, so a second non-surface case added later is
    // covered by the same sentence rather than silently admitted (L362).
    private static var surfacesUnderTest: [StallSurface] {
        StallSurface.allCases.filter { $0 != .notRecorded }
    }

    // UNMEASURED is its own outcome. An enumeration that came back empty, or that lost a case to a
    // refactor, would make the loop below run fewer times and still report a clean pass, which is the
    // emptiest possible failure reading as the cleanest possible result (L98, L400).
    @Test func theEnumerationCoversEverySurfaceTheAppCanAttributeAStallTo() {
        let under = Self.surfacesUnderTest
        #expect(under.count == StallSurface.allCases.count - 1, """
        the enumeration dropped \(StallSurface.allCases.count - 1 - under.count) case(s), so the loop \
        below observes fewer surfaces than the app has
        """)
        // Named rather than counted as well, because a count is satisfied by any six cases. These are the
        // five sheets `presentedSurface` can return plus the queue underneath them.
        for expected in [StallSurface.queue, .archive, .followUps, .sourcesSheet, .organisations, .settings] {
            #expect(under.contains(expected), "\(expected.rawValue) is not among the surfaces observed here")
        }
    }

    // The observation itself, once per surface, end to end through the real watchdog.
    @Test func everySurfaceReachesARecordNamingItself() async {
        let records = Records()
        let watchdog = self.watchdog(session: "surfaces", records: records)
        watchdog.start()
        defer { watchdog.stop() }

        for surface in Self.surfacesUnderTest {
            // Stamped the way the main thread stamps it, then the next ping records a stall carrying
            // whatever the box holds. One surface is settled before the next is stamped, so a record can
            // never be attributed to a stamp made after the ping it belongs to was posted.
            watchdog.surface.stamp(surface)

            let seen = await waitUntil("a stall recorded on \(surface.rawValue)", timeout: .seconds(20)) {
                records.all.contains { $0.surface == surface }
            }
            #expect(seen, """
            no stall record ever named \(surface.rawValue), so a freeze on that surface would be \
            attributed to whatever was stamped before it. Records seen: \
            \(records.all.map(\.surface.rawValue).joined(separator: ", "))
            """)
        }
    }

    // The fourth state, and it is what lets every `queue` record in the live log be read as evidence.
    //
    // If the box defaulted to `.queue` rather than to `.notRecorded`, then a build that never stamped, or a
    // stall recorded before the first stamp landed, would say `queue` and be indistinguishable from a real
    // reading. The 1,562 `queue` records this milestone's before-and-after is taken across would then be
    // measuring nothing, and #3827's whole finding would be an artefact of the default (L11, L98).
    //
    // `PrivacyOfTheFreezeLogTests` asserts the DECLARATION reads `.notRecorded`; this asserts the
    // BEHAVIOUR, because a declaration says nothing about what reaches the file if something stamps on the
    // way (L3).
    @Test func aStallOnAWatchdogNothingEverStampedSaysSoRatherThanNamingTheQueue() async {
        let records = Records()
        let watchdog = self.watchdog(session: "unstamped", records: records)
        watchdog.start()
        defer { watchdog.stop() }

        await waitUntil("a stall to be recorded", timeout: .seconds(20)) { !records.all.isEmpty }

        #expect(records.all.allSatisfy { $0.surface == .notRecorded }, """
        a stall on a watchdog nothing ever stamped named a real surface, so every record in the live log \
        naming that surface could be this default rather than a reading
        """)
    }
}
