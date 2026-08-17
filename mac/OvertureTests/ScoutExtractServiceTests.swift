import Testing
import Foundation

// #799 slice 3b: the service that hands a batch of pinned pages to ONE detached Claude run and gets
// out of the way. It mirrors ReplyClassifyService deliberately, so there is one convention for these
// runs and not two.
//
// One batched run, not one per source. "N sources means N subprocesses" is a defect, not a detail: one
// hung source would block the marker guard, and an unbounded fan of subprocesses behind a bare spinner
// is exactly what CLAUDE.md's progress rule forbids (working, still-alive and failed must be visibly
// different states).
@MainActor
@Suite("Scout extract service (#799)")
struct ScoutExtractServiceTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scout-extract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func page(_ id: String) -> ScoutExtractQueueItem {
        ScoutExtractQueueItem(sourceId: id, orgName: id,
                              listingsURL: "https://\(id).example/events",
                              pagePath: "/tmp/overture-scout-page-\(id).html")
    }

    @Test func writesTheQueueAndLaunchesOnce() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let queueURL = dir.appendingPathComponent("queue.json")
        let markerURL = dir.appendingPathComponent("running")
        var launches = 0

        let count = try ScoutExtractService.startExtract(
            items: [page("bargemusic"), page("chelsea-symphony")],
            now: Date(), queueURL: queueURL, markerURL: markerURL,
            launch: { launches += 1 })

        #expect(count == 2)
        #expect(launches == 1)                                    // ONE run for the whole batch
        #expect(FileManager.default.fileExists(atPath: markerURL.path))

        let queue = try JSONDecoder().decode(ScoutExtractQueue.self,
                                             from: Data(contentsOf: queueURL))
        #expect(queue.items.map(\.sourceId) == ["bargemusic", "chelsea-symphony"])
        #expect(queue.version == ScoutExtractQueueBuilder.version)
    }

    // Nothing to do must not launch anything. A run with an empty work-list would take the marker,
    // burn a Claude invocation, and write an empty results file that the app would then ingest as
    // "every source returned nothing", which is indistinguishable from every source being broken.
    @Test func refusesToLaunchWithNothingToExtract() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var launches = 0

        #expect(throws: ScoutExtractService.ExtractLaunchError.nothingToExtract) {
            try ScoutExtractService.startExtract(
                items: [], now: Date(),
                queueURL: dir.appendingPathComponent("queue.json"),
                markerURL: dir.appendingPathComponent("running"),
                launch: { launches += 1 })
        }
        #expect(launches == 0)
    }

    // The marker is a LOCK, taken atomically, not a status flag. Two runs sharing one results file is
    // a lost-update: the second overwrites the first, and sources the first read are silently dropped.
    @Test func aSecondRunCannotStartWhileOneIsAlive() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let queueURL = dir.appendingPathComponent("queue.json")
        let markerURL = dir.appendingPathComponent("running")
        var launches = 0
        let now = Date()

        _ = try ScoutExtractService.startExtract(items: [page("a")], now: now,
                                                 queueURL: queueURL, markerURL: markerURL,
                                                 launch: { launches += 1 })

        #expect(throws: ScoutExtractService.ExtractLaunchError.alreadyRunning) {
            try ScoutExtractService.startExtract(items: [page("b")], now: now,
                                                 queueURL: queueURL, markerURL: markerURL,
                                                 launch: { launches += 1 })
        }
        #expect(launches == 1)     // the second never launched
    }

    // ...but a run that DIED must not lock the feature out forever. The script heartbeats the marker
    // while it works; a marker untouched past the timeout means the run is gone, and the next attempt
    // is allowed to take the lock. Without this, one crash would leave the watchlist permanently
    // wedged with no way for Dan to recover except deleting a file he does not know about.
    @Test func aDeadRunsStaleMarkerDoesNotWedgeTheFeatureForever() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let queueURL = dir.appendingPathComponent("queue.json")
        let markerURL = dir.appendingPathComponent("running")
        let start = Date()
        var launches = 0

        _ = try ScoutExtractService.startExtract(items: [page("a")], now: start,
                                                 queueURL: queueURL, markerURL: markerURL,
                                                 launch: { launches += 1 })

        // Well past the stale window, with nothing having touched the marker: the run is dead.
        let later = start.addingTimeInterval(RunTimeouts.scoutExtract + 60)
        #expect(!ScoutExtractService.isRunning(markerURL: markerURL, now: later))

        _ = try ScoutExtractService.startExtract(items: [page("b")], now: later,
                                                 queueURL: queueURL, markerURL: markerURL,
                                                 launch: { launches += 1 })
        #expect(launches == 2)
    }

    // If the launch itself fails, the lock must be RELEASED. Otherwise a misconfigured runner (the
    // very first thing Dan will hit, before he has pointed the app at the script) would take the
    // marker and then refuse every future attempt with "already running", forever, with no run alive.
    @Test func aFailedLaunchReleasesTheLockRatherThanWedgingIt() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let queueURL = dir.appendingPathComponent("queue.json")
        let markerURL = dir.appendingPathComponent("running")

        #expect(throws: ScoutExtractService.ExtractLaunchError.runnerUnavailable("no runner")) {
            try ScoutExtractService.startExtract(
                items: [page("a")], now: Date(), queueURL: queueURL, markerURL: markerURL,
                launch: { throw ScoutExtractService.ExtractLaunchError.runnerUnavailable("no runner") })
        }

        #expect(!FileManager.default.fileExists(atPath: markerURL.path))   // lock released
        // And the next attempt is free to proceed, rather than being told a phantom run is in flight.
        var launched = false
        _ = try ScoutExtractService.startExtract(items: [page("a")], now: Date(),
                                                 queueURL: queueURL, markerURL: markerURL,
                                                 launch: { launched = true })
        #expect(launched)
    }

    // "The runner isn't set up" must be a NAMED, actionable state. It is the first thing Dan will hit,
    // and the failure mode this replaces (DetachedRunner.scriptURL returns nil for an unset key) is a
    // feature that silently never runs.
    //
    // #2838: and it now says WHICH setting and WHAT it points at, because the interesting case stopped
    // being "never configured" and became "configured, and the checkout moved". Driven through the same
    // resolver the service uses, with every real resource injected, so this is the sentence Dan gets
    // rather than a second one written beside it (L107).
    @Test func anUnconfiguredRunnerSaysSoInWordsDanCanActerOn() {
        let resolution = DetachedRunner.resolveRunner(.scoutExtract,
                                                      configuredPath: "",
                                                      installedRepoPath: nil,
                                                      isRunnable: { _ in false })
        guard case .unavailable(let configuredPath, let derivedPath) = resolution else {
            Issue.record("an unconfigured runner must resolve to unavailable, got \(resolution)")
            return
        }
        let error = ScoutExtractService.ExtractLaunchError.runnerUnavailable(
            RunnerScripts.unavailableMessage(.scoutExtract, configuredPath: configuredPath,
                                             derivedPath: derivedPath))
        let text = try! #require(error.errorDescription)
        #expect(text.contains("scout-extract"))                  // names WHICH runner
        #expect(text.contains("scoutExtractRunnerScriptPath"))   // and WHICH setting
        #expect(text.contains("build-install.sh"))               // and what to do about it
    }

    // The other half, and the one the move actually produces: a setting that is still there and points at
    // a script that is not. Every stored runner path is absolute and lives outside the repo, so this is
    // what all six of them become the moment the checkout moves (#2838, L153).
    @Test func aStaleSettingFallsBackToTheCheckoutTheBuildCameFrom() {
        let moved = "/Users/dan/Apps/Overture"
        let derived = RunnerScripts.derivedPath(for: .scoutExtract, repoPath: moved)
        let resolution = DetachedRunner.resolveRunner(
            .scoutExtract,
            configuredPath: "/Users/dan/Photography Assets/Overture/mac/scripts/scout-extract-run.sh",
            installedRepoPath: moved,
            isRunnable: { $0 == derived })
        #expect(resolution == .derivedFromInstalledRepo(URL(fileURLWithPath: derived)))
    }
}
