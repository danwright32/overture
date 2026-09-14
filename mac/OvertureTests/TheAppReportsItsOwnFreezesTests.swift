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
                    surface: surface, load: load, loadAverage: 1.0, passes: nil)
    }

    private var empty: StallLog.Kept { StallLog.Kept(records: [], highWater: nil, evicted: 0, belowFloor: 0) }

    // MARK: - the retention rule, which is #3435's own named defect

    // THE ONE THAT MATTERS. An evening of ordinary small stalls must not flush the one long entry out,
    // because the single reading this file exists to support is the MAXIMUM over a session and #3439
    // decides the whole deferred-architecture escalation from it (L191, L63).
    @Test("a run of small stalls after one big one still reports the big one")
    func theWorstStallSurvivesACapFullOfSmallOnes() {
        var kept = StallLog.adding(stall(58.0, sequence: 1), to: empty).kept
        for n in 0..<(StallLog.cap * 3) {
            kept = StallLog.adding(stall(0.3, sequence: n + 2), to: kept).kept
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
        for n in 0..<(StallLog.cap + 7) { kept = StallLog.adding(stall(0.5, sequence: n), to: kept).kept }
        #expect(kept.evicted == 7)
    }

    // The FLOOR: below it a stall is counted and not stored. Both halves asserted, because a floor that
    // silently discarded them would make a session of constant small delays invisible.
    @Test("a stall under the floor is counted, not stored")
    func aStallUnderTheFloorIsCountedNotStored() {
        let kept = StallLog.adding(stall(StallLog.floorSeconds / 2), to: empty).kept
        #expect(kept.records.isEmpty)
        #expect(kept.belowFloor == 1)
    }

    // And it is still the session's worst if nothing bigger happened, which is the half a floor written
    // the obvious way gets wrong: a session whose worst stall is under the floor still HAS a worst stall,
    // and reporting none would say it was clean when what happened is that nothing crossed a line (L98).
    @Test("a session whose worst stall is under the floor still has one")
    func theHighWaterIsJudgedBeforeTheFloor() {
        // #3752: DERIVED from the floor, like the test above it, rather than a literal. This said `0.1`,
        // which was comfortably under a floor of 0.25 and is exactly AT a floor of 0.1, so lowering the
        // floor turned the fixture into the opposite case and the test failed for a reason that had
        // nothing to do with what it asserts (L401: a fixture whose meaning is its relationship to a
        // configurable threshold must be derived from that threshold, not written as a literal chosen to
        // sit under it).
        let under = StallLog.floorSeconds / 2
        let kept = StallLog.adding(stall(under), to: empty).kept
        #expect(kept.highWater?.seconds == under)
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

    // #3851: a reader that answers the LIVE log and reports NO ARCHIVE beside it.
    //
    // These fixtures used to pass `read: liveOnly(read)`, a double that ignores the URL it is given. That
    // was harmless while the reader opened one file and became wrong the moment it opened two: the same
    // records answered for both, so every freeze was counted twice. A double that ignores its argument
    // describes no file in particular, and it stops being a double at all when the thing under test starts
    // asking a second question (L143).
    //
    // Named rather than inlined at seventeen call sites, so the next file this reader learns to open is
    // one change here rather than seventeen.
    private func liveOnly(_ live: FreezeLog.Read, support: URL = URL(fileURLWithPath: "/tmp"))
        -> (URL) -> FreezeLog.Read {
        var absent = FreezeLog.Read()
        absent.fileWasAbsent = true
        let archive = FreezeLog.archiveURL(besideLogAt: FreezeLog.url(in: support))
        return { $0 == archive ? absent : live }
    }

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
                                              read: liveOnly(FreezeLog.Read()))
        #expect(said == FreezeNoticeCopy.watchdogDidNotRun)
        // And it is not a count of nothing, which is the fold this state exists to avoid.
        #expect(said?.contains("stopped responding for") == false)
    }

    @Test("a watched session with no freezes says nothing")
    func aCleanSessionSaysNothing() {
        let said = FreezeReport.newlyReported(in: URL(fileURLWithPath: "/tmp"), watchdogRan: true,
                                              defaults: defaults("clean"),
                                              read: liveOnly(FreezeLog.Read()))
        #expect(said == nil)
    }

    @Test("freezes are reported once, with the longest named")
    func freezesAreReportedOnceWithTheLongestNamed() {
        let d = defaults("once")
        var read = FreezeLog.Read()
        read.records = [stall(0.8, sequence: 1), stall(6.6, sequence: 2, surface: .archive)]

        let first = FreezeReport.newlyReported(in: URL(fileURLWithPath: "/tmp"), watchdogRan: true,
                                               defaults: d, read: liveOnly(read))
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
                                                defaults: d, read: liveOnly(read))
        #expect(second == nil)
    }

    // MARK: - #3851: the archive is part of what Dan is told about

    // WHAT WAS RECORDED AND WHY IT IS OVERTURNED, because this reverses a decision written into
    // `FreezeReport` itself rather than filling a gap nobody had considered (L61, L249, #3077).
    //
    // That comment said the reader "deliberately ignores" the archive, "because the launch notice wants
    // the last session's shape while the archive exists for the population". That reasoning held while a
    // session could not fill the live file on its own: the records a compaction moved out had been
    // reported at an earlier launch, so ignoring them lost nothing.
    //
    // #3812 ended that. Before it a session stopped writing at its 200th stall, so 500 records spanned
    // several sessions. Writing every stall means ONE heavy session can write past the cap, and its own
    // records are then compacted into the archive before any launch has ever read them. They are lost to
    // the notice permanently, and the loss is worst in exactly the sessions that froze most (L216, L350).
    //
    // MEASURED on Dan's own files, 2026-09-12: 700 records live against a cap of 500, and 780 already in
    // the archive. Every one of those 780 is invisible to this reader.
    //
    // What the recorded decision got RIGHT is kept: the notice is still about what has not been said, not
    // about the whole history, and `scripts/what-froze-the-queue.sh` is still the reader for the
    // population. The only change is that a record's having been archived no longer counts as having been
    // said.
    private func archiveURL(besideLogIn support: URL) -> URL {
        FreezeLog.archiveURL(besideLogAt: FreezeLog.url(in: support))
    }

    @Test("a freeze that was archived before it could be reported is still reported")
    func anArchivedFreezeIsStillReported() throws {
        let d = defaults("archived")
        let support = URL(fileURLWithPath: "/tmp")
        var live = FreezeLog.Read()
        live.records = [stall(0.8, sequence: 900)]
        var archived = FreezeLog.Read()
        archived.records = [stall(9.9, sequence: 1, surface: .archive)]

        let said = try #require(FreezeReport.newlyReported(
            in: support, watchdogRan: true, defaults: d,
            read: { $0 == self.archiveURL(besideLogIn: support) ? archived : live }))

        #expect(said.contains("2 times"),
                Comment(rawValue: "the archived freeze was not counted, so a compaction takes freezes "
                        + "off what Dan is ever told (#3851). Said: \(said)"))
        #expect(said.contains("9.9 seconds"),
                Comment(rawValue: "the LONGEST freeze was the archived one and the notice named a "
                        + "shorter one, so the worst thing that happened went unsaid (#3851)."))
    }

    // AND ONCE. This is the half that makes the change safe rather than noisy: if the identities written
    // back covered only the live file, every archived record would be fresh again at the next launch and
    // the notice would repeat for ever, which teaches Dan to skim past it (L36).
    @Test("an archived freeze is reported once, not at every launch")
    func anArchivedFreezeIsNotRepeated() throws {
        let d = defaults("archived-once")
        let support = URL(fileURLWithPath: "/tmp")
        var live = FreezeLog.Read()
        live.records = [stall(0.8, sequence: 900)]
        var archived = FreezeLog.Read()
        archived.records = [stall(9.9, sequence: 1, surface: .archive)]
        let reader: (URL) -> FreezeLog.Read = { $0 == self.archiveURL(besideLogIn: support) ? archived : live }

        _ = try #require(FreezeReport.newlyReported(in: support, watchdogRan: true, defaults: d, read: reader))
        let second = FreezeReport.newlyReported(in: support, watchdogRan: true, defaults: d, read: reader)

        #expect(second == nil,
                Comment(rawValue: "the archived freeze was reported a second time, so the notice repeats "
                        + "at every launch (#3851, L36). Said: \(second ?? "nil")"))
    }

    // The ORDINARY state, which is most installs: no archive beside the log at all, because nothing has
    // ever compacted. It must read as absent rather than as an error or an empty finding (L98).
    @Test("no archive beside the log changes nothing")
    func noArchiveIsTheOrdinaryState() throws {
        let d = defaults("no-archive")
        let support = URL(fileURLWithPath: "/tmp")
        var live = FreezeLog.Read()
        live.records = [stall(3.3, sequence: 1)]
        var absent = FreezeLog.Read()
        absent.fileWasAbsent = true

        let said = try #require(FreezeReport.newlyReported(
            in: support, watchdogRan: true, defaults: d,
            read: { $0 == self.archiveURL(besideLogIn: support) ? absent : live }))

        #expect(said.contains("3.3 seconds"),
                Comment(rawValue: "the one live freeze was not reported. Said: \(said)"))
    }

    @Test("a freeze after the last report is reported, and the earlier ones are not repeated")
    func onlyTheNewOnesAreReported() {
        let d = defaults("new")
        var read = FreezeLog.Read()
        read.records = [stall(0.8, sequence: 1)]
        _ = FreezeReport.newlyReported(in: URL(fileURLWithPath: "/tmp"), watchdogRan: true,
                                       defaults: d, read: liveOnly(read))

        read.records.append(stall(2.0, sequence: 2))
        let said = try! #require(FreezeReport.newlyReported(in: URL(fileURLWithPath: "/tmp"),
                                                           watchdogRan: true, defaults: d,
                                                           read: liveOnly(read)))
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
                                                            read: liveOnly(read)))
        #expect(said.contains("Nothing recorded which screen was open."))
        // And it is NOT the same sentence as any surface that IS known, which is the fold L11 forbids.
        #expect(FreezeNoticeCopy.surfaceSentence(.notRecorded) != FreezeNoticeCopy.surfaceSentence(.queue))
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
                                                            read: liveOnly(read)))
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
                                              read: liveOnly(FreezeLog.Read()))
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
                                              read: liveOnly(read))
        #expect(said?.contains("could not write") == true)
        #expect(said?.contains("1.0 seconds") == false)
    }

    @Test("one failed write and several read differently")
    func theFailedWriteCountIsSingularOrPlural() {
        #expect(FreezeNoticeCopy.writesFailed(1).contains("at least once"))
        #expect(FreezeNoticeCopy.writesFailed(3).contains("3 times"))
    }

    // THE ONE THE REAL DATA FOUND, and it is the defect that would have silently ended this whole
    // feature after one launch.
    //
    // `sequence` restarts at 1 in every process: it is a counter on the watchdog instance, and a new
    // instance is made each launch. A reader that remembers "reported through sequence N" therefore
    // matches NOTHING in the next session, because that session's numbers all start below N again. The
    // app would say nothing about every freeze it ever recorded after the first session, and saying
    // nothing is exactly what a healthy session looks like (L98).
    //
    // Found on 2026-09-06 by looking at Dan's real log after ten minutes of use: one session, sequences
    // 1 to 3412. The next launch would have started again at 1.
    @Test("a freeze in a LATER session is reported, even though its sequence starts again at 1")
    func freezesAreReportedAcrossLaunches() {
        let d = defaults("relaunch")
        let firstSession = FreezeLog.Read(records: [
            stall(1.0, sequence: 1, at: Date(timeIntervalSince1970: 1_785_000_000)),
            stall(2.0, sequence: 2, at: Date(timeIntervalSince1970: 1_785_000_001)),
        ])
        _ = FreezeReport.newlyReported(in: URL(fileURLWithPath: "/tmp"), watchdogRan: true,
                                       defaults: d, read: liveOnly(firstSession))

        // A NEW launch. Its own sequence starts at 1 again, and its records are LATER in time.
        var afterRelaunch = firstSession
        afterRelaunch.records.append(StallRecord(session: "second", sequence: 1,
                                                 at: Date(timeIntervalSince1970: 1_785_009_999),
                                                 seconds: 3.0, surface: .queue, load: .baseline,
                                                 loadAverage: 1, passes: nil))
        let said = FreezeReport.newlyReported(in: URL(fileURLWithPath: "/tmp"), watchdogRan: true,
                                              defaults: d, read: liveOnly(afterRelaunch))

        #expect(said != nil,
                Comment(rawValue: "a freeze from a later session was not reported, because its sequence "
                        + "number is lower than the previous session's. Every freeze after the first "
                        + "session goes unsaid, and silence is what a clean session looks like."))
        #expect(said?.contains("3.0 seconds") == true)
    }

    // THE FIRST LAUNCH AFTER THE FIX, on an install that carries the broken version's key.
    //
    // Its file holds a backlog nothing could ever report, and it is SAID, once. This asserts a DECISION
    // rather than a mechanism, which is why it sets a key nothing reads any more: it goes red the moment
    // anybody reintroduces a branch treating the upgrade as a special case, and silence there is
    // indistinguishable from the defect that silenced this in the first place (L98).
    //
    // Dan's call, 2026-09-06, in this session, reversing the suppression the first version of this fix
    // shipped with. The test asserting THAT is deleted rather than adjusted, because its whole content
    // was the rejected behaviour (L252).
    @Test("the backlog the broken version could never report is said once, then not again")
    func theBacklogFromTheBrokenVersionIsSaidOnce() {
        let d = defaults("upgrade")
        d.set(3412, forKey: "freezesReportedThroughSequence")
        let read = FreezeLog.Read(records: [stall(9.0, sequence: 1), stall(4.0, sequence: 2)])

        let said = FreezeReport.newlyReported(in: URL(fileURLWithPath: "/tmp"), watchdogRan: true,
                                              defaults: d, read: liveOnly(read))
        #expect(said?.contains("2 times") == true,
                Comment(rawValue: "the backlog from the broken version was not reported, so the first "
                        + "build able to speak says nothing, which is what the defect looked like"))
        #expect(said?.contains("9.0 seconds") == true)

        // Once. The upgrade is a backlog like any other, never a notice that repeats.
        #expect(FreezeReport.newlyReported(in: URL(fileURLWithPath: "/tmp"), watchdogRan: true,
                                           defaults: d, read: liveOnly(read)) == nil)
    }

    // The OTHER wrong answer, and the reason the identity is not simply the timestamp: two stalls can
    // share an instant, so a reader remembering "said everything up to time T" drops the second one for
    // good. It has to be the SECOND call, because a filter over a set can never collapse two records
    // inside one call however they are keyed: the first version of this test reported both on a single
    // call and could not fail (L1).
    @Test("a freeze at the same instant as one already reported is still reported")
    func aFreezeSharingAnInstantWithAReportedOneIsStillReported() {
        let d = defaults("sameinstant")
        let at = Date(timeIntervalSince1970: 1_785_000_000)
        var read = FreezeLog.Read(records: [stall(1.0, sequence: 1, at: at)])
        _ = FreezeReport.newlyReported(in: URL(fileURLWithPath: "/tmp"), watchdogRan: true,
                                       defaults: d, read: liveOnly(read))

        read.records.append(stall(4.0, sequence: 2, at: at))
        let said = FreezeReport.newlyReported(in: URL(fileURLWithPath: "/tmp"), watchdogRan: true,
                                              defaults: d, read: liveOnly(read))
        #expect(said?.contains("4.0 seconds") == true,
                Comment(rawValue: "a stall sharing its instant with an already reported one was never "
                        + "said, so whatever identifies a record is the clock rather than the record"))
    }

    // #3439's reader, which is the SECOND one this phase requires: the floor, asked for rather than
    // waited for.
    @Test("the longest stall can be asked for")
    func theFloorCanBeAskedFor() {
        var read = FreezeLog.Read()
        read.records = [stall(0.4, sequence: 1), stall(58.0, sequence: 2), stall(1.1, sequence: 3)]
        let worst = FreezeReport.floor(in: URL(fileURLWithPath: "/tmp"), read: liveOnly(read))
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
