import Testing
import Foundation

// #4335 (A6, L459): a stall recorded while Overture finished an interrupted landing at idle, with nobody at the
// Mac, is IDLE WORK. The watchdog stamps it with the interrupted landing's sequence number and the input idle seconds the
// recovery measured when it started; a stall outside a recovery carries neither; and every reader keeps the two
// apart, so a recovery's hold never enters the freeze distribution milestone 80's bar is read from.
//
// Driven through a REAL freeze on the main thread, as `TheWatchdogCountsPassesTests` does, because what is
// tested is the wiring from the box the main thread stamps to the record the watchdog writes.
@Suite("A stall during an idle landing recovery is recorded as idle work (#4335)")
struct IdleRecoveryStallsAreIdleWorkTests {
    private final class Records: @unchecked Sendable {
        private let lock = NSLock()
        private var records: [StallRecord] = []
        func add(_ r: StallRecord) { lock.withLock { records.append(r) } }
        var all: [StallRecord] { lock.withLock { records } }
    }

    private static let interval = 0.05
    private static let freeze = 0.6

    private func freezeOnce(stamping work: MainThreadWatchdog.IdleWork?) async -> [StallRecord] {
        let records = Records()
        let watchdog = MainThreadWatchdog(session: "idle-work", interval: Self.interval,
                                          loadReading: { (.baseline, 0) },
                                          record: { records.add($0) })
        watchdog.idleWork.stamp(work)
        watchdog.start()
        let freeze = Self.freeze
        DispatchQueue.main.async { Thread.sleep(forTimeInterval: freeze) }
        await waitUntil("a stall to be recorded", timeout: .seconds(20)) { !records.all.isEmpty }
        watchdog.stop()
        return records.all
    }

    @Test func aStallDuringARecoveryCarriesItsRunAndTheIdleSeconds() async {
        let records = await freezeOnce(stamping: .init(recoverySequence: 41, inputIdleSeconds: 240))
        #expect(!records.isEmpty)
        #expect(records.allSatisfy { $0.recoverySequence == 41 && $0.inputIdleSeconds == 240 })
    }

