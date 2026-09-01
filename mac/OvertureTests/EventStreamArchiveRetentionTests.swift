import Testing
import Foundation

// Milestone 61 Phase 1.2, and #3346.
//
// The event streams are the only per item evidence a run leaves. `RunSlot.chunkEventsURL` puts them at a
// FIXED per slot path, so the next run overwrites them, and `PrepRunArchive` deliberately excludes them.
//
// LIVE-STORE-CLAIM verified=2026-09-01 measure="the surviving chunk event streams in Application Support, their count and total size, and the sizes of every archived run folder for both slots"
// This is a measurement rather than a prediction. Measured 2026-08-30: the 20:52 run's ten streams were
// already gone, overwritten 45 minutes later by the 21:27 run, while its archived `webCalls` still
// reported `streams: 10`. The failing run's per item evidence was destroyed on the evening it was
// produced (L202). Re-measured 2026-09-01: 7 stream files survive, 1.7 MB in total, mean 252 KB.
//
// So the streams get their OWN dated directory with its OWN keep, rather than riding in the existing
// archive folder. `DatedFolderRotation.prune` rotates whole FOLDERS by one keep, so a single folder
// holding both would give one of the two consumers a lifetime nobody chose: at 10 the queue and results
// history collapses from 30 to 10, which is exactly the defect #2760 was filed to fix, and at 30 the
// 1.7 MB of streams stay for three times their budget (L285, L191). Same answer, same reason, as #2760.
@Suite("The event streams are archived on their own retention (#3357 Phase 1.2, #3346)")
struct EventStreamArchiveRetentionTests {

