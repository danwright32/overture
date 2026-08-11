import Testing
import Foundation
import SwiftData

// #1940: the return half. A queued re-prep takes a show out of the Review count, so a run that ends
// without serving that request has to give the show back, or a draft Dan could have read sits under Prep
// waiting on a run that already came and went (L45).
//
// The case that makes this necessary is `DetachedRunOutcome.finishedEmpty`: the run produced no results
// file at all, so PrepImporter, which is what ordinarily clears the flags, never runs over anything.
@MainActor
@Suite("A finished run gives back the re-prep it did not serve (#1940)")
struct ReprepReleaseTests {
    private func makeContext() -> ModelContext {
        ModelContext(try! ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                         configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func drafted(_ ctx: ModelContext, key: String) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: key, discipline: "theatre", venue: "Under St Marks",
                         performanceDate: "2099-08-14", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .drafted)
        p.draftBody = "Hi"
        ctx.insert(p)
        return p
    }

    private func inReview(_ p: Prospect) -> Bool {
        StageNavigation.naturalKeys(for: .review, in: [p], context: StageContext(geo: .none)).count == 1
    }

    private func inPrep(_ p: Prospect) -> Bool {
        StageNavigation.naturalKeys(for: .prep, in: [p], context: StageContext(geo: .none)).count == 1
    }

    // The issue's own case: the run came home with nothing, so the draft Dan already had is worth reading
    // again and Review must count it.
    @Test func aRunThatFinishedEmptyGivesTheShowBackToReview() {
        let ctx = makeContext()
        let p = drafted(ctx, key: "reprep")
        p.reprepDraftRequested = true
        p.reprepHandedToRun = true
        #expect(!inReview(p))                       // out of Review while the run has it

        let released = ReprepRelease.release(in: [p])

        #expect(released == ["reprep"])
        #expect(inReview(p))
        #expect(!inPrep(p))
        #expect(!p.isReprepQueued)
        #expect(!p.reprepHandedToRun)
    }

    // The other half, and the reason the hand-over stamp exists at all: a re-prep Dan queued in bulk that
    // no run has picked up yet is still waiting for its run, so an unrelated run finishing must not take
    // the request away from it.
    @Test func aReprepNoRunHasCarriedIsLeftWaiting() {
        let ctx = makeContext()
        let waiting = drafted(ctx, key: "queued-by-hand")
        waiting.reprepContactsRequested = true
        let carried = drafted(ctx, key: "carried")
        carried.reprepContactsRequested = true
        carried.reprepHandedToRun = true

        let released = ReprepRelease.release(in: [waiting, carried])

        #expect(released == ["carried"])
        #expect(waiting.isReprepQueued)
        #expect(!inReview(waiting))
        #expect(inPrep(waiting))
    }

    // Nothing was researched and nothing was written, so asking again must not be refused as asking twice.
    @Test func aReleasedRequestDoesNotStartTheReprepCooldown() {
        let ctx = makeContext()
        let p = drafted(ctx, key: "reprep")
        p.reprepDraftRequested = true
        p.reprepHandedToRun = true

        ReprepRelease.release(in: [p])

        #expect(p.reprepLastServedAt == nil)
        #expect(!ReprepRequest.isInCooldown(lastServedAt: p.reprepLastServedAt, now: Date()))
    }

    // A run that DID serve the request has already had its flags cleared by PrepImporter, so there is
    // nothing to give back and nothing to report as left undone. The hand-over stamp still clears, or the
    // next finished run would read this show as one it was carrying.
    @Test func aServedRequestIsNotReportedAsLeftUndone() {
        let ctx = makeContext()
        let p = drafted(ctx, key: "served")
        p.reprepHandedToRun = true          // PrepImporter cleared both flags on the way through

        let released = ReprepRelease.release(in: [p])

        #expect(released.isEmpty)
        #expect(!p.reprepHandedToRun)
        #expect(inReview(p))
    }

    // The store-wide form the finished run actually calls, saved, because a release that is not persisted
    // leaves the show out of Review until something else happens to save.
    @Test func theStoreWideReleaseSavesWhatItChanged() throws {
        let ctx = makeContext()
        let p = drafted(ctx, key: "reprep")
        p.reprepDraftRequested = true
        p.reprepHandedToRun = true
        try ctx.save()

        let released = ReprepRelease.releaseAfterRun(in: ctx)

        #expect(released == ["reprep"])
        #expect(!ctx.hasChanges)
        let all = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(all.allSatisfy { !$0.isReprepQueued && !$0.reprepHandedToRun })
    }

