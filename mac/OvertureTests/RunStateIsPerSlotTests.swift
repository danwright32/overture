import Testing
import Foundation

// #2760 (phase 3 of #2620): the state that is still SINGLE after #2763 gave every run FILE an owner.
//
// None of it shows up in a list of filenames, which is why phase 1 could look complete and leave a check
// started during a live prep unwatched, unsettled and paying for answers that land nowhere until the next
// launch. Every item here is one piece of that state, and each has its own reason for being per slot.
//
// The exclusion between a prep and a check is deliberately STILL IN FORCE after this change. Phase 3 makes
// concurrency safe to turn on; #2765 is what turns it on, because it owns the one genuine domain conflict
// (a draft written against a contact a check is midway through replacing).
@MainActor
@Suite("A run's state belongs to its slot (#2760)")
struct RunStateIsPerSlotTests {

    // MARK: - The keys

    // The whole defect in one sentence: two slots sharing one UserDefaults key describe the wrong file.
    // `prep.consumedResultsFingerprint` decides `anIngestIsStillToCome`, which chooses between filling a
    // blank and writing the `.noEmailFound` FLOOR over a real answer with a 90 day freshness stamp locking
    // the show out of a re-check (#1623).
    @Test("each slot fingerprints its own results file")
    func consumedResultsKeyIsPerSlot() {
        #expect(RunSlot.prep.resultsConsumedKey != RunSlot.check.resultsConsumedKey)
        // The prep slot keeps TODAY's key, so an upgrade does not re-ingest the last run on first launch.
        #expect(RunSlot.prep.resultsConsumedKey == "prep.consumedResultsFingerprint")
    }

    // `lastRunStartedAt` is half of `RunKind.of` and half of `DetachedRunOutcome.phase`. Shared, a check
    // launched after a prep moves the prep's own start stamp, and the prep's finished run is then judged
    // against a moment that belongs to the check.
    @Test("each slot remembers when its own run started")
    func lastRunStartedAtKeyIsPerSlot() {
        #expect(RunSlot.prep.lastRunStartedAtKey != RunSlot.check.lastRunStartedAtKey)
        #expect(RunSlot.prep.lastRunStartedAtKey == "prepLastRunStartedAt")
    }

    // One `prep-run-archives` with `keep = 30` means a busy night of checks evicts the prep archives
    // #1616's learner reads, and two runs launched in the same second collide on the folder name, at which
    // point the second archives nothing at all and says nothing (PrepRunArchive returns .alreadyArchived).
    @Test("each slot keeps its own archives, with its own keep count")
    func archivesArePerSlot() {
        let support = URL(fileURLWithPath: "/tmp/overture-test-support")
        #expect(RunSlot.prep.archivesDirectory(in: support) != RunSlot.check.archivesDirectory(in: support))
        #expect(RunSlot.prep.archivesDirectory(in: support).lastPathComponent == "prep-run-archives")
        // Not a shared constant: the two rotations prune their own folders, so one can be retuned without
        // silently changing how much of the other's history survives.
        #expect(RunSlot.prep.archiveKeep > 0)
        #expect(RunSlot.check.archiveKeep > 0)
    }

    // Derived rather than written out beside the list it checks (L96): the same reasoning `allPaths` was
    // built on. A key added to one slot and forgotten on the other is the shape this catches.
    @Test("no two slots share a stored key")
    func noSlotSharesAStoredKey() {
        var seen: [String: RunSlot] = [:]
        for slot in RunSlot.allCases {
            for (label, key) in slot.allDefaultsKeys() {
                #expect(seen[key] == nil, "\(slot.rawValue)'s \(label) key '\(key)' is also \(seen[key]?.rawValue ?? "")'s")
                seen[key] = slot
            }
        }
        #expect(seen.count == RunSlot.allCases.count * RunSlot.prep.allDefaultsKeys().count)
    }

    // MARK: - The announce singleton

