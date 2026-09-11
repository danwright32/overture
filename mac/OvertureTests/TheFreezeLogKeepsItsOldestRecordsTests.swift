import Testing
import Foundation

// #3763: a compaction must not be the only copy of the population this milestone is judged on.
//
// `FreezeLog.compact` runs at launch and keeps the newest `fileCap` records. Measured 2026-09-10, installing
// #3760 found 686 records reaching back to 2026-09-07 and a compaction would have discarded 186 of them,
// which were the "before" half of milestone 80's own reading. They survive today only because somebody
// copied them aside by hand. Nothing in the product did that and nothing said anything had gone.
//
// So the live file stays a rolling window, cheap to read at launch, and what it drops is appended beside it.
@Suite("A compaction keeps what it discards (#3763)")
final class TheFreezeLogKeepsItsOldestRecordsTests {

    private let sandboxes = TemporarySandboxes()

    private func stall(_ seconds: Double, sequence: Int,
                       at: Date = Date(timeIntervalSince1970: 1_785_000_000)) -> StallRecord {
        StallRecord(session: "s", sequence: sequence, at: at, seconds: seconds,
                    surface: .queue, load: .baseline, loadAverage: 1.0, passes: nil)
    }

    // Written through `append`, the way the watchdog writes them, so this exercises the real file shape
    // rather than a string this test composed and therefore agrees with (L48).
    private func writeLog(_ records: [StallRecord], to url: URL) {
        for record in records { _ = FreezeLog.append(record, to: url) }
    }

