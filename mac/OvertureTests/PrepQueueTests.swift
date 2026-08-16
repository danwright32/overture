import Testing
import Foundation
import SwiftData

@MainActor
@Suite("Prep queue build")
struct PrepQueueTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    @discardableResult
    private func insert(_ ctx: ModelContext, group: String, status: ReviewStatus, hasDraft: Bool = false,
                        reprepDraftRequested: Bool = false, reprepContactsRequested: Bool = false,
                        sentAt: Date? = nil, performanceDate: String = "2026-07-01") -> Prospect {
        let key = Prospect.makeNaturalKey(groupName: group, performanceDate: performanceDate, venue: "Weill Recital Hall")
        let p = Prospect(naturalKey: key, groupName: group, discipline: "choral", venue: "Weill Recital Hall",
                         performanceDate: performanceDate, sourceListingURL: "https://src", websiteURL: "https://site",
                         priorRelationship: "none", production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 7, tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: status)
        if hasDraft { p.draftSubject = "s"; p.draftBody = "b" }
        p.reprepDraftRequested = reprepDraftRequested
        p.reprepContactsRequested = reprepContactsRequested
        p.sentAt = sentAt
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    // #901: a kept show on a day Dan cannot work is not prep work, whatever else is true of it. It stays
    // in the queue, flagged (he decides, not the app), but no contacts are researched and no email is
    // drafted for a night he is already booked or away for.
    @Test func anUnclearedDateConflictIsNeverPrepWork() {
        #expect(PrepQueueBuilder.needsPrep(status: .queued, hasDraft: false,
                                           hasUnclearedConflict: true) == false)
        // Even an explicit re-prep request loses to it: Dan asking for a redraft is not the same as Dan
        // saying he can shoot that night, and only the second one unblocks the show.
        #expect(PrepQueueBuilder.needsPrep(status: .approved, hasDraft: true, reprepDraftRequested: true,
                                           hasUnclearedConflict: true) == false)
        #expect(PrepQueueBuilder.needsPrep(status: .approved, hasDraft: true, reprepDraftRequested: true,
                                           hasUnclearedConflict: false) == true)
    }

    @Test func needsPrepOnlyForKeptUndrafted() {
        #expect(PrepQueueBuilder.needsPrep(status: .queued, hasDraft: false, hasUnclearedConflict: false) == true)
        #expect(PrepQueueBuilder.needsPrep(status: .queued, hasDraft: true, hasUnclearedConflict: false) == false)  // already drafted
        #expect(PrepQueueBuilder.needsPrep(status: .new, hasDraft: false, hasUnclearedConflict: false) == false)    // not kept
        #expect(PrepQueueBuilder.needsPrep(status: .dismissed, hasDraft: false, hasUnclearedConflict: false) == false)
        #expect(PrepQueueBuilder.needsPrep(status: .approved, hasDraft: true, hasUnclearedConflict: false) == false)
    }

    // #367: a drafted/approved prospect flagged for re-prep re-enters the queue even though it
    // already has a draft, but only for the eligible statuses; contacted/dismissed never qualify
    // no matter what the flags say.
    @Test func needsPrepAlsoTrueForReprepFlaggedEligibleStatuses() {
        #expect(PrepQueueBuilder.needsPrep(status: .drafted, hasDraft: true,
                                           reprepDraftRequested: true, reprepContactsRequested: false, hasUnclearedConflict: false) == true)
        #expect(PrepQueueBuilder.needsPrep(status: .drafted, hasDraft: true,
                                           reprepDraftRequested: false, reprepContactsRequested: true, hasUnclearedConflict: false) == true)
        #expect(PrepQueueBuilder.needsPrep(status: .approved, hasDraft: true,
                                           reprepDraftRequested: true, reprepContactsRequested: true, hasUnclearedConflict: false) == true)
        #expect(PrepQueueBuilder.needsPrep(status: .queued, hasDraft: true,
                                           reprepDraftRequested: true, reprepContactsRequested: false, hasUnclearedConflict: false) == true)
    }

    @Test func needsPrepFalseWhenReprepFlagsSetButNoFlagsActuallyTrue() {
        #expect(PrepQueueBuilder.needsPrep(status: .drafted, hasDraft: true,
                                           reprepDraftRequested: false, reprepContactsRequested: false, hasUnclearedConflict: false) == false)
    }

    @Test func needsPrepNeverTrueForContactedOrDismissedEvenWithReprepFlags() {
        #expect(PrepQueueBuilder.needsPrep(status: .contacted, hasDraft: true,
                                           reprepDraftRequested: true, reprepContactsRequested: true, hasUnclearedConflict: false) == false)
        #expect(PrepQueueBuilder.needsPrep(status: .dismissed, hasDraft: true,
                                           reprepDraftRequested: true, reprepContactsRequested: true, hasUnclearedConflict: false) == false)
    }

    @Test func gathersOnlyKeptUndraftedProspectsWithExactKey() throws {
        let ctx = ModelContext(try container())
        insert(ctx, group: "Kept Choir", status: .queued)
        insert(ctx, group: "Already Drafted", status: .queued, hasDraft: true)
        insert(ctx, group: "Not Kept", status: .new)
        insert(ctx, group: "Dismissed Group", status: .dismissed)

        let queue = PrepQueueService.buildQueue(from: ctx, generatedAt: "now")
        #expect(queue.items.count == 1)
        let item = queue.items[0]
        #expect(item.groupName == "Kept Choir")
        // The key must be the prospect's exact stored key (opaque token).
        let expectedKey = Prospect.makeNaturalKey(groupName: "Kept Choir", performanceDate: "2026-07-01", venue: "Weill Recital Hall")
        #expect(item.naturalKey == expectedKey)
        #expect(item.websiteURL == "https://site")
        // #366 Phase 1: the AI research step needs to know if a show is self-produced.
        #expect(item.production == "self")
    }

    // #367: a normal, never-drafted prospect carries no reprepMode (do both, as always).
    @Test func normalQueuedUndraftedItemCarriesNoReprepMode() throws {
        let ctx = ModelContext(try container())
        insert(ctx, group: "Fresh Choir", status: .queued)

        let queue = PrepQueueService.buildQueue(from: ctx, generatedAt: "now")
        #expect(queue.items.count == 1)
        #expect(queue.items[0].reprepMode == nil)
    }

    @Test func reprepDraftOnlyProducesDraftOnlyMode() throws {
        let ctx = ModelContext(try container())
        insert(ctx, group: "Redraft Me", status: .drafted, hasDraft: true, reprepDraftRequested: true)

        let queue = PrepQueueService.buildQueue(from: ctx, generatedAt: "now")
        #expect(queue.items.count == 1)
        #expect(queue.items[0].reprepMode == "draft_only")
    }

    @Test func reprepContactsOnlyProducesContactsOnlyMode() throws {
        let ctx = ModelContext(try container())
        insert(ctx, group: "Find Contacts", status: .approved, hasDraft: true, reprepContactsRequested: true)

        let queue = PrepQueueService.buildQueue(from: ctx, generatedAt: "now")
        #expect(queue.items.count == 1)
        #expect(queue.items[0].reprepMode == "contacts_only")
    }

    @Test func reprepBothFlagsProducesNoReprepMode() throws {
        let ctx = ModelContext(try container())
        insert(ctx, group: "Both Please", status: .drafted, hasDraft: true,
              reprepDraftRequested: true, reprepContactsRequested: true)

        let queue = PrepQueueService.buildQueue(from: ctx, generatedAt: "now")
        #expect(queue.items.count == 1)
        #expect(queue.items[0].reprepMode == nil)
    }

    @Test func startPrepWritesWorkListThenReportsRunnerUnavailable() async throws {
        let ctx = ModelContext(try container())
        insert(ctx, group: "Kept Choir", status: .queued)

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("prep-queue-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("m-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }

        // Launch throws (runner unavailable) — but the work-list must already be written.
        await #expect(throws: PrepQueueService.PrepLaunchError.runnerUnavailable) {
            try await PrepQueueService.startPrep(from: ctx, now: Date(timeIntervalSince1970: 0),
                                                 queueURL: tmp, markerURL: marker,
                                                 launch: { throw PrepQueueService.PrepLaunchError.runnerUnavailable })
        }
        let written = try Data(contentsOf: tmp)
        let decoded = try JSONDecoder().decode(PrepQueue.self, from: written)
        #expect(decoded.items.count == 1)
        #expect(decoded.items[0].groupName == "Kept Choir")
    }

    @Test func startPrepThrowsWhenNothingToPrep() async throws {
        let ctx = ModelContext(try container())
        insert(ctx, group: "Not Kept", status: .new)
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("m-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        await #expect(throws: PrepQueueService.PrepLaunchError.nothingToPrep) {
            try await PrepQueueService.startPrep(from: ctx, now: Date(), markerURL: marker, launch: {})
        }
    }

    // #1322: a probe and a normal Prep used to share the single run lock, so isRunning alone could not
    // tell them apart, and the probe-run marker's presence during a live run identified the in-flight run
    // as a probe. #2760 gives the check its own slot, so a live CHECK slot says so outright; what remains
    // of the old rule is the upgrade window, in which a check launched by an older build is still in the
    // PREP slot with its marker beside it. Both are exercised here.
    @Test func isProbeRunningIsTrueForALiveCheckAndForALegacyCheckInThePrepSlot() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("probe-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let d = UserDefaults(suiteName: "IsProbeRunning-\(UUID().uuidString)")!

        // No run at all.
        #expect(PrepQueueService.isProbeRunning(now: Date(), support: dir, defaults: d) == false)

        // A live PREP with no probe marker: a normal Prep, not a check.
        try Data().write(to: RunSlot.prep.markerURL(in: dir))
        #expect(PrepQueueService.isProbeRunning(now: Date(), support: dir, defaults: d) == false)

        // The upgrade window: a live prep slot WITH the probe marker is a legacy check.
        try ReachabilityProbeMarker.write(ReachabilityProbeMarker(keys: ["a", "b"], startedAt: "x"),
                                          to: PrepQueueService.probeRunURL(in: dir))
        #expect(PrepQueueService.isProbeRunning(now: Date(), support: dir, defaults: d) == true)

        // Marker present but the run lock has gone stale (crashed): no longer a live check.
        let stale = Date().addingTimeInterval(PrepQueueService.markerStaleAfter + 60)
        #expect(PrepQueueService.isProbeRunning(now: stale, support: dir, defaults: d) == false)

        // And the ordinary case after #2760: the CHECK slot is live, and no marker comparison is needed
        // to know what is in it.
        try FileManager.default.removeItem(at: RunSlot.prep.markerURL(in: dir))
        ReachabilityProbeMarker.clear(at: PrepQueueService.probeRunURL(in: dir))
        try Data().write(to: RunSlot.check.markerURL(in: dir))
        #expect(PrepQueueService.isProbeRunning(now: Date(), support: dir, defaults: d) == true)
    }

    @Test func isRunningReflectsAFreshMarkerButIgnoresAStaleOne() throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("prep-running-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }

        #expect(PrepQueueService.isRunning(slot: .prep, markerURL: marker, now: Date()) == false)  // absent

        try Data().write(to: marker)
        let written = (try marker.resourceValues(forKeys: [.contentModificationDateKey])).contentModificationDate!
        // The runner heartbeats the marker (#47), so "fresh" means touched within the
        // staleness window; only a marker untouched past the window reads as crashed.
        let window = PrepQueueService.markerStaleAfter
        #expect(PrepQueueService.isRunning(slot: .prep, markerURL: marker, now: written.addingTimeInterval(window - 1)) == true)
        #expect(PrepQueueService.isRunning(slot: .prep, markerURL: marker, now: written.addingTimeInterval(window + 1)) == false)
    }

    @Test func startPrepRefusesWhileARunIsInFlight() async throws {
        let ctx = ModelContext(try container())
        insert(ctx, group: "Kept Choir", status: .queued)
        let tmpQueue = FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID().uuidString).json")
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("m-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpQueue); try? FileManager.default.removeItem(at: marker) }

        try Data().write(to: marker) // a run is already in flight
        await #expect(throws: PrepQueueService.PrepLaunchError.alreadyRunning) {
            try await PrepQueueService.startPrep(from: ctx, now: Date(), queueURL: tmpQueue, markerURL: marker)
        }
    }

    // #480: the marker must be claimed atomically before launch, not written after, or two rapid
    // presses can both pass the isRunning guard and both launch. The nested call inside `launch`
    // simulates a second press landing while the first is still mid-flight, exactly the check-then-act
    // window a plain post-launch marker write leaves open.
    @Test func concurrentStartPrepCallsYieldExactlyOneLaunch() async throws {
        let ctx = ModelContext(try container())
        insert(ctx, group: "Kept Choir", status: .queued)
        let queueURL = FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID().uuidString).json")
        let markerURL = FileManager.default.temporaryDirectory.appendingPathComponent("m-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: queueURL); try? FileManager.default.removeItem(at: markerURL) }

        var launches = 0
        _ = try await PrepQueueService.startPrep(
            from: ctx, now: Date(), queueURL: queueURL, markerURL: markerURL,
            launch: {
                launches += 1
                await #expect(throws: PrepQueueService.PrepLaunchError.alreadyRunning) {
                    try await PrepQueueService.startPrep(from: ctx, now: Date(), queueURL: queueURL,
                                                         markerURL: markerURL,
                                                         launch: { launches += 1 })
                }
            })

        #expect(launches == 1)
    }

    // #480: mirrors ReplyClassifyService. If launch fails, the atomic lock must be released so a
    // retry is not permanently blocked.
    @Test func aFailedLaunchReleasesTheLock() async throws {
        struct LaunchFailed: Error {}
        let ctx = ModelContext(try container())
        insert(ctx, group: "Kept Choir", status: .queued)
        let queueURL = FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID().uuidString).json")
        let markerURL = FileManager.default.temporaryDirectory.appendingPathComponent("m-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: queueURL); try? FileManager.default.removeItem(at: markerURL) }

        await #expect(throws: LaunchFailed.self) {
            try await PrepQueueService.startPrep(from: ctx, now: Date(), queueURL: queueURL, markerURL: markerURL,
                                                 launch: { throw LaunchFailed() })
        }
        #expect(FileManager.default.fileExists(atPath: markerURL.path) == false)   // lock released
    }

    // MARK: - #953: per-run subset selection, defaulted by how far out the show is

    // #2365: the sheet opens with EVERY eligible show checked, whatever its date. Dan's rule is that
    // Scout alone decides how far out is too far, so a show reaching this list is one he kept and the run
    // does not second-guess him.
    @Test func everyEligibleShowDefaultsIn() throws {
        let ctx = ModelContext(try container())
        let near = insert(ctx, group: "Near Show", status: .queued, performanceDate: "2026-10-01")
        let far = insert(ctx, group: "Far Show", status: .queued, performanceDate: "2027-06-13")

        let selected = PrepQueueBuilder.prepDefaultSelection(prospects: [near, far])

        #expect(selected == Set([near.naturalKey, far.naturalKey]))
    }

    // The subset threads all the way through: only the chosen keys reach the built work-list, even
    // though both prospects are eligible.
    @Test func buildQueueIncludesOnlyTheSelectedKeys() throws {
        let ctx = ModelContext(try container())
        let near = insert(ctx, group: "Near Show", status: .queued, performanceDate: "2026-10-01")
        let far = insert(ctx, group: "Far Show", status: .queued, performanceDate: "2026-12-01")

        let queue = PrepQueueService.buildQueue(from: ctx, generatedAt: "now",
                                                includedKeys: [near.naturalKey])
        #expect(queue.items.map(\.groupName) == ["Near Show"])
        #expect(!queue.items.contains { $0.naturalKey == far.naturalKey })
    }

    // The whole point of the checkboxes: the selection OVERRIDES the date default in both directions.
    // Dan holds a near show (it drops out) and includes a far one (it rides along), so the chosen set
    // is exactly what runs, not the date-derived default.
    @Test func aToggledSelectionOverridesTheDateDefault() throws {
        let ctx = ModelContext(try container())
        insert(ctx, group: "Near Show", status: .queued, performanceDate: "2026-10-01")   // defaults IN
        let far = insert(ctx, group: "Far Show", status: .queued, performanceDate: "2026-12-01")  // defaults OUT

        let queue = PrepQueueService.buildQueue(from: ctx, generatedAt: "now",
                                                includedKeys: [far.naturalKey])
        #expect(queue.items.map(\.groupName) == ["Far Show"])
    }

    // A nil selection means "no subset chosen": every eligible prospect runs, exactly as before #953,
    // so the change is backward compatible for every existing call site.
    @Test func aNilSelectionRunsEveryEligibleProspect() throws {
        let ctx = ModelContext(try container())
        insert(ctx, group: "Near Show", status: .queued, performanceDate: "2026-10-01")
        insert(ctx, group: "Far Show", status: .queued, performanceDate: "2026-12-01")

        let queue = PrepQueueService.buildQueue(from: ctx, generatedAt: "now", includedKeys: nil)
        #expect(Set(queue.items.map(\.groupName)) == ["Near Show", "Far Show"])
    }

    // startPrep honours the subset end to end: the work-list it writes carries only the selected row,
    // even though a second eligible prospect exists. (The launch throws so this stays offline, but the
    // file is written before launch, so the subset is observable.)
    @Test func startPrepWritesOnlyTheSelectedSubset() async throws {
        let ctx = ModelContext(try container())
        let near = insert(ctx, group: "Near Show", status: .queued, performanceDate: "2026-10-01")
        insert(ctx, group: "Far Show", status: .queued, performanceDate: "2026-12-01")

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("prep-queue-\(UUID().uuidString).json")
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("m-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp); try? FileManager.default.removeItem(at: marker) }

        await #expect(throws: PrepQueueService.PrepLaunchError.runnerUnavailable) {
            try await PrepQueueService.startPrep(from: ctx, now: Date(timeIntervalSince1970: 0),
                                                 includedKeys: [near.naturalKey],
                                                 queueURL: tmp, markerURL: marker,
                                                 launch: { throw PrepQueueService.PrepLaunchError.runnerUnavailable })
        }
        let decoded = try JSONDecoder().decode(PrepQueue.self, from: Data(contentsOf: tmp))
        #expect(decoded.items.map(\.groupName) == ["Near Show"])
    }

    // The edge case Dan can reach from the sheet: uncheck the last near show and select nothing. A run
    // with an empty selection has nothing to prep, so it refuses rather than launching an empty run.
    @Test func startPrepWithAnEmptySelectionReportsNothingToPrep() async throws {
        let ctx = ModelContext(try container())
        insert(ctx, group: "Near Show", status: .queued, performanceDate: "2026-10-01")
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("m-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }

        await #expect(throws: PrepQueueService.PrepLaunchError.nothingToPrep) {
            try await PrepQueueService.startPrep(from: ctx, now: Date(), includedKeys: [],
                                                 markerURL: marker, launch: {})
        }
    }

    // The run button names how many shows the current selection will prep, pluralized. The count is
    // the number of checked rows, so the sentence and the checkboxes can never disagree.
    @Test func runButtonNamesTheSelectedCount() {
        #expect(PrepSelectionCopy.runButton(0) == "Prep 0 shows")
        #expect(PrepSelectionCopy.runButton(1) == "Prep 1 show")
        #expect(PrepSelectionCopy.runButton(3) == "Prep 3 shows")
    }

    // A row's dim second line: venue then date, joined only when both are present, so Dan can see why a
    // row defaulted checked or held (the date is the whole basis of the default).
    @Test func rowDetailShowsVenueThenDate() {
        #expect(PrepSelectionCopy.rowDetail(venue: "Weill Recital Hall", performanceDate: "2026-10-01")
                == "Weill Recital Hall · Oct 1")
        #expect(PrepSelectionCopy.rowDetail(venue: nil, performanceDate: "2026-10-01") == "Oct 1")
        #expect(PrepSelectionCopy.rowDetail(venue: "Weill Recital Hall", performanceDate: nil)
                == "Weill Recital Hall")
    }

    // With neither a venue nor a date there is nothing to show, so the detail is empty and the sheet
    // hides the line rather than inventing a third copy of "Date to be confirmed" (already duplicated in
    // QueueView+Model, #843) that would only drift.
    @Test func rowDetailIsEmptyWhenNothingIsKnown() {
        #expect(PrepSelectionCopy.rowDetail(venue: nil, performanceDate: nil) == "")
    }

    @Test func roundTripsThroughJSON() throws {
        let queue = PrepQueue(version: 2, generatedAt: "now", items: [
            PrepQueueItem(naturalKey: "k", groupName: "G", venue: "V", performanceDate: "2026-07-01",
                          discipline: "choral", websiteURL: nil, sourceListingURL: nil,
                          possibleMatchName: nil, priorRelationship: "none", production: "self")
        ])
        let data = try PrepQueueBuilder.encode(queue)
        let decoded = try JSONDecoder().decode(PrepQueue.self, from: data)
        #expect(decoded == queue)
    }
}
