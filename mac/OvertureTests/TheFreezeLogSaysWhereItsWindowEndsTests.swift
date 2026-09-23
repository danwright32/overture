import Testing
import Foundation

// #4122: the live freeze log is a truncated window with ONE record from an arbitrary earlier date in it,
// and the file said so nowhere.
//
// WHAT WAS MEASURED, 2026-09-21, while reading the log during a day of watching. At about 15:30 local the
// live `freeze-log.ndjson` held 1,026 records for the day; at 17:05 the same file held 583. Nothing in the
// file recorded that a compaction had happened in between. `FreezeLog.compacted` keeps the newest
// `fileCap` (500) records, moves the rest to the archive, and PROMOTES the single longest older stall back
// into the live file. Both halves are deliberate and well reasoned; neither was visible to a reader.
//
// So Dan's file that day opened with a 1,047 second stall from 2026-09-18 followed by records from
// 2026-09-21T20:07Z onwards, and any ad hoc count over it, "how many stalls today", "what was the worst",
// "what is the p90", silently answered over a truncated window with one out of band member in it. The
// issue records that its own author did exactly that and quoted the totals on #4114.
//
// #3660's bar is the sharpest case: it is defined as a count over this file, so a fix could be judged
// against a window whose oldest half was archived mid measurement.
//
// TWO MARKS, because they serve two different readers and neither covers the other:
//
//   THE RECORD carries `promotedFromOlderWindow`, so a reader going line by line (a `jq` over the file,
//   a script written later) can drop it without knowing the algorithm.
//   THE FILE carries a `FreezeLogNote`, so a reader of the whole file can see the boundary: how many
//   records this window holds, how many were archived, and which record was promoted into it.
//
// ONE NOTE PER FILE, not one per compaction, and that is deliberate. A compaction rewrites the live file
// from the records it kept, so the previous note is not carried over. A note describes the composition of
// the file it sits in, and an older note would describe a window that no longer exists, which is the
// stale-evidence shape this issue is about in the first place.
@Suite("The freeze log says where its window ends (#4122)")
final class TheFreezeLogSaysWhereItsWindowEndsTests {

    private let sandboxes = TemporarySandboxes()

    private func stall(_ seconds: Double, sequence: Int, at: Date) -> StallRecord {
        StallRecord(session: "s", sequence: sequence, at: at, seconds: seconds,
                    surface: .queue, load: .baseline, loadAverage: 1.0, passes: 1)
    }

    private func day(_ n: Int) -> Date { Date(timeIntervalSince1970: 1_785_000_000 + Double(n) * 86_400) }

    private func writeLog(_ records: [StallRecord], to url: URL) {
        for record in records { _ = FreezeLog.append(record, to: url) }
    }

    // A log whose OLDEST record is the longest, so the promotion rule actually fires. Ten records, cap
    // four: six are dropped and the longest of those six is promoted back.
    private func aLogWithAnOutlierInItsOldestHalf() -> [StallRecord] {
        var records = (0..<10).map { stall(0.2 + Double($0) * 0.1, sequence: $0 + 1, at: day($0)) }
        records[0] = stall(1_047.0, sequence: 1, at: day(0))
        return records
    }

    // MARK: - The record says it was promoted

