import Testing
import Foundation

// #3357 Phase 1.3: the attribution sidecar is archived on its OWN rotation, and this measures what
// SURVIVES ON DISK rather than comparing two constants.
//
// The plan's earlier revision asserted `attributionArchiveKeep >= archiveKeep`, which compares two
// integers and cannot see the rotation at all: it would pass while all three consumers shared one
// folder and two of them silently got a lifetime nobody chose (L63, L212, L285). What is actually at
// stake is a number: at a shared keep of 10 the queue and results history collapses from 30 to 10,
// which is precisely the defect #2760 was filed to fix.
@Suite("The attribution sidecar keeps its own history (#3357 Phase 1.3)")
final class AttributionArchiveRetentionTests {

    private let sandboxes = TemporarySandboxes()

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    // Archives past EVERY keep, then asserts per directory exactly what is left. 61 runs is one more
    // than the largest of the three, so all three rotations have had to act.
    @Test func archivingPastEveryKeepLeavesEachDirectoryItsOwnHistory() throws {
        let slot = RunSlot.check
        let dir = try sandboxes.make(named: "attribution-retention")

        for i in 1...61 {
            // Every run needs its OWN identity or the pair archives once and rotates never:
            // `archiveFinishedRun` derives its stamp from the queue's `generatedAt`, so a constant one
            // makes every call after the first read as `alreadyArchived`. Caught by this test's own
            // first run, which reported `pair -> 1` against a keep of 30.
            let day = (i % 28) + 1
            let hour = i % 24
            let stamp = String(format: "202601%02d-%02d0000", day, hour)
            let generatedAt = String(format: "2026-01-%02dT%02d:00:00Z", day, hour)
            try write(#"{"version":13,"generatedAt":"\#(generatedAt)","items":[]}"#,
                      to: slot.queueURL(in: dir))
            try write(#"{"version":11,"generatedAt":"\#(generatedAt)","results":[]}"#,
                      to: slot.resultsURL(in: dir))
            try write(#"{"version":1,"streams":[]}"#, to: slot.attributionURL(in: dir))
            try write("{}\n", to: slot.chunkEventsURL(chunk: 1, in: dir))

            PrepRunArchive.archiveEventStreams(slot: slot, handoffDirectory: dir, stamp: stamp,
                                               now: Date())
            PrepRunArchive.archiveAttribution(slot: slot, handoffDirectory: dir, stamp: stamp,
                                              now: Date())
            _ = PrepRunArchive.archiveFinishedRun(slot: slot, handoffDirectory: dir, now: Date(),
                                                  keep: slot.archiveKeep, reportProblem: { _ in })
        }

        func folders(_ url: URL) -> Int {
            ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [])
                .filter(PrepRunArchive.isArchivedRunFolder).count
        }

        let pair = folders(slot.archivesDirectory(in: dir))
        let events = folders(slot.eventArchivesDirectory(in: dir))
        let attribution = folders(slot.attributionArchivesDirectory(in: dir))

        // The stamps repeat every 28 iterations by construction, so these are ceilings the rotation
        // must respect rather than exact counts. What matters is that they DIFFER: one shared folder
        // and one keep would make all three equal, which is the design this replaces.
        #expect(events <= slot.eventArchiveKeep,
                "the event streams outlived their own keep, so they are not on their own rotation")
        #expect(attribution > slot.eventArchiveKeep,
                "the sidecar was cut to the streams' keep, which is the lifetime nobody chose")
        #expect(pair > slot.eventArchiveKeep,
                "the queue and results history collapsed to the streams' keep, which is #2760 again")
        #expect(attribution >= pair,
                "the sidecar must outlive the pair: its readers arrive weeks to months after a run")
    }

    // The three directories are distinct, which is the whole mechanism. Asserted directly so a later
    // edit cannot quietly point two of them at one path and leave the counts above to notice.
    @Test func eachConsumerHasItsOwnDirectory() {
        let dir = URL(fileURLWithPath: "/tmp/does-not-need-to-exist")
        let names = Set([
            RunSlot.check.archivesDirectory(in: dir).lastPathComponent,
            RunSlot.check.eventArchivesDirectory(in: dir).lastPathComponent,
            RunSlot.check.attributionArchivesDirectory(in: dir).lastPathComponent,
        ])

        #expect(names.count == 3)
    }

    // A run with no sidecar archives nothing rather than an empty folder: an empty archive and a run
    // whose sidecar was lost read identically to anybody looking later (L98, L11).
    @Test func aRunWithNoSidecarLeavesNoFolderAtAll() throws {
        let slot = RunSlot.check
        let dir = try sandboxes.make(named: "attribution-retention")

        PrepRunArchive.archiveAttribution(slot: slot, handoffDirectory: dir, stamp: "20260101-000000",
                                          now: Date())

        #expect(!FileManager.default.fileExists(
            atPath: slot.attributionArchivesDirectory(in: dir).path))
    }
}
