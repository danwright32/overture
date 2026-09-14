import Testing
import Foundation

// #3811: the card divergence log's compaction, which until now had no caller and therefore never ran.
//
// WHAT WAS ACTUALLY WRONG, because it was two things and only one of them is the missing call.
// `docs/contracts.md` said the file was "COMPACTED AT LAUNCH", and `CardDivergenceLog.compact` appeared
// nowhere in the app: `grep -rn "CardDivergenceLog\." mac/Overture/` returned `append`, `read` and three
// UserDefaults keys, and no compaction. So the rule that document describes, keeping one example of each
// distinct FIELD SET so a common divergence cannot evict the only record of a rare one, had never run
// once and the document was the only thing saying otherwise (L32, L407).
//
// And wiring it up as it stood would have been the wrong fix. It DELETED what it dropped. A compaction is
// the last anyone would ever have seen of those records, which is the question #3763 already settled for
// the freeze log: archive, never discard (L5). Fixing the missing call without settling that would have
// started permanently deleting divergence records for the first time, as a side effect of fixing
// something else.
@Suite("The divergence log is compacted, and keeps what it drops (#3811)")
struct TheDivergenceLogIsCompactedTests {
    private let sandboxes = TemporarySandboxes()

    private func record(_ sequence: Int, fields: [String], session: String = "s") -> CardDivergenceRecord {
        CardDivergenceRecord(session: session, sequence: sequence,
                             at: Date(timeIntervalSince1970: 1_800_000_000 + Double(sequence)),
                             fields: fields, cardsBuilt: 20, stage: nil)
    }

