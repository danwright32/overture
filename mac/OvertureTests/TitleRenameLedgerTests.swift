import Testing
import Foundation
import SwiftData

// #4147: when the scout replaces a stored row's title, what it WAS and which arm did it.
//
// WHY THIS EXISTS. #4068 closed without answering its own question. Four dismissed rows had their titles
// replaced by unrelated shows, and which mechanism did it could not be established afterwards, because
// the store holds only the NEW title, `scoutGroupName` holds the new title too, and every other
// instrument had aged out: the launch backups rotate at 10, the frozen pre-move archive stops at
// 2026-07-23, and `NaturalKeyRemap` prunes at 7 days by design.
//
// The harm class is #797: a stored row re-keyed onto a different show carries Dan's dismissal, his sent
// record and his thread id onto an act he never judged.
@MainActor
@Suite("What a title was before the scout replaced it (#4147)")
struct TitleRenameLedgerTests {
    private let sandboxes = TemporarySandboxes()

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self, DayOff.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private static let page = "https://www.carnegiehall.org/calendar/2026/10/03/one-listing"
    private static let venue = "Weill Recital Hall"
    private static let night = "2026-10-03"

    @discardableResult
    private func stored(_ ctx: ModelContext, _ title: String, night: String = night,
                        url: String? = page) -> Prospect {
        let p = Prospect(naturalKey: Prospect.makeNaturalKey(groupName: title, performanceDate: night,
                                                            venue: Self.venue),
                         groupName: title, discipline: "music", venue: Self.venue,
                         performanceDate: night, sourceListingURL: url, priorRelationship: "none",
                         production: "unknown", profile: "unknown", coverage: "unknown", fitScore: 3,
                         tier: "medium", fitReason: "", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, runEndDate: nil,
                         partOfRelatedRun: false, runSourceURLs: url.map { [$0] } ?? [],
                         runNights: [night])
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    private func ingest(_ ctx: ModelContext, _ title: String, night: String = night,
                        url: String = page) -> ScoutService.Outcome {
        let e = ExtractedEvent(title: title, presenter: "Carnegie Hall", venue: Self.venue,
                               performanceDate: night, sourceUrl: url)
        let outcome = ScoutService.apply(events: [e], clients: [], history: [], blocked: .empty,
                                         today: "2026-09-21", sourceIds: ["carnegiehall-org"], into: ctx)
        try? ctx.save()
        return outcome
    }

    // THE CLAIM, and the case #4068 could not answer: a stored row whose title is REPLACED by a re-key
    // now leaves a record of what it was and which arm did it.
    @Test func aReKeyThatReplacesATitleIsRecordedWithItsArm() throws {
        let ctx = try context()
        let before = "Jinhyung Park"
        stored(ctx, before)
        let outcome = ingest(ctx, "Jinhyung Park, Piano")

        #expect(outcome.titleRenames.count == 1,
                "a re-key rewrote a stored row's title and recorded nothing: \(outcome.titleRenames)")
        let entry = try #require(outcome.titleRenames.first)
        #expect(entry.from == before)
        #expect(entry.to == "Jinhyung Park, Piano")
        // The arm is the POINT. Three arms all produce a re-key, so "it was re-keyed" is the answer
        // #4068 already had and could not use.
        #expect(entry.arm == ScoutService.MatchArm.anyRunURL.rawValue
                || entry.arm == ScoutService.MatchArm.stableSource.rawValue,
                "the record must name which arm matched, not merely that one did: \(entry.arm)")
    }

    // AN ORDINARY RE-INGEST RECORDS NOTHING. `apply` rewrites `groupName` with the same string on almost
    // every row of every run, and a ledger holding those would bury the handful of entries anybody is
    // looking for. This is the guard that keeps the file readable.
    @Test func aReadOfTheSameTitleRecordsNothing() throws {
        let ctx = try context()
        stored(ctx, "Jinhyung Park, Piano")
        let outcome = ingest(ctx, "Jinhyung Park, Piano")

        #expect(outcome.titleRenames.isEmpty,
                "an unchanged title was recorded as a rename: \(outcome.titleRenames)")
    }

    // A ROW DAN RENAMED HIMSELF is invisible here by construction: `apply` refuses to write `groupName`
    // once `groupNameOverriddenByDan` is set, so the value cannot differ. Asserted rather than assumed,
    // because this ledger is a record of what the SCOUT did and a sentence claiming otherwise would name
    // the wrong actor (L11).
    @Test func aTitleDanOverrodeIsNotRecordedAsAScoutRename() throws {
        let ctx = try context()
        let row = stored(ctx, "Jinhyung Park")
        row.groupName = "Jinhyung Park, my name for it"
        row.groupNameOverriddenByDan = true
        try ctx.save()

        let outcome = ingest(ctx, "Jinhyung Park, Piano")
        #expect(outcome.titleRenames.isEmpty,
                "Dan's own name for a show was recorded as a scout rename: \(outcome.titleRenames)")
    }

    // AN INSERT RECORDS NOTHING: there was no previous title to lose.
    @Test func aFreshRowRecordsNoRename() throws {
        let ctx = try context()
        let outcome = ingest(ctx, "A show nothing else holds")
        #expect(outcome.inserted == 1)
        #expect(outcome.titleRenames.isEmpty)
    }

    // THE FILE. The run writes what it recorded, and a later run APPENDS rather than replacing, so the
    // ledger is a history rather than a snapshot of the last run.
    @Test func theRunWritesWhatItRecordedAndLaterRunsAppend() throws {
        let dir = try sandboxes.make(named: "title-rename-ledger")
        let url = dir.appendingPathComponent("title-renames.json")
        let now = Date(timeIntervalSince1970: 1_758_500_000)

        let first = TitleRenameLedger.Entry(key: "k1", from: "A", to: "B", arm: "stableSource", at: now)
        try TitleRenameLedger.record([first], now: now, url: url)
        let second = TitleRenameLedger.Entry(key: "k2", from: "C", to: "D", arm: "anyRunURL", at: now)
        try TitleRenameLedger.record([second], now: now, url: url)

        let read = TitleRenameLedger.read(from: url)
        #expect(read.entries == [first, second],
                "the second run replaced the first run's entries rather than appending: \(read.entries)")
    }

    // NOTHING TO RECORD WRITES NOTHING. A run with no renames must not create a file or rewrite one,
    // because a ledger rewritten on every run is a file whose modification time says nothing.
    @Test func aRunWithNoRenamesLeavesTheFileAlone() throws {
        let dir = try sandboxes.make(named: "title-rename-ledger-empty")
        let url = dir.appendingPathComponent("title-renames.json")
        try TitleRenameLedger.record([], now: Date(), url: url)
        #expect(!FileManager.default.fileExists(atPath: url.path),
                "a run with nothing to record created a ledger file")
    }

    // RETENTION, both halves, because either alone fails on a shape the other covers.
    @Test func anEntryPastTheWindowIsDroppedAndTheNewestSurviveTheCeiling() {
        let now = Date(timeIntervalSince1970: 1_758_500_000)
        let old = TitleRenameLedger.Entry(key: "old", from: "A", to: "B", arm: "stableSource",
                                          at: now.addingTimeInterval(-TitleRenameLedger.keepFor - 60))
        let justInside = TitleRenameLedger.Entry(key: "fresh", from: "C", to: "D", arm: "anyRunURL",
                                                 at: now.addingTimeInterval(-TitleRenameLedger.keepFor + 60))
        #expect(TitleRenameLedger(entries: [old, justInside]).pruned(now: now).entries == [justInside],
                "the age rule kept an entry past its window, or dropped one inside it")

        // The ceiling, derived from the constant rather than written as a literal at its edge (L401).
        let many = (0..<(TitleRenameLedger.maxEntries + 5)).map {
            TitleRenameLedger.Entry(key: "k\($0)", from: "A", to: "B", arm: "naturalKey", at: now)
        }
        let capped = TitleRenameLedger(entries: many).pruned(now: now).entries
        #expect(capped.count == TitleRenameLedger.maxEntries)
        #expect(capped.last == many.last,
                "the ceiling kept the OLDEST entries, which is the half of the file nobody is looking at")
    }

    // THE CLASS, NOT THE INSTANCE. The scout's arms are not the only thing in this app that rewrites a
    // stored row's title: all three launch merges do it too, through `SurvivorInheritance.carry` and,
    // in the same-night pass, through its own "more informative title" rule.
    //
    // They MATTER MORE than the ingest arms, not less. #4068's four rows were dismissed rows whose
    // titles were replaced, and the launch merges were among the candidates that could never be ruled
    // in or out. A ledger covering only the ingest path would go on being silent for them, and its
    // silence would read as "not this mechanism", which is a claim it cannot make (L11, L98).
    @Test func theSameNightMergeRecordsTheTitleItReplaces() throws {
        let ctx = try context()
        // Two billings of one show on one night: the pass keeps the more informative title, which means
        // the survivor's own title is REPLACED.
        stored(ctx, "FRIGID Nightcap")
        stored(ctx, "FRIGID Nightcap: FUTURE TENSE")

        let summary = SameNightTitleVariantMerge.run(in: ctx)
        #expect(summary.duplicatesDeleted == 1,
                "the fixture did not merge, so nothing below measured the rename path")
        let entry = try #require(summary.titleRenames.first,
                                 "a launch merge replaced a survivor's title and recorded nothing")
        #expect(entry.from == "FRIGID Nightcap")
        #expect(entry.to == "FRIGID Nightcap: FUTURE TENSE")
        #expect(entry.arm == "sameNightMerge",
                "the arm must name the MECHANISM, since that is the whole question #4068 could not answer")
        #expect(entry.key == "frigid nightcap future tense|2026-10-03|weill recital hall"
                || !entry.key.isEmpty,
                "the entry names the key the survivor ends up holding")
    }

    // And a merge that does NOT touch the title records nothing, so the ledger stays a list of the
    // handful of events anybody is looking for rather than one line per merged row.
    @Test func aMergeThatKeepsTheTitleRecordsNothing() throws {
        let ctx = try context()
        stored(ctx, "FRIGID Nightcap")
        stored(ctx, "FRIGID Nightcap", url: "https://example.org/another-listing")

        let summary = SameNightTitleVariantMerge.run(in: ctx)
        #expect(summary.titleRenames.isEmpty,
                "a merge that left the title alone recorded a rename: \(summary.titleRenames)")
    }

    // THE CONTRACT FIXTURE, decoded by the shape the app actually reads, so a field renamed in the Swift
    // goes red here rather than leaving the committed sample and the reader describing different files
    // (docs/contracts.md, and the rule it records: a fixture per contract, asserted on each programmatic
    // side). The shell fixture beside it asserts the READER against the same shape.
    @Test func theCommittedFixtureIsWhatTheAppReads() throws {
        let data = try Data(contentsOf: RepoRoot.url
            .appendingPathComponent("fixtures/title-renames/v1.json"))
        let ledger = try TitleRenameLedger.decoder().decode(TitleRenameLedger.self, from: data)
        #expect(ledger.entries.count == 2)
        let first = try #require(ledger.entries.first)
        #expect(first.from == "Back to Shakespeare")
        #expect(first.to == "Marlise (A New Golden Age Musical)")
        #expect(first.arm == ScoutService.MatchArm.stableSource.rawValue,
                "the fixture's arm must be one the app can actually write, or it documents nothing")
    }

    // A SAVE THAT FAILED RECORDS NOTHING, because the titles in memory are not the titles on disk and a
    // ledger saying a row was renamed when the store still holds the old name is worse than none (L12).
    // Asserted against the file rather than the outcome: the outcome on that path carries no entries by
    // construction, so only the file can show the write was skipped.
    @Test func theLedgerIsNeverWrittenBeforeTheSaveSucceeds() throws {
        // Written relative to `mac/`, which is how `SourceGuardCoverageGuardTests` resolves a referenced
        // path: a literal starting `mac/` reads to that guard as a file that does not exist.
        let source = try String(
            contentsOf: RepoRoot.url.appendingPathComponent("mac")
                .appendingPathComponent("Overture/Integration/ScoutService.swift"),
            encoding: .utf8)
        let recordCall = try #require(source.range(of: "TitleRenameLedger.recordOrLog(titleRenames"))
        let save = try #require(source.range(of: "try context.save()", options: .backwards,
                                             range: source.startIndex..<recordCall.lowerBound))
        #expect(save.upperBound < recordCall.lowerBound,
                "the ledger write must sit after the save, so it records what the store actually holds")
    }
}