    // THE GUARD THE ISSUE NAMES. `DetachedRunActivity` was a `static let` singleton wired as the default
    // `announce:` of BOTH launches, and `runStarted()` opens with `guard !isRunning else { return }`. Start
    // a check while a prep is live and no listener is woken, `watchPrepRuns` never gets a second iteration,
    // and the check is never followed and never settled: its paid answers land only at the next launch, via
    // `settleOrphanedProbe`. This is L53, two independent checks sharing one status field.
    @Test(.timeLimit(.minutes(1)))
    func aCheckStartedWhileAPrepIsLiveIsStillFollowed() async {
        let prep = DetachedRunActivity(liveness: { _ in true }, sleep: { _ in })
        let check = DetachedRunActivity(liveness: { _ in false }, sleep: { _ in })

        // The prep is already in flight and its watcher has been told.
        #expect(prep.isRunning)
        let checkStarts = check.runStarts()
        let watcher = Task { @MainActor in
            for await _ in checkStarts { return true }
            return false
        }

        check.runStarted()

        #expect(await watcher.value, "a check launched during a live prep must wake its own watcher")
        #expect(check.isRunning)
    }

    // And the two instances the app actually uses are genuinely two, not one read twice. Without this the
    // test above passes on a pair a test built itself while the app keeps its singleton (L3: built is not
    // wired).
    @Test("the app holds one activity per slot")
    func theAppHoldsOneActivityPerSlot() {
        #expect(DetachedRunActivity.forSlot(.prep) === DetachedRunActivity.prep)
        #expect(DetachedRunActivity.forSlot(.check) === DetachedRunActivity.check)
        #expect(DetachedRunActivity.prep !== DetachedRunActivity.check)
    }

    // Built is not wired (L3). The activity per slot is worth nothing unless something is LISTENING to
    // each, and the watchers are spelled out one per slot, so a slot added later is silently unwatched:
    // its runs are never followed and never settled, which is the whole defect this issue is about.
    // Derived from `allCases` rather than a list of the slots somebody remembered (L96).
    @Test("every slot has a watcher in the window body")
    func everySlotHasAWatcher() {
        let root = SourceGuardHelper.source("Overture/App/RootView.swift")
        #expect(!root.isEmpty)
        for slot in RunSlot.allCases {
            #expect(root.contains("watchRuns(slot: .\(slot.rawValue))"),
                    "nothing follows a run in the \(slot.rawValue) slot, so it is never settled")
        }
    }

    // MARK: - The run log

    // A check that finishes empty must quote its OWN log. Sharing `prep-run.log` shows Dan the tail of
    // whatever ran last, which is the reason the tail is there at all (#885).
    @Test("each slot quotes its own run log")
    func runLogIsPerSlot() {
        #expect(RunLog.url(for: .prep) != RunLog.url(for: .check))
        #expect(RunLog.url(for: .prep).lastPathComponent == "prep-run.log")
        #expect(RunLog.url(for: .check).lastPathComponent == "check-run.log")
    }

    // MARK: - The legacy settle rule

    // `RunKind.of` survives ONLY as the prep slot's settle rule, and that is what makes the upgrade safe:
    // a check launched by the old app is in flight in the PREP slot with its marker beside it, and settles
    // exactly as it does today. The check slot needs no such inference, because only checks are ever in it.
    @Test("a legacy check in the prep slot still settles as a check, and says so")
    func aLegacyCheckInThePrepSlotIsStillRecognised() {
        var said: [String] = []
        let started = Date()
        let kind = PrepQueueService.prepSlotRunKind(
            runStartedAt: started,
            probeMarkerStartedAt: ISO8601DateFormatter().string(from: started),
            log: { said.append($0) })

        #expect(kind == .reachabilityCheck)
        // #2760 logs the branch when it is GENUINELY taken, so the issue that deletes it can be closed on
        // evidence rather than on a guess about who has updated (L65).
        #expect(said.count == 1)
        #expect(said.first?.contains("prep slot") == true)
    }

    @Test("an ordinary prep in the prep slot says nothing")
    func anOrdinaryPrepSaysNothing() {
        var said: [String] = []
        let kind = PrepQueueService.prepSlotRunKind(runStartedAt: Date(), probeMarkerStartedAt: nil,
                                                    log: { said.append($0) })
        #expect(kind == .prep)
        #expect(said.isEmpty, "a log line on every ordinary prep is a log nobody reads")
    }
}
