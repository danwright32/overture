import Testing
import Foundation

// #3036: the sibling sweep #2930 asked for.
//
// #2930 fixed `StoreColumnCensus` answering one `nil` for six different refusals, and the same shape
// turned up one level down in the helper the fix itself used. The question this suite settles is whether
// the habit is anywhere else: every place that reads the store's SQLite directly, derived from a grep for
// `sqlite3_` rather than from memory (L96).
//
// The list, measured 2026-08-21, is four files. `StoreColumnCensus` is #2930's own and now answers a
// `Reading`. `StoreSchemaGuard` was already clean: it carries `.unreadable(detail:)` and every failure
// path reaches it. `StoreShrinkCheck.rowCount` was already clean too, and says so in its own comment:
// nil, never 0, because zero rows would invent a catastrophe out of a file that could not be counted.
//
// The one gap was ABOVE the SQLite call, in the step that decides which backup to count. A backups
// directory that could not be LISTED became an empty list, became `.none`, and `.none` means "first
// launch, no history yet, nothing to say" (L105, L42). So the launch most likely to be in trouble, one
// where Overture cannot read its own backup folder, was the one that said nothing at all, and the file's
// own comment already states the rule it was breaking: a backup that exists and cannot be read must not
// pass as fine.
@Suite("Every direct store reader refuses rather than answering (#3036)")
struct StoreReaderRefusalSweepTests {
    private func directory() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shrink-sweep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // A store with no backups directory at all is a fresh install. Unchanged, and the case that makes the
    // gap below invisible: both used to answer `.none`.
    @Test func noBackupsDirectoryYetIsNotAFinding() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(StoreShrinkCheck.previousCount(dataDirectory: dir) == .none)
    }

    // A backups directory that exists and holds nothing countable is also no history. Unchanged.
    @Test func anemptyBackupsDirectoryIsNotAFinding() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(
            at: StoreBackup.backupsDirectory(dataDirectory: dir), withIntermediateDirectories: true)

        #expect(StoreShrinkCheck.previousCount(dataDirectory: dir) == .none)
    }

    // THE gap. The directory is there and cannot be listed, which is not the same fact as there being no
    // backups, and it was reported as though it were.
    @Test func abackupsDirectoryThatCannotBeListedIsARefusal() throws {
        let dir = try directory()
        let backups = StoreBackup.backupsDirectory(dataDirectory: dir)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: backups.path)
            try? FileManager.default.removeItem(at: dir)
        }
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: backups.appendingPathComponent("20260101-120000"), withIntermediateDirectories: true)
        // Unreadable to its owner, which is what a permissions fault or a half-mounted volume looks like
        // from here. Proved below rather than assumed: a test asserting that something is refused is
        // satisfied by a fixture where it could not have been read anyway (L159).
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: backups.path)
        try #require((try? FileManager.default.contentsOfDirectory(atPath: backups.path)) == nil,
                     "the fixture has to actually be unlistable, or this proves nothing")

        let previous = StoreShrinkCheck.previousCount(dataDirectory: dir)

        #expect(previous != .none, "an unreadable backup folder read as a first launch with no history")
        #expect(previous == .backupsUnreadable)
    }

    // And it reaches Dan, under the heading that says only what was measured. The shrink heading would
    // claim shows are missing, which is precisely what nobody knows here.
    @Test func therefusalIsShownAndDoesNotClaimAnythingIsMissing() {
        let finding = StoreShrinkCheck.warning(live: 40, previous: .backupsUnreadable)

        #expect(finding?.title == StoreShrinkCheck.unreadableTitle)
        #expect(finding?.title != StoreShrinkCheck.shrankTitle)
        #expect(finding?.message.isEmpty == false)
    }

    // The two refusals say different things, because they are different faults with different next moves:
    // one names a backup to check, the other names the folder Overture could not open at all (L11).
    @Test func thetwoRefusalsDoNotShareOneSentence() {
        let theFolder = StoreShrinkCheck.warning(live: 1, previous: .backupsUnreadable)
        // Over several names, so the difference cannot be the interpolation. An earlier version of this
        // compared one of each with DIFFERENT names in them, which two sentences differ by whatever they
        // say, and a mutation pointing one case at the other's sentence survived it.
        for name in ["20260101-120000", "20260815-093000"] {
            let oneBackup = StoreShrinkCheck.warning(live: 1, previous: .unreadable(name))
            #expect(oneBackup?.message != theFolder?.message)
            #expect(oneBackup?.message.contains(name) == true)
        }
        // And the folder-wide one carries no name at all, because the path is already on screen below it.
        #expect(theFolder?.message.contains("(") == false)
    }

    // The other two readers, re-checked here rather than left to memory, so this suite is the sweep's
    // record and not just its one fix.
    @Test func thestoreSchemaGuardStillRefusesAFileItCannotRead() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("Overture.store")
        try Data("not a database at all".utf8).write(to: path)

        let identity = StoreSchemaGuard.identity(of: path)

        #expect(identity != .overtures)
        #expect(StoreSchemaGuard.hasExpectedSchema(at: path) == false,
                "a file it cannot read must refuse the launch, never pass as Overture's own")
    }

    @Test func therowCountAnswersNilRatherThanZeroForAFileItCannotCount() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("Overture.store")
        try Data("not a database at all".utf8).write(to: path)

        // Zero would read as "the store emptied", which is a catastrophe invented out of not knowing.
        #expect(StoreShrinkCheck.rowCount(at: path) == nil)
    }
}