    // Running twice must be the same as running once: a second settle over a store the first already
    // released takes nothing else away (CLAUDE.md, assume it runs twice).
    @Test func aSecondReleaseOverTheSameStoreChangesNothing() throws {
        let ctx = makeContext()
        let p = drafted(ctx, key: "reprep")
        p.reprepDraftRequested = true
        p.reprepHandedToRun = true
        try ctx.save()
        ReprepRelease.releaseAfterRun(in: ctx)

        // Dan asks for another re-prep before anything else runs.
        p.reprepDraftRequested = true
        try ctx.save()
        let second = ReprepRelease.releaseAfterRun(in: ctx)

        #expect(second.isEmpty)
        #expect(p.isReprepQueued, "a fresh request must survive a settle for a run that never carried it")
    }
}

// #1940: the two ends of the release, which are separate claims from the release itself (#1679: a rule and
// its wiring are two claims). Nothing stamps a show as handed over unless a run really took it, and every
// way a run can end runs the release, or the return to Review happens on some paths and not others.
@MainActor
@Suite("A Prep run picks up and puts down the re-preps it carries (#1940)")
struct ReprepHandOverTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(
            for: Schema([Prospect.self, PromotedProducer.self, DemotedHouse.self, Recipient.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    @discardableResult
    private func insert(_ ctx: ModelContext, key: String, status: ReviewStatus,
                        hasDraft: Bool, reprep: Bool) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: key, discipline: "other", venue: "The Room",
                         performanceDate: "2099-09-11", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: status)
        if hasDraft { p.draftBody = "Hi" }
        p.reprepDraftRequested = reprep
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    private func tmp(_ prefix: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    }

    // The launch stamps only what actually went into the queue file the run opens, so the release later
    // can tell a request a run declined from one still waiting for its first run.
    @Test func theLaunchStampsTheReprepsItPutsInTheQueue() async throws {
        let ctx = ModelContext(try container())
        let carried = insert(ctx, key: "carried", status: .drafted, hasDraft: true, reprep: true)
        let waiting = insert(ctx, key: "waiting", status: .drafted, hasDraft: true, reprep: true)
        let plain = insert(ctx, key: "kept", status: .queued, hasDraft: false, reprep: false)
        let queueURL = tmp("q"), markerURL = tmp("m")
        defer { try? FileManager.default.removeItem(at: queueURL); try? FileManager.default.removeItem(at: markerURL) }

        _ = try await PrepQueueService.startPrep(from: ctx, now: Date(),
                                                 includedKeys: ["carried", "kept"],
                                                 queueURL: queueURL, markerURL: markerURL,
                                                 render: { _ in "" }, launch: {})

        #expect(carried.reprepHandedToRun)
        #expect(!waiting.reprepHandedToRun, "a show the run was not given must not be marked as carried")
        #expect(!plain.reprepHandedToRun, "a first prep carries no re-prep request to give back")
    }

    // A launch that never happened has handed nothing over, so a later run's settle cannot take the
    // request away from a show this run failed to start on.
    @Test func aLaunchThatFailedStampsNothing() async throws {
        let ctx = ModelContext(try container())
        let p = insert(ctx, key: "carried", status: .drafted, hasDraft: true, reprep: true)
        let queueURL = tmp("q"), markerURL = tmp("m")
        defer { try? FileManager.default.removeItem(at: queueURL); try? FileManager.default.removeItem(at: markerURL) }

        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            _ = try await PrepQueueService.startPrep(from: ctx, now: Date(), queueURL: queueURL,
                                                     markerURL: markerURL, render: { _ in "" },
                                                     launch: { throw Boom() })
        }

        #expect(!p.reprepHandedToRun)
        #expect(p.isReprepQueued, "the request itself survives, so the show rides the next run")
    }

    // Every way a Prep run can end has to give the requests back, and each of them is a different branch in
    // RootView with no shared exit. Guarded by source because the failure is invisible: miss one and the
    // show simply never returns to Review, which no other test would notice.
    @Test func everyWayARunCanEndRunsTheRelease() {
        let root = SourceGuardHelper.source("Overture/App/RootView.swift")
        #expect(!root.isEmpty)

        // The run produced results (the ingest path), and the launch-time ingest of a run that finished
        // while Overture was closed, both go through ingestPrep.
        let ingest = SourceGuardHelper.propertyBody("private func ingestPrep() {", in: root)
        #expect(ingest?.contains("ReprepRelease.releaseAfterRun(in: context)") == true,
                "a run that produced results must give back the requests it did not serve")

        // The run finished having produced nothing at all: the case #1940 exists for.
        let settle = SourceGuardHelper.propertyBody("private func settleFinishedPrepRun() async {", in: root)
        #expect(settle?.contains("ReprepRelease.releaseAfterRun(in: context)") == true,
                "a run that finished empty must give back every request it was carrying")

        // The run died rather than finished.
        let swept = SourceGuardHelper.propertyBody("private func sweptADeadPrepRun() -> Bool {", in: root)
        #expect(swept?.contains("ReprepRelease.releaseAfterRun(in: context)") == true,
                "a run that died must give back every request it was carrying")
    }
}
