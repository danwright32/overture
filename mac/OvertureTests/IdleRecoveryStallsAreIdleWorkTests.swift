import Testing
import Foundation

// #4335 (A6, L459): a stall recorded while Overture finished an interrupted landing at idle, with nobody at the
// Mac, is IDLE WORK. The watchdog stamps it with the recovery's run identity and the input idle seconds the
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
        let records = await freezeOnce(stamping: .init(recoveryRunID: "recovered-run", inputIdleSeconds: 240))
        #expect(!records.isEmpty)
        #expect(records.allSatisfy { $0.recoveryRunID == "recovered-run" && $0.inputIdleSeconds == 240 })
    }

    @Test func aStallOutsideARecoveryCarriesNeither() async {
        let records = await freezeOnce(stamping: nil)
        #expect(!records.isEmpty)
        #expect(records.allSatisfy { $0.recoveryRunID == nil && $0.inputIdleSeconds == nil })
    }

    // Absent on every record written before this shipped, and written only when present, so the records
    // already on Dan's Mac read back unchanged and an ordinary record grows by nothing.
    @Test func theFieldsRoundTripAndAreAbsentFromAnOrdinaryRecord() throws {
        let plain = StallRecord(session: "s", sequence: 1, at: Date(timeIntervalSince1970: 1_790_000_000),
                                seconds: 1.5, surface: .queue, load: .baseline, loadAverage: 3, passes: 0)
        let idle = StallRecord(session: "s", sequence: 2, at: Date(timeIntervalSince1970: 1_790_000_010),
                               seconds: 3.6, surface: .queue, load: .baseline, loadAverage: 3, passes: 0,
                               recoveryRunID: "r", inputIdleSeconds: 180)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let plainText = String(decoding: try encoder.encode(plain), as: UTF8.self)
        #expect(!plainText.contains("recoveryRunID") && !plainText.contains("inputIdleSeconds"))
        let back = try decoder.decode(StallRecord.self, from: try encoder.encode(idle))
        #expect(back.recoveryRunID == "r" && back.inputIdleSeconds == 180)
    }

    // The launch report keeps idle work out of the freeze count and the longest freeze, and says it apart.
    @Test func theLaunchReportCountsIdleWorkApartFromFreezes() throws {
        func record(_ sequence: Int, _ seconds: Double, idle: Bool) -> StallRecord {
            StallRecord(session: "launch-report", sequence: sequence,
                        at: Date(timeIntervalSince1970: 1_790_000_000 + Double(sequence)), seconds: seconds,
                        surface: .queue, load: .baseline, loadAverage: 3, passes: 1,
                        recoveryRunID: idle ? "r" : nil, inputIdleSeconds: idle ? 300 : nil)
        }
        let records = [record(1, 1.2, idle: false), record(2, 9.8, idle: true), record(3, 0.4, idle: false)]
        let defaults = try #require(UserDefaults(suiteName: "IdleRecoveryStallsAreIdleWorkTests-\(UUID().uuidString)"))
        let said = FreezeReport.newlyReported(
            in: URL(fileURLWithPath: NSTemporaryDirectory()), watchdogRan: true, defaults: defaults,
            sources: .init(live: { _ in FreezeLog.Read(records: records) },
                           archive: { _, _ in FreezeLog.ArchiveTail(records: []) }))
        let line = try #require(said)
        #expect(line.contains("stopped responding 2 times. The longest was 1.2 seconds."), Comment(rawValue: line))
        #expect(line.contains(FreezeNoticeCopy.idleWork(count: 1, longestSeconds: 9.8)), Comment(rawValue: line))
    }
}