    @Test("the promoted record is marked, and it is the only one that is")
    func onlyThePromotedRecordIsMarked() {
        let result = FreezeLog.compacted(aLogWithAnOutlierInItsOldestHalf(), cap: 4)
        let marked = result.records.filter { $0.promotedFromOlderWindow == true }
        #expect(marked.count == 1, Comment(rawValue:
            "\(marked.count) of the \(result.records.count) kept records say they were promoted, so a "
            + "reader cannot tell the out of band member from the window (#4122)"))
        #expect(marked.first?.seconds == 1_047.0)
        // And it is the FIRST line, which is where the promotion inserts it and therefore where a reader
        // of the file's head actually meets it.
        #expect(result.records.first?.promotedFromOlderWindow == true)
    }

    // THE TRAP, and the reason marking is a mutation of a copy rather than a rebuild through the
    // initialiser. `surfaceVocabulary` is DERIVED in `init` from the running build, so a promoted record
    // rebuilt that way would silently acquire today's vocabulary size while claiming to be the record an
    // older build wrote, which is the one field that would read as correct and be wrong (L443, L510).
    @Test("marking a record changes nothing about it but the mark")
    func markingPreservesEveryOtherField() throws {
        // DECODED from a line an OLDER build would have written, rather than constructed here, and that is
        // what makes this guard able to fail. A record built in this process carries today's
        // `surfaceVocabulary` because `init` derives it, so comparing a rebuild against a fresh original
        // would find them equal and prove nothing (L48, L70). `surfaceVocabulary: 7` is a build that knew
        // seven surfaces; today's knows more, so a rebuild restamps it and the comparison sees it.
        let older = #"{"session":"old","sequence":1,"at":"2026-09-18T11:02:00Z","seconds":1047.9,"#
            + #""surface":"queue","load":"elevated","loadAverage":95.8,"surfaceVocabulary":7,"#
            + #""passes":3,"rootDraws":2,"passSeconds":0.25,"windows":"open","asleepSeconds":12.5}"#
        let data = try #require(older.data(using: .utf8))
        let original = try FreezeLog.decoder().decode(StallRecord.self, from: data)
        #expect(original.surfaceVocabulary == 7, "the fixture no longer carries an older vocabulary")

        var records = (1..<10).map { stall(0.2 + Double($0) * 0.1, sequence: $0 + 1, at: day($0)) }
        records.insert(original, at: 0)
        let result = FreezeLog.compacted(records, cap: 4)
        let promoted = try #require(result.records.first { $0.promotedFromOlderWindow == true })

        #expect(promoted.identity == original.identity)
        #expect(promoted.at == original.at)
        #expect(promoted.seconds == original.seconds)
        #expect(promoted.surface == original.surface)
        #expect(promoted.load == original.load)
        #expect(promoted.loadAverage == original.loadAverage)
        #expect(promoted.passes == original.passes)
        // The four fields a rebuild through `init` would silently drop to their defaults, and the one it
        // would silently restamp. Each is named rather than covered by an equality on the whole record,
        // so a failure says WHICH field moved.
        #expect(promoted.rootDraws == 2)
        #expect(promoted.passSeconds == 0.25)
        #expect(promoted.windows == .open)
        #expect(promoted.asleepSeconds == 12.5)
        #expect(promoted.surfaceVocabulary == 7, Comment(rawValue:
            "the promoted record's surface vocabulary changed from 7 to "
            + "\(String(describing: promoted.surfaceVocabulary)), so marking it rebuilt the record "
            + "instead of copying it and rewrote the one field that records which build wrote it"))
    }

    // A compaction that promoted NOTHING must mark nothing, or the mark stops meaning anything.
    @Test("a compaction that promotes nothing marks nothing")
    func nothingIsMarkedWhenNothingIsPromoted() {
        // Ascending, so the longest record is the newest and the promotion rule cannot fire.
        let records = (0..<10).map { stall(0.2 + Double($0) * 0.1, sequence: $0 + 1, at: day($0)) }
        let result = FreezeLog.compacted(records, cap: 4)
        #expect(result.dropped == 6, "this did not exercise the cap, so it proves nothing either way")
        #expect(result.records.allSatisfy { $0.promotedFromOlderWindow != true })
    }

    // MARK: - The file says what its window is

    @Test("a compaction writes a note naming what it kept, archived and promoted")
    func theFileCarriesANoteAboutItsOwnWindow() throws {
        let dir = try sandboxes.make(named: "freeze-window-note")
        let log = FreezeLog.url(in: dir)
        writeLog(aLogWithAnOutlierInItsOldestHalf(), to: log)

        FreezeLog.compact(at: log, cap: 4)

        let read = FreezeLog.read(at: log)
        let note = try #require(read.notes.first, Comment(rawValue:
            "the compacted file carries no note at all, so a reader holds a truncated window with one "
            + "out of band member in it and nothing in the file says so (#4122)"))
        #expect(read.notes.count == 1, "one note per file, describing the file it sits in")
        #expect(note.kept == read.records.count)
        #expect(note.archived == 6)
        #expect(note.promotedAt == day(0))
        #expect(note.promotedSeconds == 1_047.0)
    }

    // The note is not a stall, and must not be counted as one or as a line that could not be read. Both
    // failures are silent: the first inflates every count taken from the file, the second reads as the
    // corruption a half written file produces, which is an ordinary state here (L11, L98).
    @Test("the note is neither a record nor an unreadable line")
    func theNoteIsKeptApartFromTheRecords() throws {
        let dir = try sandboxes.make(named: "freeze-note-apart")
        let log = FreezeLog.url(in: dir)
        writeLog(aLogWithAnOutlierInItsOldestHalf(), to: log)

        FreezeLog.compact(at: log, cap: 4)

        let read = FreezeLog.read(at: log)
        #expect(read.records.count == 4, Comment(rawValue:
            "the file read as \(read.records.count) records against a cap of 4, so the note is being "
            + "counted as a stall"))
        #expect(read.unreadableLines == 0, Comment(rawValue:
            "\(read.unreadableLines) line(s) read as unreadable, so the note reads as the corruption a "
            + "process killed mid freeze leaves behind"))
    }

    // THE WHOLE POINT, stated as the question a reader actually asks: given the file, can a consumer
    // separate the window from the record promoted into it (L11)?
    @Test("a consumer can tell the promoted record from the window it sits in")
    func aConsumerCanSeparateThePromotedRecordFromTheWindow() throws {
        let dir = try sandboxes.make(named: "freeze-window-split")
        let log = FreezeLog.url(in: dir)
        writeLog(aLogWithAnOutlierInItsOldestHalf(), to: log)

        FreezeLog.compact(at: log, cap: 4)
        let read = FreezeLog.read(at: log)

        let window = read.records.filter { $0.promotedFromOlderWindow != true }
        let promoted = read.records.filter { $0.promotedFromOlderWindow == true }
        #expect(promoted.count == 1)
        #expect(window.count == read.records.count - 1)
        // The maximum over the window and the maximum over the file are different numbers, which is the
        // defect restated as arithmetic: quoting the second as "the worst freeze in this window" is what
        // the file used to invite.
        let worstInWindow = window.map(\.seconds).max() ?? 0
        let worstInFile = read.records.map(\.seconds).max() ?? 0
        #expect(worstInFile == 1_047.0)
        #expect(worstInWindow < worstInFile, Comment(rawValue:
            "the promoted record is not the longest in the file, so this fixture no longer reproduces "
            + "the reading that motivated the issue"))
        // And the note agrees with the record, so the two marks cannot drift into two answers (L70).
        #expect(read.notes.first?.promotedAt == promoted.first?.at)
    }

    // MARK: - The file Dan has today

    // A log written before any of this shipped carries no note and no marks, and that must be
    // DISTINGUISHABLE from a compacted file that promoted nothing. Otherwise "this window is clean" and
    // "nobody recorded whether it is" read alike, which is the same defect one level up (L98).
    @Test("a log written before this shipped carries no note, which is its own answer")
    func anOlderLogSaysNothingRatherThanSayingItIsClean() throws {
        let dir = try sandboxes.make(named: "freeze-older-log")
        let log = FreezeLog.url(in: dir)
        writeLog(aLogWithAnOutlierInItsOldestHalf(), to: log)

        let read = FreezeLog.read(at: log)
        #expect(read.notes.isEmpty)
        #expect(read.records.count == 10)
        #expect(read.records.allSatisfy { $0.promotedFromOlderWindow == nil }, Comment(rawValue:
            "a record nobody promoted claims to know it was not promoted, so absent and false are the "
            + "same value here and an older file reads as a measured clean one"))
    }

    // MARK: - Round trips

    @Test("the mark survives the round trip through the log")
    func theMarkSurvivesTheRoundTrip() throws {
        var record = stall(1_047.0, sequence: 1, at: day(0))
        record.promotedFromOlderWindow = true
        let line = try #require(FreezeLog.line(for: record))
        let data = try #require(line.data(using: .utf8))
        let back = try FreezeLog.decoder().decode(StallRecord.self, from: data)
        #expect(back.promotedFromOlderWindow == true)
    }

    @Test("a note survives the round trip through the log")
    func theNoteSurvivesTheRoundTrip() throws {
        let note = FreezeLogNote(at: day(3), kept: 500, archived: 526,
                                 promotedAt: day(0), promotedSeconds: 1_047.0)
        let line = try #require(FreezeLog.line(for: note))
        let data = try #require(line.data(using: .utf8))
        let back = try FreezeLog.decoder().decode(FreezeLogNote.self, from: data)
        #expect(back == note)
    }
}