    private func scratch() throws -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("event-archive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func eachSlotsStreamsGetTheirOwnDirectory() throws {
        let support = URL(fileURLWithPath: "/tmp/support")
        #expect(RunSlot.check.eventArchivesDirectory(in: support).lastPathComponent
                == "check-run-event-archives")
        #expect(RunSlot.prep.eventArchivesDirectory(in: support).lastPathComponent
                == "prep-run-event-archives")
        // NOT the folder the queue and results pair uses, which is the whole point.
        #expect(RunSlot.check.eventArchivesDirectory(in: support)
                != RunSlot.check.archivesDirectory(in: support))
    }

    // The keeps are different NUMBERS for a stated reason, so a later reader cannot collapse them.
    @Test func theStreamsAreKeptForFewerRunsThanThePair() throws {
        #expect(RunSlot.check.eventArchiveKeep < RunSlot.check.archiveKeep)
        #expect(RunSlot.prep.eventArchiveKeep < RunSlot.prep.archiveKeep)
    }

    // THE TEST THAT MATTERS, and it measures what SURVIVES ON DISK rather than comparing two integers.
    // A constant comparison cannot see the rotation at all, so it would pass while measuring nothing
    // (L63, L212). Archive past BOTH keeps and assert, per directory, what is left.
    @Test func rotatingTheStreamsDoesNotDrainThePairsHistory() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let slot = RunSlot.check
        let pairDir = slot.archivesDirectory(in: root)
        let eventDir = slot.eventArchivesDirectory(in: root)
        for d in [pairDir, eventDir] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }

        // 61 runs, well past both keeps, each landing in BOTH directories under the same stamp.
        var stamps: [String] = []
        for i in 0..<61 {
            let stamp = String(format: "202601%02d-%02d0000", (i / 24) + 1, i % 24)
            stamps.append(stamp)
            for d in [pairDir, eventDir] {
                try FileManager.default.createDirectory(
                    at: d.appendingPathComponent(stamp, isDirectory: true),
                    withIntermediateDirectories: true)
            }
        }

        DatedFolderRotation.prune(in: pairDir, keep: slot.archiveKeep)
        DatedFolderRotation.prune(in: eventDir, keep: slot.eventArchiveKeep)

        let pairLeft = try FileManager.default
            .contentsOfDirectory(atPath: pairDir.path).filter(PrepRunArchive.isArchivedRunFolder).sorted()
        let eventsLeft = try FileManager.default
            .contentsOfDirectory(atPath: eventDir.path).filter(PrepRunArchive.isArchivedRunFolder).sorted()

        // The pair still holds its full 30 after 61 event archives have rotated. This is the assertion
        // that fails if the two ever share one directory or one keep.
        #expect(pairLeft.count == slot.archiveKeep,
                "the pair's history was drained by the streams' rotation")
        #expect(eventsLeft.count == slot.eventArchiveKeep)
        // And each kept the NEWEST, so what survives is the recent history rather than an arbitrary set.
        #expect(pairLeft == Array(stamps.sorted().suffix(slot.archiveKeep)))
        #expect(eventsLeft == Array(stamps.sorted().suffix(slot.eventArchiveKeep)))
    }

    // The archiving itself, not just the shape of the directory: a run's streams reach the archive under
    // the SAME stamp as its queue and results, so one run's evidence is found under one folder name in
    // both places.
    @Test func aFinishedRunsStreamsAreArchivedUnderTheRunsOwnStamp() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let slot = RunSlot.check

        try #"{"version":6,"generatedAt":"2026-08-30T20:52:44Z","items":[]}"#
            .write(to: slot.queueURL(in: root), atomically: true, encoding: .utf8)
        try #"{"version":11,"results":[]}"#
            .write(to: slot.resultsURL(in: root), atomically: true, encoding: .utf8)
        for chunk in 1...3 {
            try "{\"type\":\"result\",\"total_cost_usd\":0.1}\n"
                .write(to: slot.chunkEventsURL(chunk: chunk, in: root), atomically: true, encoding: .utf8)
        }

        let outcome = PrepRunArchive.archiveFinishedRun(slot: slot, handoffDirectory: root, now: Date())
        let stamp: String
        switch outcome {
        case .archived(let folder, _, _): stamp = folder.lastPathComponent
        case .alreadyArchived(let folder): stamp = folder.lastPathComponent
        default: Issue.record("the run was not archived: \(outcome)"); return
        }

        let streams = slot.eventArchivesDirectory(in: root).appendingPathComponent(stamp)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: streams.path)) ?? []).sorted()
        #expect(names.count == 3, "all three streams, found under the run's own stamp")
        #expect(names.first?.contains("chunk-1") == true)
    }

    // A run that produced NO streams leaves no empty folder claiming it had some. An empty archive folder
    // and a run whose streams were lost look identical to anyone reading later (L98, L11).
    @Test func aRunWithNoStreamsLeavesNoEmptyArchiveFolder() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let slot = RunSlot.check
        try #"{"version":6,"generatedAt":"2026-08-30T20:52:44Z","items":[]}"#
            .write(to: slot.queueURL(in: root), atomically: true, encoding: .utf8)

        _ = PrepRunArchive.archiveFinishedRun(slot: slot, handoffDirectory: root, now: Date())

        let dir = slot.eventArchivesDirectory(in: root)
        let folders = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter(PrepRunArchive.isArchivedRunFolder)
        #expect(folders.isEmpty)
    }

    // The keep the PRODUCTION PATH actually applies, which the rotation test above does not prove: it
    // calls `DatedFolderRotation.prune` itself, so it asserts the arithmetic and never that
    // `archiveEventStreams` passes the streams' own number. Caught by mutation: swapping
    // `slot.eventArchiveKeep` for `slot.archiveKeep` in the production call left that test green, which
    // is a guard measuring a proxy for the quantity it exists to protect (L63).
    @Test func theArchivingPathPrunesByTheStreamsOwnKeep() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let slot = RunSlot.check
        let past = slot.eventArchiveKeep + 5

        for i in 0..<past {
            // A fresh stream each round, since the previous one was copied, not moved.
            try "{\"type\":\"result\",\"total_cost_usd\":0.1}\n"
                .write(to: slot.chunkEventsURL(chunk: 1, in: root), atomically: true, encoding: .utf8)
            PrepRunArchive.archiveEventStreams(slot: slot, handoffDirectory: root,
                                               stamp: String(format: "202601%02d-120000", i + 1),
                                               now: Date())
        }

        let left = ((try? FileManager.default.contentsOfDirectory(
            atPath: slot.eventArchivesDirectory(in: root).path)) ?? [])
            .filter(PrepRunArchive.isArchivedRunFolder)
        #expect(left.count == slot.eventArchiveKeep,
                "archived \(past) runs of streams and kept \(left.count), not the streams' own keep")
    }

    // A copy that FAILED is not the same state as a run with no streams, and until this it produced the
    // same silence. The pair's own path reports a failure to both the archive log and the problem ledger
    // for exactly this reason: a broken archive that says nothing looks identical to a working one
    // (L10, L11). Losing the streams silently is the worse half, because they are the evidence this pass
    // exists to preserve and nothing else records that they were meant to be there.
    @Test func aFailedStreamCopyIsReportedRatherThanSwallowed() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let slot = RunSlot.check
        try "{}\n".write(to: slot.chunkEventsURL(chunk: 1, in: root), atomically: true, encoding: .utf8)

        // A FILE where the archive directory needs to be, so creating the working folder fails. A real
        // failure of the real call rather than a stubbed FileManager, so what is asserted is the
        // behaviour and not a double's (L52).
        try "not a directory".write(to: slot.eventArchivesDirectory(in: root),
                                    atomically: true, encoding: .utf8)

        var problems: [String] = []
        PrepRunArchive.archiveEventStreams(slot: slot, handoffDirectory: root,
                                           stamp: "20260901-120000", now: Date(),
                                           reportProblem: { problems.append($0) })

        #expect(problems.count == 1, "a lost stream archive said nothing at all")
        #expect(problems.first?.contains("searched for") == true,
                "the problem does not say what Dan lost: \(problems)")
        #expect(problems.first?.contains("(s)") == false,
                "singular and plural are separate sentences, never one with an (s) in it")
    }

    // And the ordinary case stays quiet, or the report above becomes noise on every run that has no
    // streams to archive and nobody reads it (L36).
    @Test func aRunWithNoStreamsReportsNoProblem() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        var problems: [String] = []
        PrepRunArchive.archiveEventStreams(slot: .check, handoffDirectory: root,
                                           stamp: "20260901-120000", now: Date(),
                                           reportProblem: { problems.append($0) })
        #expect(problems.isEmpty)
    }
}
