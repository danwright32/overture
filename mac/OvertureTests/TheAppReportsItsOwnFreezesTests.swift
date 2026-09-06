import Testing
import Foundation

// #3435 Phase 2e, with #3442. Every decision this feature makes, driven with no timer, no file and no
// clock of its own.
@Suite("The app records and reports its own freezes (#3435, #3442)")
struct TheAppReportsItsOwnFreezesTests {

    private func stall(_ seconds: Double, sequence: Int = 1,
                       surface: StallSurface = .queue, load: MachineLoad = .baseline,
                       at: Date = Date(timeIntervalSince1970: 1_785_000_000)) -> StallRecord {
        StallRecord(session: "s", sequence: sequence, at: at, seconds: seconds,
                    surface: surface, load: load, loadAverage: 1.0)
    }

    private var empty: StallLog.Kept { StallLog.Kept(records: [], highWater: nil, evicted: 0, belowFloor: 0) }

    // MARK: - the retention rule, which is #3435's own named defect

    // THE ONE THAT MATTERS. An evening of ordinary small stalls must not flush the one long entry out,
    // because the single reading this file exists to support is the MAXIMUM over a session and #3439
    // decides the whole deferred-architecture escalation from it (L191, L63).
    @Test("a run of small stalls after one big one still reports the big one")
    func theWorstStallSurvivesACapFullOfSmallOnes() {
        var kept = StallLog.adding(stall(58.0, sequence: 1), to: empty)
        for n in 0..<(StallLog.cap * 3) {
            kept = StallLog.adding(stall(0.3, sequence: n + 2), to: kept)
        }

        #expect(kept.records.count == StallLog.cap, "the detail log is not bounded")
        #expect(kept.evicted > 0, "nothing was evicted, so this did not exercise the cap at all")
        #expect(!kept.records.contains(where: { $0.seconds == 58.0 }),
                "the 58 second record survived in the detail log, so this test did not reach its own case")
        #expect(kept.highWater?.seconds == 58.0,
                Comment(rawValue: "the longest stall of the session was evicted by cheap ones, which is exactly what the "
                + "eviction count cannot tell you (L191, L63)"))
    }

    @Test("how many were dropped is recorded rather than merely happening")
    func theEvictionCountIsKept() {
        var kept = empty
        for n in 0..<(StallLog.cap + 7) { kept = StallLog.adding(stall(0.5, sequence: n), to: kept) }
        #expect(kept.evicted == 7)
    }

    // The FLOOR: below it a stall is counted and not stored. Both halves asserted, because a floor that
    // silently discarded them would make a session of constant small delays invisible.
    @Test("a stall under the floor is counted, not stored")
    func aStallUnderTheFloorIsCountedNotStored() {
        let kept = StallLog.adding(stall(StallLog.floorSeconds / 2), to: empty)
        #expect(kept.records.isEmpty)
        #expect(kept.belowFloor == 1)
    }

    // And it is still the session's worst if nothing bigger happened, which is the half a floor written
    // the obvious way gets wrong: a session whose worst stall is under the floor still HAS a worst stall,
    // and reporting none would say it was clean when what happened is that nothing crossed a line (L98).
    @Test("a session whose worst stall is under the floor still has one")
    func theHighWaterIsJudgedBeforeTheFloor() {
        let kept = StallLog.adding(stall(0.1), to: empty)
        #expect(kept.highWater?.seconds == 0.1)
        #expect(kept.records.isEmpty)
    }

    @Test("the floor is one ping interval, and says so")
    func theFloorIsOnePingInterval() {
        #expect(StallLog.floorSeconds == MainThreadWatchdog.pingInterval,
                Comment(rawValue: "the floor is no longer one ping interval, so the number in its comment is now a claim "
                + "about nothing (L32)"))
    }

    // MARK: - the file

    @Test("a record round trips through the file format")
    func aRecordRoundTrips() throws {
        let record = stall(1.25, sequence: 4, surface: .archive, load: .elevated)
        let line = try #require(FreezeLog.line(for: record))
        let read = FreezeLog.read(line)
        #expect(read.records == [record])
        #expect(read.unreadableLines == 0)
    }

    // A file half-written by a process killed mid-freeze is exactly the file this exists to hold, so an
    // unreadable tail is an ordinary state and must be COUNTED rather than dropped (L98).
    @Test("a half written line is counted rather than dropped in silence")
    func aHalfWrittenLineIsCounted() throws {
        let good = try #require(FreezeLog.line(for: stall(1.0)))
        let read = FreezeLog.read(good + "\n{\"session\":\"s\",\"seq")
        #expect(read.records.count == 1)
        #expect(read.unreadableLines == 1)
    }

    @Test("an absent file is its own state, never an empty one")
    func anAbsentFileIsItsOwnState() {
        let read = FreezeLog.read(at: URL(fileURLWithPath: "/nonexistent/freeze-log.ndjson"))
        #expect(read.fileWasAbsent)
        #expect(read.records.isEmpty)
    }

    // MARK: - the reader, and its four states

    private func defaults(_ name: String) -> UserDefaults {
        let d = UserDefaults(suiteName: "freeze-report-\(name)-\(UUID().uuidString)")!
        return d
    }

    // THE STATE THIS DESIGN TURNS ON. A file with nothing in it means EITHER that nothing froze OR that
    // nothing was watching, and those are the two most different answers available (L98, L11).
    @Test("a session with no watchdog says so, and never reports a count")
    func noWatchdogIsItsOwnSentence() {
        let said = FreezeReport.newlyReported(in: URL(fileURLWithPath: "/tmp"), watchdogRan: false,
                                              defaults: defaults("nowatchdog"),
                                              read: { _ in FreezeLog.Read() })
        #expect(said == FreezeNoticeCopy.watchdogDidNotRun)
        // And it is not a count of nothing, which is the fold this state exists to avoid.
        #expect(said?.contains("stopped responding for") == false)
    }

    @Test("a watched session with no freezes says nothing")
    func aCleanSessionSaysNothing() {
        let said = FreezeReport.newlyReported(in: URL(fileURLWithPath: "/tmp"), watchdogRan: true,
                                              defaults: defaults("clean"),
                                              read: { _ in FreezeLog.Read() })
        #expect(said == nil)
    }

    @Test("freezes are reported once, with the longest named")
    func freezesAreReportedOnceWithTheLongestNamed() {
        let d = defaults("once")
        var read = FreezeLog.Read()
        read.records = [stall(0.8, sequence: 1), stall(6.6, sequence: 2, surface: .archive)]

        let first = FreezeReport.newlyReported(in: URL(fileURLWithPath: "/tmp"), watchdogRan: true,
                                               defaults: d, read: { _ in read })
        let said = try! #require(first)
        // "2 times" rather than "twice", matching `RunBoundaryViolations`'s existing "once / N times"
        // idiom: this notice sits in the same slot as that one, and two ways of counting in one place is
        // one word naming two things (L118).
        #expect(said.contains("2 times"))
        #expect(said.contains("The longest was"))
        #expect(said.contains("6.6 seconds"))
        #expect(said.contains("The archive was on screen."))

        // ONCE. A message that reappears on every launch teaches him to skim past it.
        let second = FreezeReport.newlyReported(in: URL(fileURLWithPath: "/tmp"), watchdogRan: true,
                                                defaults: d, read: { _ in read })
        #expect(second == nil)
    }

    @Test("a freeze after the last report is reported, and the earlier ones are not repeated")
    func onlyTheNewOnesAreReported() {
        let d = defaults("new")
        var read = FreezeLog.Read()
        read.records = [stall(0.8, sequence: 1)]
        _ = FreezeReport.newlyReported(in: URL(fileURLWithPath: "/tmp"), watchdogRan: true,
                                       defaults: d, read: { _ in read })

        read.records.append(stall(2.0, sequence: 2))
        let said = try! #require(FreezeReport.newlyReported(in: URL(fileURLWithPath: "/tmp"),
                                                           watchdogRan: true, defaults: d,
                                                           read: { _ in read }))
        #expect(!said.contains("times"), "the earlier freeze was reported a second time")
        #expect(said.contains("stopped responding for 2.0 seconds"),
                "a single freeze does not read as one: it borrows the plural sentence's wording")
    }

    // #3435's fourth record state, in the sentence rather than swallowed.
    @Test("a freeze whose surface was never stamped says so")
    func anUnstampedSurfaceSaysSo() {
        var read = FreezeLog.Read()
        read.records = [stall(1.0, surface: .notRecorded)]
        let said = try! #require(FreezeReport.newlyReported(in: URL(fileURLWithPath: "/tmp"),
                                                            watchdogRan: true, defaults: defaults("nosurface"),
                                                            read: { _ in read }))
        #expect(said.contains("Nothing recorded which screen was open."))
        // And it is NOT the same sentence as a freeze with no window open, which is ordinary for a menu
        // bar app rather than a gap (L11).
        #expect(FreezeNoticeCopy.surfaceSentence(.notRecorded) != FreezeNoticeCopy.surfaceSentence(.noWindow))
    }

    // #3442: the caveat is carried into the sentence, because work done to fix a freeze that was really a
    // loaded machine is unfalsifiable and can never be shown to have worked.
    @Test("a freeze on a busy Mac carries that caveat, and a quiet one does not")
    func theLoadCaveatIsCarried() {
        #expect(FreezeNoticeCopy.loadClause(.baseline).isEmpty)
        #expect(FreezeNoticeCopy.loadClause(.elevated).contains("busy with something else"))
        #expect(FreezeNoticeCopy.loadClause(.unmeasured).contains("could not be read"))
        #expect(FreezeNoticeCopy.loadClause(.elevated) != FreezeNoticeCopy.loadClause(.unmeasured),
                "a busy Mac and an unreadable one say the same thing, which is the fold L98 forbids")
    }

    @Test("unreadable entries are mentioned rather than hidden")
    func unreadableEntriesAreMentioned() {
        var read = FreezeLog.Read()
        read.records = [stall(1.0)]
        read.unreadableLines = 3
        let said = try! #require(FreezeReport.newlyReported(in: URL(fileURLWithPath: "/tmp"),
                                                            watchdogRan: true, defaults: defaults("unreadable"),
                                                            read: { _ in read }))
        #expect(said.contains("3 earlier records could not be read"))
    }

    // A record the app could not WRITE is the one state worse than a freeze, because the file is then not
    // the evidence anybody thinks it is. Said FIRST and on its own, or an unwritable file reads as a quiet
    // session (L11, L13, L95). The push gate's own lessons check is what asked for this: `FreezeLog.append`
    // answers false when it cannot write and the first version of `FreezeWatch` discarded that answer.
    @Test("a freeze the app could not write down says so, ahead of anything else")
    func aFailedWriteIsSaidFirst() {
        let said = FreezeReport.newlyReported(in: URL(fileURLWithPath: "/tmp"), watchdogRan: true,
                                              writesThatFailed: 2, defaults: defaults("failed"),
                                              read: { _ in FreezeLog.Read() })
        #expect(said == FreezeNoticeCopy.writesFailed(2))
        #expect(said?.contains("could not write") == true)
    }

    // And it outranks a report of freezes that WERE written, because a partial file is the misleading
    // case: a count taken from it is a count of what survived rather than of what happened.
    @Test("a failed write outranks the ordinary report")
    func aFailedWriteOutranksTheReport() {
        var read = FreezeLog.Read()
        read.records = [stall(1.0, sequence: 1)]
        let said = FreezeReport.newlyReported(in: URL(fileURLWithPath: "/tmp"), watchdogRan: true,
                                              writesThatFailed: 1, defaults: defaults("outranks"),
                                              read: { _ in read })
        #expect(said?.contains("could not write") == true)
        #expect(said?.contains("1.0 seconds") == false)
    }

    @Test("one failed write and several read differently")
    func theFailedWriteCountIsSingularOrPlural() {
        #expect(FreezeNoticeCopy.writesFailed(1).contains("at least once"))
        #expect(FreezeNoticeCopy.writesFailed(3).contains("3 times"))
    }

    // #3439's reader, which is the SECOND one this phase requires: the floor, asked for rather than
    // waited for.
    @Test("the longest stall can be asked for")
    func theFloorCanBeAskedFor() {
        var read = FreezeLog.Read()
        read.records = [stall(0.4, sequence: 1), stall(58.0, sequence: 2), stall(1.1, sequence: 3)]
        let worst = FreezeReport.floor(in: URL(fileURLWithPath: "/tmp"), read: { _ in read })
        #expect(worst?.seconds == 58.0)
    }

    // MARK: - #3442's classification

    @Test("the load class is derived from the core count, not a round number")
    func theLoadClassIsPerCore() {
        #expect(MachineLoadReading.classify(4.0, cores: 12) == .baseline)
        #expect(MachineLoadReading.classify(13.01, cores: 12) == .elevated,
                "the reading #3442 recorded as genuinely loaded reads as quiet")
        #expect(MachineLoadReading.classify(1.5, cores: 1) == .elevated)
        #expect(MachineLoadReading.classify(.nan, cores: 12) == .unmeasured)
        #expect(MachineLoadReading.classify(-1, cores: 12) == .unmeasured)
    }

}
