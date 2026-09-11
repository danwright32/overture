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