    // THE ONE THAT MATTERS. Every record a compaction drops is in the archive afterwards, so the
    // distribution survives a relaunch, which is the only thing a build install is guaranteed to do.
    @Test("the records a compaction drops are in the archive afterwards")
    func droppedRecordsAreArchivedRatherThanDiscarded() throws {
        let dir = try sandboxes.make(named: "freeze-archive")
        let log = FreezeLog.url(in: dir)
        // Ascending lengths, so the worst stall is the NEWEST one and the keep-the-longest rule cannot
        // rescue any of the records this test expects to be dropped. Without that the rule would hold one
        // of them back and the archive could pass while still losing the rest.
        let written = (0..<10).map { stall(Double($0) * 0.1 + 0.2, sequence: $0 + 1) }
        writeLog(written, to: log)

        FreezeLog.compact(at: log, cap: 4)

        let live = FreezeLog.read(at: log)
        #expect(live.records.count == 4, "this did not exercise the cap, so it proves nothing either way")

        let archived = FreezeLog.read(at: FreezeLog.archiveURL(besideLogAt: log))
        #expect(!archived.fileWasAbsent,
                "no archive was written at all, so a compaction is still the last anyone sees of these records")
        let keptOrArchived = Set(live.records.map(\.identity)).union(archived.records.map(\.identity))
        #expect(keptOrArchived == Set(written.map(\.identity)),
                Comment(rawValue: "a compaction lost records: wrote \(written.count), "
                + "kept \(live.records.count), archived \(archived.records.count)"))
    }

    // The archive and the truncation are two writes with no transaction around them, so the ORDER is the
    // whole safeguard: archive first, and do not truncate at all if that failed. Without this the records
    // are gone and the only evidence of it is an archive nobody has a reason to open (L5).
    //
    // The archive is blocked by putting a DIRECTORY at its path, which is a real thing the filesystem can
    // hand back rather than an injected failure the production code knows about.
    @Test("a compaction whose archive cannot be written leaves the live log untouched")
    func aFailedArchiveDestroysNothing() throws {
        let dir = try sandboxes.make(named: "freeze-archive-blocked")
        let log = FreezeLog.url(in: dir)
        let written = (0..<10).map { stall(Double($0) * 0.1 + 0.2, sequence: $0 + 1) }
        writeLog(written, to: log)
        try FileManager.default.createDirectory(at: FreezeLog.archiveURL(besideLogAt: log),
                                                withIntermediateDirectories: false)

        FreezeLog.compact(at: log, cap: 4)

        let live = FreezeLog.read(at: log)
        #expect(Set(live.records.map(\.identity)) == Set(written.map(\.identity)),
                Comment(rawValue: "the live log was truncated to \(live.records.count) records even though "
                + "the archive could not be written, so those records are gone and nothing holds them"))
    }

    // A file half written by a process killed mid-freeze is the ORDINARY case for this log, which is why
    // `read` counts unreadable lines rather than dropping them. The same file can hold one record twice,
    // and an identity that appears in the kept window then answers for its own older copy, so that copy is
    // neither kept nor archived. Counted rather than compared by identity, because identity is the very
    // thing that collides here.
    @Test("a log holding the same record twice still archives every line it drops")
    func aDuplicatedRecordIsNotLostByIdentity() throws {
        let dir = try sandboxes.make(named: "freeze-archive-duplicate")
        let log = FreezeLog.url(in: dir)
        // The FIRST line repeats the identity of one that will survive in the kept window, which is the
        // shape a duplicated append leaves behind.
        var written = (0..<9).map { stall(Double($0) * 0.1 + 0.2, sequence: $0 + 1) }
        written.insert(stall(0.15, sequence: 9), at: 0)
        writeLog(written, to: log)

        FreezeLog.compact(at: log, cap: 4)

        let live = FreezeLog.read(at: log)
        let archived = FreezeLog.read(at: FreezeLog.archiveURL(besideLogAt: log))
        #expect(live.records.count + archived.records.count == written.count,
                Comment(rawValue: "wrote \(written.count) lines, kept \(live.records.count) and archived "
                + "\(archived.records.count), so \(written.count - live.records.count - archived.records.count) "
                + "went nowhere"))
    }

    // MARK: - the archive's own retention (#3763, Dan's call 2026-09-11)

    // Dan's words, this session: "I don't think we need it that long do we? Probably could keep it for a
    // month and then drop it." So the archive is not forever. That makes the prune the second destructive
    // operation in this file, and it gets the same treatment as the first: it SAYS what it removed, because
    // a retention policy that deletes silently is indistinguishable from a quiet month (L9, L98).
    //
    // Every date here is derived from `archiveRetentionDays` rather than written as a literal beside it, so
    // the day that constant changes these fixtures still mean what their names say (L401).
    @Test("archived records older than the retention window are dropped and newer ones kept")
    func theArchiveKeepsOnlyTheRetentionWindow() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day: TimeInterval = 60 * 60 * 24
        let window = Double(FreezeLog.archiveRetentionDays) * day
        let inside = [stall(0.3, sequence: 1, at: now.addingTimeInterval(-day)),
                      stall(0.4, sequence: 2, at: now.addingTimeInterval(-window + day))]
        let outside = [stall(0.5, sequence: 3, at: now.addingTimeInterval(-window - day)),
                       stall(0.6, sequence: 4, at: now.addingTimeInterval(-window - 90 * day))]

        let result = FreezeLog.pruned(outside + inside, now: now)

        #expect(result.records.map(\.identity) == inside.map(\.identity),
                "the retention window kept the wrong records")
        #expect(result.dropped == outside.count,
                Comment(rawValue: "expected \(outside.count) records outside the window to be dropped, "
                + "got \(result.dropped)"))
    }

    // The report half. A prune that removed 200 records and one that removed none must not print the same
    // thing, and the DATE RANGE is what makes the difference readable: "it dropped 200 records from
    // 2026-09-07 to 2026-09-10" is a fact somebody can act on, where a bare count is not (L11).
    @Test("a prune says how many it dropped and over what date range")
    func thePruneSaysWhatItRemoved() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day: TimeInterval = 60 * 60 * 24
        let window = Double(FreezeLog.archiveRetentionDays) * day
        let oldest = now.addingTimeInterval(-window - 90 * day)
        let newestDropped = now.addingTimeInterval(-window - day)
        let records = [stall(0.6, sequence: 1, at: oldest),
                       stall(0.5, sequence: 2, at: newestDropped),
                       stall(0.3, sequence: 3, at: now.addingTimeInterval(-day))]

        let result = FreezeLog.pruned(records, now: now)

        #expect(result.dropped == 2)
        #expect(result.earliestDropped == oldest, "the prune cannot say how far back it reached")
        #expect(result.latestDropped == newestDropped, "the prune cannot say how recent its newest loss was")
    }

    // Nothing dropped is its own outcome, and it must be distinguishable from a prune that never ran. The
    // two read identically if the only signal is a count of zero (L98).
    @Test("a prune with nothing old enough to drop names no date range at all")
    func aPruneThatRemovedNothingSaysSo() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let records = [stall(0.3, sequence: 1, at: now.addingTimeInterval(-60 * 60 * 24))]

        let result = FreezeLog.pruned(records, now: now)

        #expect(result.dropped == 0)
        #expect(result.earliestDropped == nil)
        #expect(result.latestDropped == nil)
    }

    // The file half. `pruned` decides; this writes, and writing is where the record is actually destroyed.
    @Test("pruning the archive file leaves only the retention window")
    func thePruneRewritesTheArchiveFile() throws {
        let dir = try sandboxes.make(named: "freeze-prune")
        let log = FreezeLog.url(in: dir)
        let archive = FreezeLog.archiveURL(besideLogAt: log)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day: TimeInterval = 60 * 60 * 24
        let window = Double(FreezeLog.archiveRetentionDays) * day
        writeLog([stall(0.5, sequence: 1, at: now.addingTimeInterval(-window - day)),
                  stall(0.3, sequence: 2, at: now.addingTimeInterval(-day))], to: archive)

        let result = FreezeLog.pruneArchive(besideLogAt: log, now: now)

        #expect(result.dropped == 1, "the prune did not remove the record outside the window")
        let left = FreezeLog.read(at: archive)
        #expect(left.records.map(\.identity) == ["s#2"], "the archive file was not rewritten to the window")
    }

    // THE ONE THAT MATTERS HERE. A prune rewrites the archive from what its READ returned, so any line the
    // read could not decode is destroyed by the rewrite without ever being counted. A log half written by a
    // process killed mid-freeze is the ordinary case for this file, so that is not a rare path. A cleanup
    // that deletes whatever its read failed to mention must refuse on a SHORT read, not only on a failed
    // one (L211, L105).
    @Test("a prune refuses to rewrite an archive holding lines it could not read")
    func aPruneRefusesOnAnUnreadableArchive() throws {
        let dir = try sandboxes.make(named: "freeze-prune-damaged")
        let log = FreezeLog.url(in: dir)
        let archive = FreezeLog.archiveURL(besideLogAt: log)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day: TimeInterval = 60 * 60 * 24
        let window = Double(FreezeLog.archiveRetentionDays) * day
        // Built as ONE write, with the truncated line in the MIDDLE, which is where a process killed
        // mid-append leaves it. Written in one go deliberately: composing it by appending after a
        // `String.write` would OVERWRITE the record before it, and the fixture would then be a damaged line
        // plus one good one rather than the sandwich this case is about.
        let good = [stall(0.5, sequence: 1, at: now.addingTimeInterval(-window - day)),
                    stall(0.3, sequence: 2, at: now.addingTimeInterval(-day))]
        let damaged = "{\"session\":\"s\",\"sequence\":99,\"at\":\"2026-09-10T17:4"
        let lines = [FreezeLog.line(for: good[0]), damaged, FreezeLog.line(for: good[1])].compactMap { $0 }
        #expect(lines.count == 3, "the fixture could not encode its own records, so it tests nothing")
        try (lines.joined(separator: "\n") + "\n").write(to: archive, atomically: true, encoding: .utf8)
        let before = try String(contentsOf: archive, encoding: .utf8)
        #expect(FreezeLog.read(at: archive).unreadableLines == 1,
                "the fixture's damaged line decoded after all, so this case was never reached")

        let result = FreezeLog.pruneArchive(besideLogAt: log, now: now)

        #expect(result.dropped == 0, "the prune removed records from an archive it could not fully read")
        #expect(result.refusedUnreadableLines == 1,
                "the prune did not report the unreadable line as its reason for refusing")
        let after = try String(contentsOf: archive, encoding: .utf8)
        #expect(after == before,
                "the archive was rewritten despite holding a line the read could not decode, so that line is gone")
    }

    // MARK: - the rehearsal against the real log

    // L7: rehearse a destructive operation against a COPY of the real thing, never only against data you
    // built. Every other test here feeds this code logs it composed itself, so they all agree with my idea
    // of what a freeze log looks like. Dan's real one does not: 675 records on 2026-09-11, spanning two
    // build generations, most of them carrying no `passes` field at all, six sessions, and already 175
    // over the cap, so the first real compaction moves a population whose shape this code has never seen.
    //
    // OPT IN, and UNMEASURED rather than passing when it cannot run, because a machine with no live log and
    // a compaction that loses nothing must not print the same thing (L98). Set
    // TEST_RUNNER_REHEARSE_FREEZE_COMPACTION=1 to run it.
    //
    // READ ONLY on the real file. It is copied into this suite's own sandbox first and the compaction runs
    // on the copy, so the rehearsal can never be the thing that destroys the records it is checking.
    @Test("compacting a copy of the real freeze log loses nothing")
    func rehearseAgainstTheRealLog() throws {
        // Read WITHOUT the prefix. xcodebuild passes a `TEST_RUNNER_<NAME>` variable into the test process
        // as `<NAME>`, which is why that prefix is load bearing rather than decoration, and why the message
        // below names the variable the CALLER sets rather than the one read here. Setting the prefixed name
        // and reading the prefixed name looks right and is never true, and the test then prints "not
        // measured" while the caller believes it ran (caught 2026-09-11 doing exactly that).
        guard ProcessInfo.processInfo.environment["REHEARSE_FREEZE_COMPACTION"] != nil else {
            print("freeze-compaction-rehearsal: not measured. Set TEST_RUNNER_REHEARSE_FREEZE_COMPACTION=1 to run it.")
            return
        }
        // The APP's own definition of where the log lives, never a path this test builds. Two reasons, and
        // the suite enforces the first: `TestsCannotReachSharedStateTests` forbids a test reaching a shared
        // location through `NSHomeDirectory()`, and it caught this written that way (L2). The second is that
        // a hand-built path is a second definition of where the log is, free to drift from where the app
        // actually writes it, which would make this rehearse a file nobody uses (L70, L263).
        let live = FreezeLog.url(in: StoreLocation.dataDirectory(appSupport: StoreLocation.appSupport,
                                                                isDebugBuild: false))
        guard FileManager.default.fileExists(atPath: live.path) else {
            let why = "freeze-compaction-rehearsal: UNMEASURED. No live log at \(live.path), so this "
                + "rehearsal verified nothing. That is not the same as a compaction that lost nothing."
            Issue.record(Comment(rawValue: why))
            return
        }

        let dir = try sandboxes.make(named: "freeze-rehearsal")
        let copy = FreezeLog.url(in: dir)
        try FileManager.default.copyItem(at: live, to: copy)
        let before = FreezeLog.read(at: copy)

        FreezeLog.compact(at: copy)

        let kept = FreezeLog.read(at: copy)
        let archived = FreezeLog.read(at: FreezeLog.archiveURL(besideLogAt: copy))
        print("freeze-compaction-rehearsal: \(before.records.count) real records in, "
              + "\(kept.records.count) kept, \(archived.records.count) archived, "
              + "\(before.unreadableLines) unreadable line(s) in the source.")
        #expect(kept.records.count + archived.records.count == before.records.count,
                Comment(rawValue: "the real log lost records: \(before.records.count) in, "
                + "\(kept.records.count) kept, \(archived.records.count) archived"))
        #expect(kept.records.count <= FreezeLog.fileCap, "the real log was left over its own cap")
    }

    // MARK: - the retention rule itself, pinned where #3763 changed how it is computed

    // #3763 moved the search for a promotable freeze from the WHOLE file to the part being dropped, on the
    // reasoning that a long freeze already inside the kept window is kept anyway and the strict test could
    // never admit it. That reasoning was not covered by any test: the three before this one pin keeping the
    // newest, rescuing an old long freeze, and leaving a small file alone. This is the case the change
    // actually touched, and it decides which freeze survives, which is the one reading this file exists for.
    @Test("the longest freeze already in the kept window promotes nothing and the oldest are dropped")
    func nothingIsPromotedWhenTheWorstIsAlreadyKept() {
        // Ascending, so the longest stall is the NEWEST record and sits inside the kept window.
        let records = (0..<10).map { stall(Double($0) * 0.1 + 0.2, sequence: $0 + 1) }

        let result = FreezeLog.compacted(records, cap: 4)

        #expect(result.records.map(\.identity) == records.suffix(4).map(\.identity),
                "a record was promoted even though the longest stall was already being kept")
        #expect(result.droppedRecords.map(\.identity) == records.prefix(6).map(\.identity),
                "the dropped records are not exactly the oldest six")
        #expect(result.dropped == 6)
    }

    // The other side of the same rule. Rescuing an old long freeze costs a slot, and the record it pushes
    // out has to be archived like any other dropped one. Nothing pinned that, and a displaced record is the
    // easiest of all of them to lose: it is the only one that leaves the kept window rather than never
    // having been in it.
    @Test("the record displaced by a rescued freeze is dropped rather than vanishing")
    func theDisplacedRecordIsAccountedFor() {
        // One very long stall FIRST, then short ones, so the rescue branch is the one taken.
        var records = [stall(58.0, sequence: 1)]
        records += (1..<10).map { stall(0.3, sequence: $0 + 1) }

        let result = FreezeLog.compacted(records, cap: 4)

        #expect(result.records.first?.identity == "s#1", "the 58 second stall was not rescued at all")
        #expect(result.records.count == 4, "the rescue grew the file past its cap")
        #expect(result.records.count + result.dropped == records.count,
                Comment(rawValue: "\(records.count) in, \(result.records.count) kept and \(result.dropped) "
                + "dropped, so the record the rescue displaced is in neither"))
        #expect(result.droppedRecords.map(\.identity).contains("s#7"),
                "the record displaced to make room for the rescue is not among the dropped ones")
    }
}
