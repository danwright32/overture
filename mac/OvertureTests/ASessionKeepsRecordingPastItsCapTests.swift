import Testing
import Foundation

// #3812: a session must not stop WRITING to the freeze log when its in-memory kept set is full.
//
// WHAT WENT WRONG. `MainThreadWatchdog.recordIfStalled` wrote a record only when the kept set GREW:
//
//     let before = kept.records.count
//     kept = StallLog.adding(stall, to: kept)
//     return kept.records.count > before
//
// At the cap `adding` appends and then drops one, so the count goes 200, 201, 200 and `count > before`
// is false for ever after. The cap on what is HELD silently became a cap on what is WRITTEN, and the two
// are separate decisions that one comparison had tied together.
//
// MEASURED on Dan's own log plus its archive, 1,040 records over 10 sessions, 2026-09-12: three
// independent sessions sat on EXACTLY 200 records. Three sessions landing on the same round number is
// the cap, not the app. One of them (027CBFE2) last recorded at 18:17 and the next session did not start
// until 18:46, so roughly 29 minutes went unrecorded while the watchdog was still running and counting.
//
// WHY IT IS WORSE THAN A LOST DIAGNOSTIC. Milestone 80's bar is a distribution read off this file. A
// session that stops at its 200th stall makes every record in it one of the FIRST 200 stalls of that
// session, which is not a sample of the session, and the censoring is worst in exactly the sessions with
// the most stalls, which are the ones the milestone cares about (L216, L350). It reads like a full record
// and it is a truncated one.
//
// WHAT IS NOT THE CLAIM: that the cap is wrong. A bounded in-memory set is right and #3439's reason for
// it stands. The file has its own bound and its own archive (#3763), so what a compaction drops is kept
// rather than discarded, which is why writing every stall is safe.
@MainActor
@Suite("A session keeps recording past its cap (#3812)")
struct ASessionKeepsRecordingPastItsCapTests {

    private final class Records: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [StallRecord] = []
        func add(_ r: StallRecord) { lock.withLock { items.append(r) } }
        var all: [StallRecord] { lock.withLock { items } }
        var count: Int { lock.withLock { items.count } }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func bump() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    // The pairing is `OneFreezeIsOneRecordTests`'s, which is the rig this copies: a freeze far longer than
    // the interval, so the freeze is unambiguous, with everything around it waiting on a condition rather
    // than a clock (L290).
    private static let interval = 0.05
    private static let freeze = 0.8