    private func write(_ records: [CardDivergenceRecord], to url: URL) throws {
        let text = records.compactMap(CardDivergenceLog.line(for:)).joined(separator: "\n") + "\n"
        #expect(text.count > 1, "the fixture encoded nothing, so nothing below is measured")
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // THE FINDING THIS ISSUE IS ABOUT. What a compaction drops is written to the archive, not deleted.
    @Test func compactionArchivesWhatItDropsRatherThanDeletingIt() throws {
        let dir = try sandboxes.make(named: "divergence-compact")
        let url = CardDivergenceLog.url(in: dir)
        let rare = record(0, fields: ["draftLintBlockers"])
        let common = (1...12).map { record($0, fields: ["venue"]) }
        try write([rare] + common, to: url)

        let outcome = CardDivergenceLog.compact(at: url, cap: 10)

        #expect(outcome == .archived(count: 3))
        // The live file is trimmed and still holds the rare kind, which is the rule the contract states.
        let live = CardDivergenceLog.read(at: url)
        #expect(live.records.count == 10)
        #expect(live.records.contains(rare))
        // And the three it dropped are IN THE ARCHIVE rather than gone, which is the whole change.
        let archived = CardDivergenceLog.read(at: CardDivergenceLog.archiveURL(besideLogAt: url))
        #expect(archived.records.count == 3, """
        the compaction dropped three records and the archive holds \(archived.records.count) of them, so \
        what it took out was deleted rather than kept
        """)
        #expect(archived.unreadableLines == 0)
    }

    // A FAILED ARCHIVE ABANDONS THE TRUNCATION. The order is the whole safeguard: these are two writes
    // with no transaction around them, so doing the destructive half first would leave a failed archive
    // indistinguishable from a clean compaction, with the records already gone (L5).
    //
    // The failure is forced by putting a DIRECTORY where the archive file goes, so the write cannot
    // succeed. That is a real filesystem refusal rather than an injected flag, which is what makes this a
    // test of the ordering rather than of a seam.
    @Test func aFailedArchiveLeavesTheLiveFileOverItsCapRatherThanTrimmed() throws {
        let dir = try sandboxes.make(named: "divergence-archive-fails")
        let url = CardDivergenceLog.url(in: dir)
        let all = (0...12).map { record($0, fields: ["venue"]) }
        try write(all, to: url)
        try FileManager.default.createDirectory(at: CardDivergenceLog.archiveURL(besideLogAt: url),
                                                withIntermediateDirectories: true)

        let outcome = CardDivergenceLog.compact(at: url, cap: 10)

        #expect(outcome == .archiveFailed, """
        a compaction whose archive could not be written reported \(String(describing: outcome)), which \
        a caller cannot tell from a healthy one (L11)
        """)
        let live = CardDivergenceLog.read(at: url)
        #expect(live.records.count == all.count, """
        the live file was trimmed to \(live.records.count) after the archive failed, so those records are \
        in neither file
        """)
    }

    // Under the cap, nothing happens, and it says so rather than reporting a trim of zero.
    @Test func aFileUnderTheCapIsLeftAlone() throws {
        let dir = try sandboxes.make(named: "divergence-under-cap")
        let url = CardDivergenceLog.url(in: dir)
        try write((0...5).map { record($0, fields: ["venue"]) }, to: url)

        #expect(CardDivergenceLog.compact(at: url, cap: 10) == .nothingToArchive)
        let archiveExists = FileManager.default.fileExists(
            atPath: CardDivergenceLog.archiveURL(besideLogAt: url).path)
        #expect(!archiveExists, "an untouched log created an archive anyway")
    }

    // THE ARCHIVE IS BOUNDED BY KIND, and this is the one judgement in the change rather than a copy of
    // the freeze log's answer.
    //
    // `FreezeLog` keeps a month, and its own comment explains that this is safe there because the reading
    // it supports is the MAXIMUM, which the live file protects separately and never drops. The reading
    // THIS file supports is which KINDS have ever happened, so an age-based prune would delete exactly the
    // rare record the compaction rescued, a month after rescuing it (L387). Bounded by distinct field set,
    // the archive cannot exceed the number of kinds the app can produce.
    @Test func theArchiveKeepsOneOfEachKindAndCannotGrowWithoutBound() throws {
        let dir = try sandboxes.make(named: "divergence-prune")
        let url = CardDivergenceLog.url(in: dir)
        let archive = CardDivergenceLog.archiveURL(besideLogAt: url)
        // Two kinds, many copies, and the OLDEST of each is the one worth keeping.
        let oldestVenue = record(1, fields: ["venue"])
        let oldestLint = record(2, fields: ["draftLintBlockers"])
        let laterCopies = (3...40).map { record($0, fields: $0 % 2 == 0 ? ["venue"] : ["draftLintBlockers"]) }
        try write([oldestVenue, oldestLint] + laterCopies, to: archive)

        let outcome = CardDivergenceLog.pruneArchive(besideLogAt: url)

        #expect(outcome == .removed(count: 38))
        let kept = CardDivergenceLog.read(at: archive)
        #expect(kept.records.count == 2, "the archive kept \(kept.records.count) records for two kinds")
        #expect(kept.records.contains(oldestVenue))
        #expect(kept.records.contains(oldestLint), """
        the archive dropped the oldest example of a kind, which is the first time that kind was ever seen \
        and the fact this file exists to hold
        """)
    }

    // REFUSED on a short read, not only on a failed one. This rewrites the archive from what the read
    // returned, so every line the read could not decode would be destroyed by the rewrite without ever
    // being counted, and a file half written by a process killed mid-append is the ordinary case here
    // rather than a rare one (L211, L105).
    @Test func aPruneRefusesRatherThanRewritingAnArchiveItCouldNotFullyRead() throws {
        let dir = try sandboxes.make(named: "divergence-prune-refuses")
        let url = CardDivergenceLog.url(in: dir)
        let archive = CardDivergenceLog.archiveURL(besideLogAt: url)
        let good = record(1, fields: ["venue"])
        let text = (CardDivergenceLog.line(for: good) ?? "") + "\n{ this line is not a record\n"
        try text.write(to: archive, atomically: true, encoding: .utf8)

        let outcome = CardDivergenceLog.pruneArchive(besideLogAt: url)

        #expect(outcome == .refused(unreadableLines: 1))
        // And the file is UNTOUCHED, which is what the refusal is for.
        let after = try String(contentsOf: archive, encoding: .utf8)
        #expect(after == text, "the archive was rewritten despite the refusal, so the unreadable line is gone")
    }

    // No archive is the ordinary state: most installs have never compacted.
    @Test func aPruneWithNoArchiveIsQuietRatherThanAFailure() throws {
        let dir = try sandboxes.make(named: "divergence-no-archive")
        #expect(CardDivergenceLog.pruneArchive(besideLogAt: CardDivergenceLog.url(in: dir)) == .nothingToRemove)
    }

    // COMPACT THEN PRUNE, in that order, and the order is load bearing: compacting CREATES the archive the
    // prune then bounds, so pruning first would leave whatever the compaction just wrote unbounded until
    // the next tick.
    @Test func housekeepingCompactsThenPrunesSoTheNewArchiveIsBoundedInTheSameRun() throws {
        let dir = try sandboxes.make(named: "divergence-housekeeping")
        let url = CardDivergenceLog.url(in: dir)
        // Thirteen records of ONE kind, so the compaction drops three into a fresh archive and the prune
        // in the same run reduces those three to the single oldest.
        try write((0...12).map { record($0, fields: ["venue"]) }, to: url)

        let done = CardDivergenceLog.housekeeping(at: url, cap: 10)

        #expect(done.compaction == .archived(count: 3))
        #expect(done.prune == .removed(count: 2), """
        the prune reported \(String(describing: done.prune)), so it ran BEFORE the compaction and found \
        nothing to bound, which leaves the archive the compaction wrote unbounded until the next tick
        """)
        let archived = CardDivergenceLog.read(at: CardDivergenceLog.archiveURL(besideLogAt: url))
        #expect(archived.records.count == 1)
        #expect(!done.isQuiet)
    }

    // A quiet run says so, which is what lets a caller tell "nothing needed doing" from "something went
    // wrong" without reading two enums (L11).
    @Test func aRunWithNothingToDoReportsItselfQuiet() throws {
        let dir = try sandboxes.make(named: "divergence-quiet")
        let url = CardDivergenceLog.url(in: dir)
        try write([record(1, fields: ["venue"])], to: url)

        #expect(CardDivergenceLog.housekeeping(at: url, cap: 10).isQuiet)
    }
}

// The half that made this issue exist: the compaction had no caller. A rule enforced by nothing is a rule
// that never runs, and this one had a document describing it for weeks (L27, L407).
@Suite("The divergence log's housekeeping is actually called (#3811)")
struct TheDivergenceHousekeepingIsWiredTests {
    @Test func theAppRunsTheDivergenceHousekeepingFromTheSamePlaceAsTheFreezeLogs() {
        let root = SourceGuardHelper.source("Overture/App/RootView.swift")
        #expect(!root.isEmpty)
        // The SAME method, so the two cannot drift into being called from different moments. That is the
        // whole reason this one was forgotten: it had a call site of its own to be added to, and nobody
        // added it (L621, L613).
        let body = SourceGuardHelper.bodyOfFunction(named: "runFreezeLogHousekeeping", in: root) ?? ""
        #expect(!body.isEmpty, "runFreezeLogHousekeeping could not be read, so nothing below was measured")
        #expect(body.contains("runCardDivergence("), """
        the freeze log's housekeeping runs without the divergence log's, which is the state that left \
        CardDivergenceLog.compact with no caller anywhere in the app
        """)
    }

    // Through the SAME actor, not a second one. Two actors would serialise each against itself while
    // letting the two run together, which is the main-actor contention #3828 moved this work off (L369).
    @Test func bothLogsSharedOneHousekeeperSoTheyCannotRunAtOnce() {
        let keeper = SourceGuardHelper.source("Overture/Integration/FreezeLogHousekeeper.swift")
        #expect(!keeper.isEmpty)
        #expect(keeper.contains("func runCardDivergence("))
        #expect(keeper.contains("CardDivergenceLog.housekeeping("))
        // One instance is what makes the serialisation real.
        #expect(keeper.contains("static let shared = FreezeLogHousekeeper()"))
    }

    // And the document stops claiming a thing that does not happen, which is the third half of this issue.
    @Test func theContractSaysWhenTheCompactionActuallyRuns() {
        let contracts = SourceGuardHelper.source("../docs/contracts.md")
        #expect(!contracts.isEmpty, "docs/contracts.md could not be read, so nothing below was measured")
        let claimsLaunchOnly = contracts.contains("`CardDivergenceLog.fileCap`, COMPACTED AT LAUNCH,")
        #expect(!claimsLaunchOnly, """
        the contract still says the divergence log is compacted AT LAUNCH, which was true of nothing: it \
        had no caller at all, and it now runs at launch and on the hourly tick
        """)
        #expect(contracts.contains("card-divergence-archive.ndjson"), """
        the contract does not mention the archive, so a reader still expects a compaction to delete
        """)
    }
}