    // The recovery clears its stamp the moment its replay returns, which is before the ping that measures the
    // stall gets its turn on the main thread. A stall that began inside the replay is still idle work.
    @Test func aStallWhoseRecoveryEndedBeforeThePingRanIsStillIdleWork() async {
        let records = Records()
        let watchdog = MainThreadWatchdog(session: "idle-work-ended", interval: Self.interval,
                                          loadReading: { (.baseline, 0) },
                                          record: { records.add($0) })
        watchdog.idleWork.stamp(.init(recoverySequence: 42, inputIdleSeconds: 200))
        watchdog.start()
        let freeze = Self.freeze
        let box = watchdog.idleWork
        DispatchQueue.main.async {
            Thread.sleep(forTimeInterval: freeze)
            box.stamp(nil)   // the replay returned, still inside this turn of the main thread
        }
        await waitUntil("a stall to be recorded", timeout: .seconds(20)) { !records.all.isEmpty }
        watchdog.stop()
        #expect(records.all.contains { $0.recoverySequence == 42 }, Comment(rawValue:
            "the stall of a replay that had just ended was recorded as a freeze: \(records.all.map(\.recoverySequence))"))
    }

    // The other end. A freeze already under way when a recovery starts is a freeze Dan could have felt, so it
    // is judged by the state when its ping was POSTED, never by a stamp that arrived while it was blocked.
    // Erring this way can only count idle work as a freeze, the harmless direction (L648); the other way
    // would take a real freeze out of milestone 80's distribution.
    @Test func aFreezeARecoveryStartedDuringIsStillAFreeze() async {
        let records = Records()
        let watchdog = MainThreadWatchdog(session: "idle-work-started-late", interval: Self.interval,
                                          loadReading: { (.baseline, 0) },
                                          record: { records.add($0) })
        watchdog.start()
        let freeze = Self.freeze
        let box = watchdog.idleWork
        DispatchQueue.main.async {
            Thread.sleep(forTimeInterval: freeze)   // the ping is posted while this blocks, with no stamp
            box.stamp(.init(recoverySequence: 45, inputIdleSeconds: 150))
            Thread.sleep(forTimeInterval: freeze)
        }
        await waitUntil("a stall to be recorded", timeout: .seconds(20)) { !records.all.isEmpty }
        watchdog.stop()
        box.stamp(nil)
        let first = records.all.first
        #expect(first?.recoverySequence == nil, Comment(rawValue:
            "a freeze under way before the recovery started was recorded as idle work: \(records.all.map(\.recoverySequence))"))
    }

    // #3439's gate reads the session's worst stall through two readers, the in-memory high water and the
    // file's longest record. Idle work is in neither, or one recovery's hold would decide the escalation.
    @Test func idleWorkNeverSetsTheWorstStallTheGateReads() {
        func record(_ sequence: Int, _ seconds: Double, idle: Bool) -> StallRecord {
            StallRecord(session: "gate", sequence: sequence,
                        at: Date(timeIntervalSince1970: 1_790_000_000 + Double(sequence)), seconds: seconds,
                        surface: .queue, load: .baseline, loadAverage: 3, passes: 1,
                        recoverySequence: idle ? 46 : nil, inputIdleSeconds: idle ? 300 : nil)
        }
        var kept = StallLog.Kept(records: [], highWater: nil, evicted: 0, belowFloor: 0)
        kept = StallLog.adding(record(1, 1.2, idle: false), to: kept).kept
        let admitted = StallLog.adding(record(2, 9.8, idle: true), to: kept)
        #expect(admitted.kept.highWater?.seconds == 1.2,
                Comment(rawValue: "an idle stall became the session's worst: \(String(describing: admitted.kept.highWater))"))
        #expect(admitted.write, "idle work is still written to the file, where every reader can set it apart")

        let read = FreezeLog.Read(records: [record(1, 1.2, idle: false), record(2, 9.8, idle: true)])
        let worst = FreezeReport.floor(in: URL(fileURLWithPath: NSTemporaryDirectory()), read: { _ in read })
        #expect(worst?.seconds == 1.2, Comment(rawValue: "the file's longest was idle work: \(String(describing: worst))"))
    }

    @Test func aStallOutsideARecoveryCarriesNeither() async {
        let records = await freezeOnce(stamping: nil)
        #expect(!records.isEmpty)
        #expect(records.allSatisfy { $0.recoverySequence == nil && $0.inputIdleSeconds == nil })
    }

    // Absent on every record written before this shipped, and written only when present, so the records
    // already on Dan's Mac read back unchanged and an ordinary record grows by nothing.
    @Test func theFieldsRoundTripAndAreAbsentFromAnOrdinaryRecord() throws {
        let plain = StallRecord(session: "s", sequence: 1, at: Date(timeIntervalSince1970: 1_790_000_000),
                                seconds: 1.5, surface: .queue, load: .baseline, loadAverage: 3, passes: 0)
        let idle = StallRecord(session: "s", sequence: 2, at: Date(timeIntervalSince1970: 1_790_000_010),
                               seconds: 3.6, surface: .queue, load: .baseline, loadAverage: 3, passes: 0,
                               recoverySequence: 43, inputIdleSeconds: 180)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let plainText = String(decoding: try encoder.encode(plain), as: UTF8.self)
        #expect(!plainText.contains("recoverySequence") && !plainText.contains("inputIdleSeconds"))
        let back = try decoder.decode(StallRecord.self, from: try encoder.encode(idle))
        #expect(back.recoverySequence == 43 && back.inputIdleSeconds == 180)
    }

    // The launch report keeps idle work out of the freeze count and the longest freeze, and says it apart.
    @Test func theLaunchReportCountsIdleWorkApartFromFreezes() throws {
        func record(_ sequence: Int, _ seconds: Double, idle: Bool) -> StallRecord {
            StallRecord(session: "launch-report", sequence: sequence,
                        at: Date(timeIntervalSince1970: 1_790_000_000 + Double(sequence)), seconds: seconds,
                        surface: .queue, load: .baseline, loadAverage: 3, passes: 1,
                        recoverySequence: idle ? 44 : nil, inputIdleSeconds: idle ? 300 : nil)
        }
        let records = [record(1, 1.2, idle: false), record(2, 9.8, idle: true), record(3, 0.4, idle: false)]
        let defaults = ScratchDefaults.make("IdleRecoveryStallsAreIdleWorkTests")
        let said = FreezeReport.newlyReported(
            in: URL(fileURLWithPath: NSTemporaryDirectory()), watchdogRan: true, defaults: defaults,
            sources: .init(live: { _ in FreezeLog.Read(records: records) },
                           archive: { _, _ in FreezeLog.ArchiveTail(records: []) }))
        let line = try #require(said)
        #expect(line.contains("stopped responding 2 times. The longest was 1.2 seconds."), Comment(rawValue: line))
        #expect(line.contains(FreezeNoticeCopy.idleWork(count: 1, longestSeconds: 9.8)), Comment(rawValue: line))
    }
}
