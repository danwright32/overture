import Testing
import Foundation

// #4453: the freeze notice decoded the WHOLE archive every time the window appeared, on the main thread.
//
// Measured 2026-10-02 on the live Release app: of 4,270 main thread samples, 2,955 (69%) were in
// `reportAnyFreezes`, 2,739 of them in the archive read. The archive was 9,245,974 bytes and 29,527
// records, and the preferences file holding every identity it had considered was 1,749,034 bytes. Dan
// saw the window stop responding.
//
// WHAT IS MEASURED HERE IS WORK, NOT TIME. The quantity that grew is how many lines were decoded, so the
// decoder is injected and COUNTED. A duration asserted against a fixed number would measure whatever else
// the Mac is running (L224, L290), and it is exactly this Mac's load that made the defect visible.
//
// Every fixture is GENERATED. None of it is Dan's data (L2).
@Suite("The freeze notice reads only what is new, off the main actor (#4453)")
final class TheFreezeNoticeReadsOnlyWhatIsNewTests {

    private let sandboxes = TemporarySandboxes()

    private let base = Date(timeIntervalSince1970: 1_785_000_000)

    private func record(_ session: String, _ sequence: Int, seconds: Double = 1.0,
                        at: Date? = nil) -> StallRecord {
        StallRecord(session: session, sequence: sequence,
                    at: at ?? base.addingTimeInterval(Double(sequence)),
                    seconds: seconds, surface: .queue, load: .baseline, loadAverage: 1.0, passes: nil)
    }

    private func records(_ session: String, _ count: Int, from start: Int = 1) -> [StallRecord] {
        (start..<(start + count)).map { record(session, $0) }
    }

    private func text(_ records: [StallRecord]) -> String {
        records.compactMap(FreezeLog.line(for:)).map { $0 + "\n" }.joined()
    }

    private func write(_ records: [StallRecord], to url: URL) throws {
        try text(records).write(to: url, atomically: true, encoding: .utf8)
    }

