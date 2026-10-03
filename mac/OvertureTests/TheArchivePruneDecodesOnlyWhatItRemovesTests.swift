import Testing
import Foundation

// #4454: the archive's month prune decoded EVERY record in the archive, every hour.
//
// Measured 2026-10-02 on Dan's Mac: the archive was 9.2 MB and 29,527 records, and `FreezeLog.pruneArchive`
// decoded all of them on the hourly housekeeping tick to learn which were older than a month, then encoded
// every survivor again to write them back. Off the main actor since #3828, so it never froze the window, but
// it spent CPU in proportion to the archive on a Mac that is usually already loaded by builds.
//
// WHAT IS MEASURED HERE IS WORK, NOT TIME, on #4453's precedent beside it. The decoder is injected and
// COUNTED, because a duration asserted against a fixed number measures whatever else the Mac is running
// (L224, L290).
//
// AND WHAT MUST NOT CHANGE, which is most of this file. A month still means a month, including for the old
// record a compaction appends AFTER newer ones (#3763). Nothing younger than the window is ever removed. And a
// line nobody can read is kept, never dropped, on #4398's precedent for the live file.
//
// Every fixture is GENERATED. None of it is Dan's data (L2).
@Suite("The archive prune decodes only what it removes (#4454)")
final class TheArchivePruneDecodesOnlyWhatItRemovesTests {

    private let sandboxes = TemporarySandboxes()

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 60 * 60 * 24
    // Derived from the retention constant rather than written beside it, so the day it moves these fixtures
    // still mean what their names say (L401).
    private var window: TimeInterval { Double(FreezeLog.archiveRetentionDays) * day }

    private func stall(_ sequence: Int, at: Date) -> StallRecord {
        StallRecord(session: "s", sequence: sequence, at: at, seconds: 0.5,
                    surface: .queue, load: .baseline, loadAverage: 1.0, passes: nil)
    }

    private func line(_ record: StallRecord) throws -> String {
        try #require(FreezeLog.line(for: record), "the fixture could not encode its own record")
    }

    private func lines(_ records: [StallRecord]) throws -> [Data] {
        try records.map { Data(try line($0).utf8) }
    }

    private final class Counter { var decoded = 0 }

    private func counting(_ counter: Counter) -> (Data) -> FreezeLog.Line {
        let decoder = FreezeLog.decoder()
        return { data in
            counter.decoded += 1
            return FreezeLog.decodeLine(data, with: decoder)
        }
    }

    private func identities(_ kept: [Data]) -> [String] {
        let decoder = FreezeLog.decoder()
        return kept.compactMap {
            if case .record(let record) = FreezeLog.decodeLine($0, with: decoder) { return record.identity }
            return nil
        }
    }

    private func archive(_ dir: URL) -> URL {
        FreezeLog.archiveURL(besideLogAt: FreezeLog.url(in: dir))
    }

    // MARK: - the defect