    // THE DEFECT, driven through the real watchdog rather than reasoned about from the pure rule.
    //
    // The cap is ONE here, so the kept set is full after the first freeze and the second freeze is the
    // 201st stall of the shipped configuration. Reverting the fix makes this fail with the second freeze
    // never written.
    @Test func aStallPastTheCapIsStillWritten() async {
        let records = Records()
        let watchdog = MainThreadWatchdog(session: "past-the-cap", interval: Self.interval,
                                          loadReading: { (.baseline, 0) },
                                          cap: 1,
                                          record: { records.add($0) })
        watchdog.start()

        // A CONTROL, started with it and never stopped, so "long enough for a straggler to have landed" is
        // a condition rather than a duration (L290).
        let control = Counter()
        let controlDog = MainThreadWatchdog(session: "control", interval: Self.interval,
                                            now: { control.bump(); return Date() },
                                            loadReading: { (.baseline, 0) },
                                            record: { _ in })
        controlDog.start()
        _ = await waitUntil("both watchdogs to be ticking") { control.value >= 4 }

        DispatchQueue.main.async { Thread.sleep(forTimeInterval: Self.freeze) }
        let sawFirst = await waitUntil("the first freeze to be recorded", timeout: .seconds(30)) {
            records.count >= 1
        }
        let afterFirst = records.count

        let settleFrom = control.value
        _ = await waitUntil("the control to tick past the first drain", timeout: .seconds(30)) {
            control.value >= settleFrom + 20
        }

        DispatchQueue.main.async { Thread.sleep(forTimeInterval: Self.freeze) }
        let sawSecond = await waitUntil("the freeze past the cap to be recorded", timeout: .seconds(30)) {
            records.count > afterFirst
        }
        watchdog.stop()
        controlDog.stop()

        // POSITIVE CONTROL. Without this a machine that recorded NOTHING would satisfy nothing here and
        // the real assertion below would read as a pass over an empty measurement (L98, L159).
        #expect(sawFirst, "the first freeze was never recorded, so nothing here measured the cap at all")
        #expect(afterFirst >= 1, "the kept set was never filled, so the second freeze is not past the cap")
        #expect(sawSecond,
                Comment(rawValue: "the freeze past the cap wrote nothing. The session stopped recording "
                        + "at its \(1)st stall and said nothing, and a session that has gone quiet looks "
                        + "exactly like a session with no freezes (#3812, L98, L216)."))
    }

    // The same decision at the pure layer, where every outcome can be PRODUCED rather than waited for
    // (L151). This is what the watchdog above consults.
    @Test func afullKeptSetStillWrites() {
        var full = empty
        for i in 1...StallLog.cap {
            full = StallLog.adding(stall(sequence: i, seconds: 0.5), to: full).kept
        }
        #expect(full.records.count == StallLog.cap, "the kept set was not filled, so this tests nothing")

        let past = StallLog.adding(stall(sequence: StallLog.cap + 1, seconds: 0.5), to: full)

        #expect(past.write,
                Comment(rawValue: "a stall arriving at a full kept set was not written. What is HELD in "
                        + "memory and what is WRITTEN to the file are separate decisions (#3812)."))
        #expect(past.kept.evicted == 1, "the eviction did not happen, so the cap was not exercised")
    }

    // THE OTHER DIRECTION, and it is the one that makes the assertion above a rule rather than "always
    // write". A stall under the floor is COUNTED and never written, and a fix that wrote everything would
    // pass the test above while filling the file with sub-floor blips (L93).
    @Test func astallUnderTheFloorIsStillNotWritten() {
        let under = StallLog.adding(stall(sequence: 1, seconds: StallLog.floorSeconds / 4), to: empty)

        #expect(!under.write, "a stall under the floor was written, so the floor stopped being a floor")
        #expect(under.kept.belowFloor == 1, "it was not counted either, so it went nowhere at all")
    }

    // And the ordinary case, so the two above are not the only readings this rule has.
    @Test func astallOverTheFloorWithRoomToSpareIsWritten() {
        let ordinary = StallLog.adding(stall(sequence: 1, seconds: StallLog.floorSeconds * 2), to: empty)

        #expect(ordinary.write, "an ordinary stall with room in the kept set was not written")
        #expect(ordinary.kept.records.count == 1)
    }

    // The READER of the file names the cap too, and it cannot import Swift, so it holds a copy of the
    // number (`scripts/how-often-does-it-freeze.sh`, `CAP = 200`). That copy is what decides whether a
    // session is reported as possibly truncated, and a copy maintained by hand beside its source drifts
    // with no symptom at all: the reader would go on flagging 200 while the app capped at some other
    // number, and the flag would be about a population that no longer exists (L41, L70).
    //
    // Derived from the script's own text rather than restated here, so this fails when either side moves.
    @Test func thereaderNamesTheSameCapTheAppHolds() throws {
        let script = RepoRoot.url.appendingPathComponent("scripts/how-often-does-it-freeze.sh")
        let text = try String(contentsOf: script, encoding: .utf8)

        let line = text.split(separator: "\n").first { $0.hasPrefix("CAP = ") }
        let named = line.flatMap { Int($0.dropFirst("CAP = ".count).trimmingCharacters(in: .whitespaces)) }

        #expect(named != nil,
                Comment(rawValue: "no `CAP = <n>` line in \(script.lastPathComponent). The reader's own "
                        + "copy of the cap could not be found, so this guard measured nothing (L98)."))
        #expect(named == StallLog.cap,
                Comment(rawValue: "the reader names \(named.map(String.init) ?? "no") and the app "
                        + "holds \(StallLog.cap). A session is flagged as possibly truncated by "
                        + "comparing its record count against that number, so the two have to be one "
                        + "fact (#3812, L41)."))
    }

    private var empty: StallLog.Kept {
        StallLog.Kept(records: [], highWater: nil, evicted: 0, belowFloor: 0)
    }

    private func stall(sequence: Int, seconds: Double) -> StallRecord {
        StallRecord(session: "s", sequence: sequence, at: Date(timeIntervalSince1970: 1_000_000),
                    seconds: seconds, surface: .queue, load: .baseline, loadAverage: 1, passes: nil)
    }
}
