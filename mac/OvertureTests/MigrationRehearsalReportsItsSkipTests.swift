import Testing
import Foundation

// #3035: a rehearsal that examined ZERO subjects must not read as one where everything passed.
//
// The four migration dry runs stand between a schema change and Dan's only copy of his queue, and each
// returned SILENTLY on a machine with no live store: same green tick, same nothing on screen, whether it
// rehearsed the migration against 936 real prospects or never opened a file. That is the exact reading
// L98 exists to stop, and this repo already refuses it at three other entry points (`NOTHING RAN` in
// run-tests-locked.sh, the no-assertion rule in run-shell-fixtures.sh, #2541).
//
// It is not made a FAILURE, and that is deliberate: a fresh clone and a CI runner genuinely have no live
// store, so a gate there would be red for everyone who has not run the app, which is a gate nobody can go
// green on. What it gets is a voice.
@Suite("A migration rehearsal says when it rehearsed nothing (#3035)")
struct MigrationRehearsalReportsItsSkipTests {

    private func scratch() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rehearsal-report-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // The skip that used to be silent.
    @Test func noLiveStoreIsReportedAsASkipAndNamesTheRehearsal() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }

        let start = try MigrationRehearsal.begin("joint-send columns", liveStore: nil, into: dir)

        guard case let .skipped(said) = start else {
            Issue.record("a machine with no live store must report a skip, not a rehearsal")
            return
        }
        #expect(said.contains(MigrationRehearsal.marker))
        #expect(said.contains("joint-send columns"))
        #expect(said.contains("no live store"))
    }

    // A skip and a broken clone are DIFFERENT states and get different words, because a message may claim
    // only what its check measured (L11). One is an ordinary machine; the other is a rehearsal that tried
    // and could not, which is worth somebody's attention.
    @Test func aCloneThatCouldNotBeTakenSaysSomethingElseEntirely() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let live = dir.appendingPathComponent("not-really-a-store.sqlite")
        FileManager.default.createFile(atPath: live.path, contents: Data("not sqlite".utf8))

        let start = try MigrationRehearsal.begin("joint-send columns", liveStore: live, into: dir,
                                                 clone: { _, _ in nil })

        guard case let .cloneFailed(said) = start else {
            Issue.record("a clone that could not be taken must not report as an ordinary skip")
            return
        }
        #expect(said.contains(MigrationRehearsal.marker))
        #expect(!said.contains("no live store"))
        #expect(said.contains("could not"))
    }

    // And a machine that CAN rehearse gets the clone, so the report is not simply a refusal of everything
    // (a guard that refuses every input is indistinguishable from one that works, L1).
    @Test func aMachineWithALiveStoreIsHandedTheCloneToRehearseAgainst() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let live = dir.appendingPathComponent("live.store")
        FileManager.default.createFile(atPath: live.path, contents: Data("x".utf8))
        let pretendClone = dir.appendingPathComponent("clone.store")

        let start = try MigrationRehearsal.begin("joint-send columns", liveStore: live, into: dir,
                                                 clone: { _, _ in pretendClone })

        guard case let .rehearse(copy) = start else {
            Issue.record("a machine with a live store must be handed a clone")
            return
        }
        #expect(copy == pretendClone)
    }

    // The class, not the instance. The issue names two suites and there are FOUR, so the list is DERIVED
    // from the directory rather than written out here: a fifth rehearsal added later is covered without
    // anybody remembering (L96). Each must route its two silent exits through the helper.
    @Test func everyMigrationRehearsalRoutesItsSkipThroughTheHelper() throws {
        let dir = URL(fileURLWithPath: RepoRoot.mac.path).appendingPathComponent("OvertureTests")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix("MigrationDryRunTests.swift") }
            .sorted()
        #expect(names.count >= 4, "the rehearsals were not found, so nothing below was checked")

        var offenders: [String] = []
        for name in names {
            let source = SourceGuardHelper.source("OvertureTests/\(name)")
            if !source.contains("MigrationRehearsal.begin") {
                offenders.append("\(name): does not route through MigrationRehearsal.begin")
            }
            // The two silent returns this issue is about, in the exact shapes they were written in.
            if source.contains("else { return }   // no live store")
                || source.contains("try LiveStoreClone.makeClone(in: tmpDir) else { return }") {
                offenders.append("\(name): still returns silently")
            }
        }
        #expect(offenders.isEmpty, "\(offenders.joined(separator: "; "))")
    }
}