    // THE ONE THAT MATTERS. A month of records inside the window and a handful just past it: the prune must
    // decode the handful, not the month. Before #4454 this decoded every line, 2,005 here.
    @Test("a prune decodes the records it removes, not the whole archive")
    func aPruneDecodesOnlyWhatItRemoves() throws {
        let old = (0..<5).map { stall($0, at: now.addingTimeInterval(-window - Double($0 + 1) * 60)) }
        let inside = (0..<2_000).map { stall(100 + $0, at: now.addingTimeInterval(-window + Double($0 + 1) * 60)) }
        let counter = Counter()

        let result = FreezeLog.pruned(lines: try lines(old + inside), now: now, decode: counting(counter))

        #expect(result.dropped == old.count, "this did not remove the old records, so it proves nothing")
        #expect(counter.decoded == old.count,
                Comment(rawValue: "the prune decoded \(counter.decoded) lines to remove \(old.count), so its "
                        + "cost still grows with the archive rather than with what it removes"))
    }

    // The ordinary hour: nothing has aged past the window since the last pass. Nothing is decoded and the
    // file is not rewritten, so a quiet hour costs one pass over the bytes and nothing else.
    @Test("an hour with nothing to remove decodes nothing and writes nothing")
    func aQuietHourDecodesAndWritesNothing() throws {
        let dir = try sandboxes.make(named: "freeze-prune-quiet")
        let inside = (0..<200).map { stall($0, at: now.addingTimeInterval(-Double($0 + 1) * 60)) }
        try (try inside.map(line).joined(separator: "\n") + "\n")
            .write(to: archive(dir), atomically: true, encoding: .utf8)
        let counter = Counter()
        var writes = 0

        let result = FreezeLog.pruneArchive(besideLogAt: FreezeLog.url(in: dir), now: now,
                                             decode: counting(counter),
                                             write: { _, _ in writes += 1 })

        #expect(result == .nothingToRemove)
        #expect(counter.decoded == 0, Comment(rawValue: "a quiet hour decoded \(counter.decoded) lines"))
        #expect(writes == 0, "a prune with nothing to remove rewrote the archive anyway")
    }

    // MARK: - a month still means a month (#3763)

    // The archive is NOT in time order: `compact` promotes an old stall into the live file and later
    // displaces it into the archive, AFTER records newer than it. Measured 2026-10-03 on a copy of Dan's
    // archive, three records sat behind newer ones, the oldest by a week. A prune that stopped at the first
    // record inside the window would keep that one past its month, for ever.
    @Test("an old record appended after newer ones is still removed")
    func anOldRecordBehindNewerOnesIsStillRemoved() throws {
        let inside = (0..<20).map { stall($0, at: now.addingTimeInterval(-window + Double($0 + 1) * day / 2)) }
        let displaced = stall(99, at: now.addingTimeInterval(-window - 7 * day))
        let after = stall(100, at: now.addingTimeInterval(-60))

        let result = FreezeLog.pruned(lines: try lines(inside + [displaced, after]), now: now,
                                      decode: counting(Counter()))

        #expect(result.droppedRecords.map(\.identity) == [displaced.identity],
                "a record past its month survived because newer records were ahead of it in the file")
        #expect(identities(result.keptLines) == (inside + [after]).map(\.identity),
                "the prune removed or reordered records inside the window")
    }

    // THE EDGE, to the second. The file stores whole seconds and the clock does not, so the cheap test on a
    // line's stamp and the rule on the decoded record must agree on both sides of a cutoff that falls part
    // way through a second. Asserted against the rule itself rather than a hand worked answer (L638).
    @Test("records either side of the cutoff are judged exactly as the rule judges them")
    func theCutoffIsExactToTheSecond() throws {
        let fractionalNow = now.addingTimeInterval(0.4)
        let cutoff = FreezeLog.archiveCutoff(now: fractionalNow, retentionDays: FreezeLog.archiveRetentionDays)
        let around = (-3...3).map { stall(10 + $0, at: Date(timeIntervalSince1970:
            cutoff.timeIntervalSince1970.rounded(.down) + Double($0))) }

        let result = FreezeLog.pruned(lines: try lines(around), now: fractionalNow, decode: counting(Counter()))

        let expectedDropped = around.filter { $0.at < cutoff }.map(\.identity)
        #expect(!expectedDropped.isEmpty && expectedDropped.count < around.count,
                "the fixture does not straddle the cutoff, so it proves nothing")
        #expect(result.droppedRecords.map(\.identity) == expectedDropped,
                Comment(rawValue: "the cutoff \(cutoff) was applied differently: dropped "
                        + "\(result.droppedRecords.map(\.identity)), the rule drops \(expectedDropped)"))
    }

    // The cheap stamp read trusts a line only when `"at":"` appears in it ONCE. A later build that nests
    // something carrying its own `at` must not have that inner, younger stamp read as the record's, or a
    // record past its month is kept for ever without anybody deciding to keep it.
    @Test("a record carrying a second, younger at inside it is judged by its own")
    func aNestedAtIsNotReadAsTheRecords() throws {
        let old = stall(1, at: now.addingTimeInterval(-window - day))
        let youngStamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-60))
        let nested = String(try line(old).dropLast()) + ",\"zLaterBuild\":{\"at\":\"\(youngStamp)\"}}"

        let result = FreezeLog.pruned(lines: [Data(nested.utf8)], now: now, decode: counting(Counter()))

        #expect(result.droppedRecords.map(\.identity) == [old.identity],
                Comment(rawValue: "the nested stamp \(youngStamp) was read as the record's own, so a record "
                        + "past its month was kept: \(nested)"))
    }

    // MARK: - what is never removed

    // A line nobody can read is KEPT, verbatim, and the prune still removes what it can show is old. Until
    // #4454 the prune refused outright on such a line, which kept it but also stopped the archive ever being
    // bounded again; #4398 made the same call for the live file. A torn line that STARTS like an old record is
    // the case that matters: its stamp says old, and it is still not a record anybody can show is old.
    @Test("a line nobody can read is kept, beside a prune that still removes the old records")
    func anUnreadableLineIsKeptAndThePruneStillRuns() throws {
        let dir = try sandboxes.make(named: "freeze-prune-unreadable")
        let old = stall(1, at: now.addingTimeInterval(-window - day))
        let young = stall(2, at: now.addingTimeInterval(-day))
        let oldStamp = String(try line(old).prefix(while: { $0 != "Z" })) + "Z\",\"lo"
        let garbage = "not json at all"
        let fileLines = [try line(old), oldStamp, garbage, try line(young)]
        try (fileLines.joined(separator: "\n") + "\n").write(to: archive(dir), atomically: true, encoding: .utf8)

        let result = FreezeLog.pruneArchive(besideLogAt: FreezeLog.url(in: dir), now: now)

        #expect(result == .removed(count: 1, earliest: old.at, latest: old.at),
                Comment(rawValue: "the prune did not remove the old record beside the unreadable lines: \(result)"))
        let after = try String(contentsOf: archive(dir), encoding: .utf8)
        #expect(after == [oldStamp, garbage, try line(young)].joined(separator: "\n") + "\n",
                Comment(rawValue: "the unreadable lines did not survive the prune verbatim:\n\(after)"))
    }

    // Kept lines are written back as the FILE held them, never re-encoded. Re-encoding through this build's
    // `StallRecord` drops any field a later build added, which is a loss nobody would see (L425).
    @Test("a kept record is written back byte for byte, a field this build does not know included")
    func keptLinesAreWrittenBackVerbatim() throws {
        let dir = try sandboxes.make(named: "freeze-prune-verbatim")
        let old = stall(1, at: now.addingTimeInterval(-window - day))
        let young = try line(stall(2, at: now.addingTimeInterval(-day)))
        let fromALaterBuild = String(young.dropLast()) + ",\"zFieldFromALaterBuild\":7}"
        try ([try line(old), fromALaterBuild].joined(separator: "\n") + "\n")
            .write(to: archive(dir), atomically: true, encoding: .utf8)

        _ = FreezeLog.pruneArchive(besideLogAt: FreezeLog.url(in: dir), now: now)

        let after = try String(contentsOf: archive(dir), encoding: .utf8)
        #expect(after == fromALaterBuild + "\n",
                Comment(rawValue: "the kept record was not written back as the file held it:\n\(after)"))
    }

    // MARK: - a failed write destroys nothing

    // The rewrite is the only destructive step, so it is atomic and its failure is SAID. Blocked for real
    // rather than by an injected failure: the archive's folder is made read only, so the temporary file an
    // atomic write needs cannot be created beside it.
    @Test("a rewrite that cannot be written leaves the archive as it was, and says so")
    func aFailedRewriteLeavesTheArchiveIntact() throws {
        let dir = try sandboxes.make(named: "freeze-prune-readonly")
        let lines = [try line(stall(1, at: now.addingTimeInterval(-window - day))),
                     try line(stall(2, at: now.addingTimeInterval(-day)))]
        try (lines.joined(separator: "\n") + "\n").write(to: archive(dir), atomically: true, encoding: .utf8)
        let before = try Data(contentsOf: archive(dir))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }

        let result = FreezeLog.pruneArchive(besideLogAt: FreezeLog.url(in: dir), now: now)

        #expect(result == .couldNotRewrite,
                Comment(rawValue: "a rewrite that failed was not reported as one: \(result)"))
        #expect(try Data(contentsOf: archive(dir)) == before, "a failed rewrite changed the archive")
    }

    // The same, through the injected writer, so the outcome is pinned even on a file system that would let
    // the read only folder through.
    @Test("a writer that throws leaves the archive as it was")
    func aThrowingWriterLeavesTheArchiveIntact() throws {
        struct Refused: Error {}
        let dir = try sandboxes.make(named: "freeze-prune-throwing")
        let lines = [try line(stall(1, at: now.addingTimeInterval(-window - day))),
                     try line(stall(2, at: now.addingTimeInterval(-day)))]
        try (lines.joined(separator: "\n") + "\n").write(to: archive(dir), atomically: true, encoding: .utf8)
        let before = try Data(contentsOf: archive(dir))

        let result = FreezeLog.pruneArchive(besideLogAt: FreezeLog.url(in: dir), now: now,
                                             write: { _, _ in throw Refused() })

        #expect(result == .couldNotRewrite)
        #expect(try Data(contentsOf: archive(dir)) == before, "a failed rewrite changed the archive")
    }

    @Test("a rewrite that could not be written is said, and says nothing was deleted")
    func aFailedRewriteIsSaid() {
        let notice = FreezeHousekeepingCopy.notice(FreezeLog.Housekeeping(prune: .couldNotRewrite))
        #expect(notice == FreezeHousekeepingCopy.pruneCouldNotRewrite,
                Comment(rawValue: "a prune that removed nothing because its write failed said: \(String(describing: notice))"))
    }
}
