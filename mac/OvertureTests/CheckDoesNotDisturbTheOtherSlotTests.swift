import Testing
import Foundation
import SwiftData

// #2760 (phase 3 of #2620): the state a check and a prep still shared after every FILE was given an owner.
//
// The exclusion between the two is STILL IN FORCE after this change, deliberately: this phase makes
// concurrency safe, #2765 is what turns it on. So every case here is constructed directly rather than by
// running the two at once, which the app still refuses to do.
@MainActor
@Suite("A check settles without touching the prep slot (#2760)")
struct CheckDoesNotDisturbTheOtherSlotTests {

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "PerSlot-\(UUID().uuidString)")!
    }

    private func tmpDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("overture-slot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func drafted(_ ctx: ModelContext, key: String) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: key, discipline: "theatre", venue: "Under St Marks",
                         performanceDate: "2099-08-14", sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .drafted)
        p.draftBody = "Hi"
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    private func writeQueue(_ keys: [String], to url: URL) throws {
        let items = keys.map { PrepQueueItem(naturalKey: $0, groupName: $0, venue: "Under St Marks",
                                             performanceDate: "2099-08-14", discipline: "theatre", sourceListingURL: nil,
                                             possibleMatchName: nil, priorRelationship: "none",
                                             production: "self") }
        let queue = PrepQueueBuilder.build(from: items, generatedAt: "2099-01-01T00:00:00Z", houses: [])
        try PrepQueueBuilder.encode(queue).write(to: url)
    }

    // MARK: - The re-prep release

    // THE SECOND GUARD THE ISSUE NAMES. `ReprepRelease.releaseAfterRun` fetched the WHOLE store, and its
    // header said why that was fine: "what a finished run has in front of it". True while one run could
    // exist. A check finishing empty would release the re-prep requests the LIVE prep is carrying, sending
    // a show back to Review while it is being drafted.
    @Test func aCheckFinishingEmptyLeavesTheOtherRunsRepairsAlone() throws {
        let ctx = try context()
        let beingDrafted = drafted(ctx, key: "prep-is-drafting-this")
        beingDrafted.reprepDraftRequested = true
        beingDrafted.reprepHandedToRun = true
        let onTheCheck = drafted(ctx, key: "the-check-has-this")
        onTheCheck.reprepDraftRequested = true
        onTheCheck.reprepHandedToRun = true
        try ctx.save()

        // The ending run's own work-list names only its own show.
        let released = ReprepRelease.releaseAfterRun(in: ctx, carrying: ["the-check-has-this"])

        #expect(released == ["the-check-has-this"])
        #expect(beingDrafted.reprepHandedToRun, "the other run's request must survive its neighbour ending")
        #expect(beingDrafted.isReprepQueued)
        #expect(!onTheCheck.reprepHandedToRun)
    }

    // The keys come from the ending run's OWN queue file, which is the app's record of what it handed that
    // run. Read here rather than assembled at the call site, so the two ends cannot disagree.
    @Test func theCarriedKeysComeFromTheRunsOwnQueueFile() throws {
        let dir = try tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let queueURL = RunSlot.check.queueURL(in: dir)
        try writeQueue(["a", "b"], to: queueURL)

        #expect(PrepQueue.keys(inQueueAt: queueURL) == ["a", "b"])
    }

    // A queue file that cannot be read releases NOTHING, which is the fail-safe direction: a request left
    // standing keeps the show under Prep until the next run serves it, where a blanket release would pull a
    // show back into Review in the middle of being drafted (L5, and the exact damage this scoping prevents).
    @Test func anUnreadableQueueReleasesNothing() throws {
        let dir = try tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(PrepQueue.keys(inQueueAt: dir.appendingPathComponent("nothing-here.json")).isEmpty)
    }

    // MARK: - The consumed-results fingerprint

    // One UserDefaults key decides `anIngestIsStillToCome`, which chooses between filling blanks and writing
    // the `.noEmailFound` floor OVER a real answer with a 90 day freshness stamp locking the show out of a
    // re-check (#1623). Two slots ping-ponging one key makes it describe the wrong file.
    @Test func consumingOneSlotsResultsSaysNothingAboutTheOthers() throws {
        let ctx = try context()
        let dir = try tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let d = defaults()
        let prepResults = RunSlot.prep.resultsURL(in: dir)
        let checkResults = RunSlot.check.resultsURL(in: dir)
        let bytes = try JSONEncoder().encode(PrepResults(version: 2, generatedAt: "2099-01-01T00:00:00Z",
                                                          results: []))
        // Byte-identical on purpose: the fingerprint is over the CONTENT, so two runs that happen to write
        // the same thing are exactly the case a shared key cannot tell apart.
        try bytes.write(to: prepResults)
        try bytes.write(to: checkResults)

        #expect(PrepImporter.hasUnconsumedResults(slot: .prep, at: prepResults, defaults: d))
        #expect(PrepImporter.hasUnconsumedResults(slot: .check, at: checkResults, defaults: d))

        _ = PrepImporter.consumeIfNew(slot: .check, at: checkResults, into: ctx, defaults: d,
                                      ingest: { _, _ in PrepImporter.Outcome() })

        #expect(!PrepImporter.hasUnconsumedResults(slot: .check, at: checkResults, defaults: d))
        #expect(PrepImporter.hasUnconsumedResults(slot: .prep, at: prepResults, defaults: d),
                "a check consuming its own results must not tell the prep slot its file has been read")
    }

    // MARK: - The exclusion, which this phase does NOT lift

    // Phase 3 makes the state per slot; #2765 owns the one genuine domain conflict and is what lets the two
    // run at once. Until it lands, a check and a prep still exclude each other, and this is what says so.
    // #3015 REVERSED both of these, deliberately, and they are kept rather than deleted because the
    // behaviour they pin is still the point of this suite: a run must not disturb the OTHER slot. What
    // changed is that not disturbing it no longer means refusing to start (#2620). The exclusion each of
    // these asserted was the thing #2620 existed to remove, and everything that made removing it safe is
    // in: #2980, #3009, #3010, #3011, #3012, #2765, #3014, #3016.
    @Test func aPrepNowStartsWhileACheckIsRunning() async throws {
        let ctx = try context()
        let dir = try tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Genuinely prep-eligible: kept AND with no draft yet. `PrepQueue.needsPrep` requires both, and
        // the `drafted` helper writes a draftBody, so clearing the status alone leaves nothing for the
        // run to do and the launch answers `nothingToPrep` before it ever reaches the exclusion.
        let kept = drafted(ctx, key: "kept")
        kept.status = .queued
        kept.draftBody = nil
        try ctx.save()
        // The check slot holds a live run, and publishes that it is on a DIFFERENT show, so nothing the
        // prep wants is held.
        try Data().write(to: RunSlot.check.markerURL(in: dir))
        try RunCoverage.write(keys: ["some other show"], slot: .check, in: dir)

        var launched = false
        let count = try await PrepQueueService.startPrep(from: ctx, now: Date(), support: dir,
                                                         render: { _ in "" }, launch: { launched = true })
        #expect(launched)
        #expect(count == 1)
    }

    @Test func aCheckNowStartsWhileAPrepIsRunning() async throws {
        let ctx = try context()
        let dir = try tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = drafted(ctx, key: "untriaged")
        p.status = .new
        try ctx.save()
        try Data().write(to: RunSlot.prep.markerURL(in: dir))
        try RunCoverage.write(keys: ["some other show"], slot: .prep, in: dir)

        var launched = false
        let count = try await PrepQueueService.startReachabilityProbe(keys: [p.naturalKey], from: ctx,
                                                                      now: Date(), support: dir,
                                                                      render: { _ in "" },
                                                                      launch: { launched = true })
        #expect(launched)
        #expect(count == 1)
    }

    // THE POSITIVE CONTROL for both, and it is what stops the two above reading as "the guard was simply
    // deleted": a second run in the SAME slot is still refused, which is what that slot's lock has always
    // meant and still means.
    @Test func aSecondRunInTheSameSlotIsStillRefused() async throws {
        let ctx = try context()
        let dir = try tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let kept = drafted(ctx, key: "kept")
        kept.status = .queued
        kept.draftBody = nil
        try ctx.save()
        try Data().write(to: RunSlot.prep.markerURL(in: dir))

        await #expect(throws: PrepQueueService.PrepLaunchError.alreadyRunning) {
            _ = try await PrepQueueService.startPrep(from: ctx, now: Date(), support: dir,
                                                     render: { _ in "" }, launch: {})
        }
    }

    // The upgrade window is the case with no wording of its own today. A check launched by the OLD app is
    // in flight in the PREP slot, so a new check would find the check slot empty and start a second one.
    // It is refused, and with a sentence that names a check rather than `alreadyRunning`, which names a
    // Prep run and would send Dan looking for a run that is not there.
    @Test func aSecondCheckIsRefusedWhileALegacyCheckHoldsThePrepSlot() async throws {
        let ctx = try context()
        let dir = try tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = drafted(ctx, key: "untriaged")
        p.status = .new
        try ctx.save()
        let now = Date()
        let d = defaults()
        d.set(now, forKey: RunSlot.prep.lastRunStartedAtKey)
        try Data().write(to: RunSlot.prep.markerURL(in: dir))
        // A legacy check: the prep slot is live and its probe marker belongs to that live run.
        try ReachabilityProbeMarker.write(
            ReachabilityProbeMarker(keys: ["untriaged"],
                                    startedAt: ISO8601DateFormatter().string(from: now), lookups: 1),
            to: PrepQueueService.probeRunURL(in: dir))

        await #expect(throws: PrepQueueService.PrepLaunchError.checkAlreadyRunning) {
            _ = try await PrepQueueService.startReachabilityProbe(keys: [p.naturalKey], from: ctx,
                                                                  now: now, support: dir, defaults: d,
                                                                  render: { _ in "" }, launch: {})
        }
    }

    // Its own sentence, and one that does not name a Prep run.
    @Test func theCheckRefusalNamesACheck() {
        let sentence = PrepQueueService.PrepLaunchError.checkAlreadyRunning.errorDescription ?? ""
        #expect(sentence.lowercased().contains("check"))
        #expect(!sentence.lowercased().contains("prep run"))
    }

    // MARK: - A check that starts really does take its own slot

    // The launch is what makes every item above reachable: a check that still wrote the prep slot's files
    // would leave all of this correct and unused (L3, built is not wired).
    @Test func aCheckWritesTheCheckSlotsFilesAndNotThePreps() async throws {
        let ctx = try context()
        let dir = try tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = drafted(ctx, key: "untriaged")
        p.status = .new
        try ctx.save()

        _ = try await PrepQueueService.startReachabilityProbe(keys: [p.naturalKey], from: ctx, now: Date(),
                                                              support: dir, render: { _ in "" }, launch: {})

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: RunSlot.check.queueURL(in: dir).path))
        #expect(fm.fileExists(atPath: RunSlot.check.markerURL(in: dir).path))
        #expect(!fm.fileExists(atPath: RunSlot.prep.queueURL(in: dir).path),
                "a check must not write the prep slot's work-list")
        #expect(!fm.fileExists(atPath: RunSlot.prep.markerURL(in: dir).path),
                "a check must not take the prep slot's lock")
    }

    // And it stamps its OWN start, so the prep slot's `lastRunStartedAt` (half of both `RunKind.of` and
    // `DetachedRunOutcome.phase`) is not moved by a run that has nothing to do with it.
    @Test func aCheckStampsItsOwnStartAndNotThePreps() async throws {
        let ctx = try context()
        let dir = try tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = drafted(ctx, key: "untriaged")
        p.status = .new
        try ctx.save()
        let d = defaults()
        let prepStart = Date(timeIntervalSince1970: 1_800_000_000)
        d.set(prepStart, forKey: RunSlot.prep.lastRunStartedAtKey)
        let checkStart = Date(timeIntervalSince1970: 1_800_009_999)

        _ = try await PrepQueueService.startReachabilityProbe(keys: [p.naturalKey], from: ctx,
                                                              now: checkStart, support: dir, defaults: d,
                                                              render: { _ in "" }, launch: {})

        #expect(PrepQueueService.lastRunStartedAt(slot: .prep, defaults: d) == prepStart)
        #expect(PrepQueueService.lastRunStartedAt(slot: .check, defaults: d) == checkStart)
    }
}