    private func append(_ records: [StallRecord], to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text(records).utf8))
    }

    private func liveURL(_ support: URL) -> URL { FreezeLog.url(in: support) }
    private func archiveURL(_ support: URL) -> URL { FreezeLog.archiveURL(besideLogAt: liveURL(support)) }

    // The real file readers, with the ARCHIVE's decoder counted. The live file is bounded by its own cap,
    // so it is not what grew; the archive is.
    private final class Counter { var decoded = 0 }

    private func countedFiles(_ counter: Counter) -> FreezeReport.Sources {
        let decoder = FreezeLog.decoder()
        return FreezeReport.Sources(live: FreezeLog.read(at:), archive: { url, anchors in
            FreezeLog.readArchiveTail(at: url, after: anchors, decode: { data in
                counter.decoded += 1
                return FreezeLog.decodeLine(data, with: decoder)
            })
        })
    }

    private func report(_ support: URL, _ defaults: UserDefaults,
                        _ sources: FreezeReport.Sources = .files) -> String? {
        FreezeReport.newlyReported(in: support, watchdogRan: true, defaults: defaults, sources: sources)
    }

    private func stored(_ defaults: UserDefaults) throws -> FreezeReport.Said {
        let data = try #require(defaults.data(forKey: FreezeReport.saidKey))
        return try FreezeLog.decoder().decode(FreezeReport.Said.self, from: data)
    }

    // MARK: - the defect

    // THE ONE THAT MATTERS. Two archives ten times apart in size, each given the same few new records
    // after a report has already been made, must cost the SAME number of decoded lines.
    @Test("what a report decodes does not grow with the archive")
    func theWorkDoesNotGrowWithTheArchive() throws {
        var decodedAfterTheFirstReport: [Int: Int] = [:]
        for size in [1_000, 10_000] {
            let support = try sandboxes.make(named: "freeze-tail-\(size)")
            let defaults = ScratchDefaults.make("freeze-tail-\(size)")
            try write(records("old", size), to: archiveURL(support))
            try write(records("live", 20), to: liveURL(support))

            // The first report reads everything, which is the backlog rule, and is how this counter is
            // shown to count at all: a counter that read zero here would make the next zero meaningless.
            let first = Counter()
            _ = try #require(report(support, defaults, countedFiles(first)))
            #expect(first.decoded == size, Comment(rawValue: "the first report did not read the whole archive, so the counter below measures nothing (size \(size), decoded \(first.decoded))"))

            // Three records compacted out before any report saw them, and five new ones in the live file.
            try append(records("moved", 3), to: archiveURL(support))
            try append(records("new", 5), to: liveURL(support))
            let second = Counter()
            let said = try #require(report(support, defaults, countedFiles(second)))
            #expect(said.contains("8 times"), Comment(rawValue: "the eight new freezes were not what was reported (size \(size)). Said: \(said)"))
            decodedAfterTheFirstReport[size] = second.decoded
        }

        let small = try #require(decodedAfterTheFirstReport[1_000])
        let large = try #require(decodedAfterTheFirstReport[10_000])
        #expect(small == large, Comment(rawValue: "an archive ten times larger cost \(large) decoded lines against \(small), so the notice's work still grows with the archive (#4453)"))
        #expect(large <= 3 + FreezeLog.archiveAnchorDepth, Comment(rawValue: "the report decoded \(large) archive lines to find 3 new ones"))
    }

    // And it stops rewriting every identity it has ever considered.
    @Test("what is remembered is bounded by the live file, not the archive")
    func whatIsRememberedIsBoundedByTheLiveFile() throws {
        let support = try sandboxes.make(named: "freeze-remembered")
        let defaults = ScratchDefaults.make("freeze-remembered")
        try write(records("old", 1_000), to: archiveURL(support))
        try write(records("live", 50), to: liveURL(support))

        _ = report(support, defaults)

        let said = try stored(defaults)
        #expect(said.liveIdentities.count == 50, Comment(rawValue: "the stored list holds \(said.liveIdentities.count) identities for a live file of 50, so it still grows with the archive"))
        #expect(said.archiveAnchors.count == FreezeLog.archiveAnchorDepth)
        #expect(defaults.object(forKey: FreezeLog.reportedIdsKey) == nil,
                "the old every-identity list is still being written")
    }

    // MARK: - #3812 and #3851, kept

    // A heavy session writes past the cap and its oldest records are compacted into the archive before
    // any report has read them. Each is said once, and nothing said before is said again.
    @Test("a compaction before any report loses nothing and repeats nothing")
    func aCompactionBeforeAnyReportLosesNothing() throws {
        let support = try sandboxes.make(named: "freeze-compacted")
        let defaults = ScratchDefaults.make("freeze-compacted")
        try write(records("earlier", 10), to: liveURL(support))
        _ = try #require(report(support, defaults))

        try append(records("heavy", 600), to: liveURL(support))
        let outcome = FreezeLog.compact(at: liveURL(support), cap: 500, now: base)
        #expect(outcome == .archived(count: 110), "the fixture did not compact the way this test depends on")

        let said = try #require(report(support, defaults))
        #expect(said.contains("600 times"), Comment(rawValue: "the heavy session's freezes were not each said once: \(said)"))
        #expect(report(support, defaults) == nil, "the compacted freezes were said a second time")
    }

    // A record in BOTH files is one freeze. A compaction whose live rewrite failed leaves exactly that.
    @Test("a record held by both files is one freeze")
    func aRecordInBothFilesIsOneFreeze() throws {
        let support = try sandboxes.make(named: "freeze-both")
        let defaults = ScratchDefaults.make("freeze-both")
        let one = record("s", 1, seconds: 2.5)
        try write([one], to: archiveURL(support))
        try write([one], to: liveURL(support))

        let said = try #require(report(support, defaults))
        #expect(said.contains("stopped responding for 2.5 seconds"), Comment(rawValue: "one freeze held by two files was counted twice: \(said)"))
    }

    // MARK: - the month's retention

    // The ordinary prune: the oldest records go from the FRONT. Nothing new is created by it.
    @Test("a prune of the archive's oldest records says nothing")
    func aPruneOfTheFrontSaysNothing() throws {
        let support = try sandboxes.make(named: "freeze-prune-front")
        let defaults = ScratchDefaults.make("freeze-prune-front")
        let now = base.addingTimeInterval(60 * 60 * 24 * 40)
        let old = (1...5).map { record("old", $0, at: base.addingTimeInterval(Double($0))) }
        let recent = (1...20).map { record("recent", $0, at: now.addingTimeInterval(-Double($0))) }
        try write(old + recent, to: archiveURL(support))
        _ = try #require(report(support, defaults))

        let pruned = FreezeLog.pruneArchive(besideLogAt: liveURL(support), now: now)
        guard case .removed(let count, _, _) = pruned, count == 5 else {
            Issue.record("the fixture did not prune the way this test depends on: \(pruned)"); return
        }
        #expect(report(support, defaults) == nil, "a prune made the archive's survivors read as new")
    }

    // THE CASE ONE ANCHOR GETS WRONG. A compaction that drops only the stall it had promoted leaves that
    // OLD record as the archive's last line, and the month's prune can then remove it while keeping the
    // newer records appended before it. Remembering only the last record, the reader finds nothing it
    // knows and announces the whole archive again (L36).
    @Test("a prune that removes the archive's last record says nothing")
    func aPruneOfTheLastRecordSaysNothing() throws {
        let support = try sandboxes.make(named: "freeze-prune-last")
        let defaults = ScratchDefaults.make("freeze-prune-last")
        let now = base.addingTimeInterval(60 * 60 * 24 * 40)
        let recent = (1...20).map { record("recent", $0, at: now.addingTimeInterval(-Double(100 - $0))) }
        let displacedPromotion = record("promoted", 1, seconds: 58.0, at: base)
        try write(recent + [displacedPromotion], to: archiveURL(support))
        _ = try #require(report(support, defaults))

        let pruned = FreezeLog.pruneArchive(besideLogAt: liveURL(support), now: now)
        guard case .removed(let count, _, _) = pruned, count == 1 else {
            Issue.record("the fixture did not prune the way this test depends on: \(pruned)"); return
        }
        let said = report(support, defaults)
        #expect(said == nil, Comment(rawValue: "removing the archive's last record made every record before it read as new: \(said ?? "nil")"))
    }

    // MARK: - the migration from the every-identity list

    // The first launch on this build carries the old list. Nothing it lists is said again, anything it
    // never reached is said (L98), the old key is removed, and from then on only what is new is read.
    @Test("the first report on this build repeats nothing the old list holds")
    func theMigrationRepeatsNothing() throws {
        let support = try sandboxes.make(named: "freeze-migrate")
        let defaults = ScratchDefaults.make("freeze-migrate")
        let archived = records("old", 1_000)
        let live = records("live", 50)
        try write(archived, to: archiveURL(support))
        try write(live, to: liveURL(support))
        // The old build said everything but one record in each file.
        let saidBefore = (archived.dropLast() + live.dropLast()).map(\.identity)
        defaults.set(saidBefore, forKey: FreezeLog.reportedIdsKey)

        let first = try #require(report(support, defaults))
        #expect(first.contains("2 times"), Comment(rawValue: "the migration did not say exactly the two records the old build never said: \(first)"))
        #expect(defaults.object(forKey: FreezeLog.reportedIdsKey) == nil, "the old list was left behind")
        #expect(try stored(defaults).liveIdentities.count == 50)

        #expect(report(support, defaults) == nil, "the migrated backlog was said a second time")

        try append([record("next", 1, seconds: 4.0)], to: liveURL(support))
        let counter = Counter()
        let next = try #require(report(support, defaults, countedFiles(counter)))
        #expect(next.contains("stopped responding for 4.0 seconds"))
        #expect(counter.decoded <= FreezeLog.archiveAnchorDepth, Comment(rawValue: "after the migration a report still decoded \(counter.decoded) archive lines"))
    }

    // MARK: - an archive that cannot be opened

    // The live file's freezes are still said, the gap is named, and nothing the archive holds is lost or
    // repeated once it can be read again.
    @Test("an archive that cannot be opened still lets the live freezes be said")
    func anUnopenableArchiveStillReports() throws {
        let support = try sandboxes.make(named: "freeze-unopenable")
        let defaults = ScratchDefaults.make("freeze-unopenable")
        // A DIRECTORY where the archive belongs: present, and unreadable as a file.
        try FileManager.default.createDirectory(at: archiveURL(support), withIntermediateDirectories: false)
        let earlier = record("live", 1, seconds: 3.0)
        try write([earlier], to: liveURL(support))

        let said = try #require(report(support, defaults))
        #expect(said.contains("stopped responding for 3.0 seconds"), Comment(rawValue: "the live freeze was not said: \(said)"))
        #expect(said.contains(FreezeNoticeCopy.partUnopened), Comment(rawValue: "the unopenable archive was not named: \(said)"))
        #expect(report(support, defaults) == nil, "the same notice was repeated while nothing changed")

        // The live file loses the record it said while the archive is still unopenable, which is what a
        // compaction moving it out looks like from here. What was said must outlast that.
        try write([], to: liveURL(support))
        #expect(report(support, defaults) == nil)

        // Healed, holding one record said while it was live and one never seen anywhere.
        try FileManager.default.removeItem(at: archiveURL(support))
        let unseen = record("lost", 1, seconds: 7.0)
        try write([earlier, unseen], to: archiveURL(support))
        let healed = try #require(report(support, defaults))
        #expect(healed.contains("stopped responding for 7.0 seconds"), Comment(rawValue: "once the archive opened, the record never said was not said alone: \(healed)"))
    }

    // And what it carries meanwhile stays bounded, or an archive that never opens again regrows the list
    // this change removed.
    @Test("what is carried while the archive cannot be opened is bounded")
    func whatIsCarriedIsBounded() throws {
        let support = try sandboxes.make(named: "freeze-carried")
        let defaults = ScratchDefaults.make("freeze-carried")
        try FileManager.default.createDirectory(at: archiveURL(support), withIntermediateDirectories: false)
        let earlier = FreezeReport.Said(liveIdentities: records("earlier", FreezeReport.carriedIdentityCeiling + 300).map(\.identity))
        defaults.set(try FreezeLog.encoder().encode(earlier), forKey: FreezeReport.saidKey)
        try write(records("live", 10), to: liveURL(support))

        _ = try #require(report(support, defaults))

        let carried = try stored(defaults).liveIdentities
        #expect(carried.count == FreezeReport.carriedIdentityCeiling, Comment(rawValue: "an unopenable archive carried \(carried.count) identities"))
        #expect(Array(carried.suffix(10)) == records("live", 10).map(\.identity), "the newest identities were not the ones kept")
    }

    @Test("an archive that cannot be opened is said on its own once, when nothing else is new")
    func anUnopenableArchiveIsSaidOnce() throws {
        let support = try sandboxes.make(named: "freeze-unopenable-alone")
        let defaults = ScratchDefaults.make("freeze-unopenable-alone")
        try FileManager.default.createDirectory(at: archiveURL(support), withIntermediateDirectories: false)

        #expect(report(support, defaults) == FreezeNoticeCopy.recordsUnopened,
                "an archive nobody could open read as a session with nothing to say (L98)")
        #expect(report(support, defaults) == nil, "the sentence repeats on every tick (L36)")
    }

    // MARK: - off the main actor

    // The main thread is the subject, so the wiring is guarded: the window's reporter awaits the actor and
    // never calls the domain reader itself.
    @Test("the window's freeze reporter reads off the main actor")
    func theReporterReadsOffTheMainActor() {
        let rootView = SourceGuardHelper.source("Overture/App/RootView.swift")
        guard let body = SourceGuardHelper.bodyOfFunction(named: "reportAnyFreezes", in: rootView) else {
            Issue.record("reportAnyFreezes body not found in RootView"); return
        }
        #expect(SourceGuardHelper.containsCode("await FreezeLogHousekeeper.shared.freezeReport(", in: body),
                "the freeze notice is no longer read through the housekeeping actor")
        #expect(!SourceGuardHelper.containsCode("FreezeReport.newlyReported(", in: rootView),
                "RootView calls the freeze reader directly, which runs it on the main actor (#4453)")

        let housekeeper = SourceGuardHelper.source("Overture/Integration/FreezeLogHousekeeper.swift")
        #expect(SourceGuardHelper.containsCode("FreezeReport.newlyReported(", in: housekeeper))
    }
}
