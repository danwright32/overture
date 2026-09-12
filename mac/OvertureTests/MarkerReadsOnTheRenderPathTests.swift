import Testing
import Foundation
import SwiftData

// #3646: a marker file read off disk once per rendered card and once per date heading.
//
// `QueueView.checkRunning` was a computed property calling `PrepQueueService.isRunning`, and the queue
// called it once for every date group it drew (235 of them on the live store) and once for every card.
// The answer was already in hand on the very next line: `RenderData.probeRunning` is derived once for
// the whole pass and was being handed to the same view as the argument beside it.
//
// It could not be cached away either, which is what made it expensive rather than merely untidy. The
// marker URLs are computed properties on purpose (#1613): Foundation caches resource values on a `URL`
// value, so a reused one keeps answering with its first reading even after the file is deleted, which
// turns "the marker is gone" into "the marker is still there and stale". That fix is right and stays, so
// every one of those calls really did reach the filesystem.
//
// Nothing could see it. `QueueRenderPass.Corpus` counts whole-store sweeps and `WorkTally` counts card
// construction; a `stat` is neither. So the instrument comes first here and the fix second.
@Suite("Every marker read off disk is counted (#3646)")
final class MarkerReadTallyTests {
    private let sandboxes = TemporarySandboxes()

    // The counter is over READS, not over markers that exist. An absent marker costs the same `stat` as a
    // present one, and absent is the state an idle queue is in every single time, so a counter that only
    // saw live runs would report zero for exactly the case this issue is about (L90).
    @Test func aReadOfAnAbsentMarkerIsStillARead() throws {
        let dir = try sandboxes.make(named: "marker-read-tally")
        let missing = dir.appendingPathComponent("nothing-here.marker")

        let tally = DetachedRunner.MarkerReadTally.measure {
            _ = DetachedRunner.heartbeat(markerURL: missing, now: Date(), staleAfter: 120)
            _ = DetachedRunner.heartbeat(markerURL: missing, now: Date(), staleAfter: 120)
        }

        #expect(tally.reads == 2)
    }

    // And a present one counts too, so the two states cannot be told apart by the cost they report.
    @Test func aReadOfALiveMarkerIsARead() throws {
        let dir = try sandboxes.make(named: "marker-read-tally")
        let marker = dir.appendingPathComponent("live.marker")
        try Data().write(to: marker)

        let tally = DetachedRunner.MarkerReadTally.measure {
            #expect(DetachedRunner.heartbeat(markerURL: marker, now: Date(), staleAfter: 120) == .beating)
        }

        #expect(tally.reads == 1)
    }

    // A tally reports on the work the measurer ran and on nothing else, which is what stops one reading
    // being answered by work somebody else did.
    @Test func aTallyCountsOnlyWhatItsOwnBodyRead() throws {
        let dir = try sandboxes.make(named: "marker-read-tally")
        let missing = dir.appendingPathComponent("nothing-here.marker")

        _ = DetachedRunner.heartbeat(markerURL: missing, now: Date(), staleAfter: 120)
        let tally = DetachedRunner.MarkerReadTally.measure { }

        #expect(tally.reads == 0)
    }
}

// The per-slot answer, from one reading of the two markers.
// @MainActor because `PrepQueueService` is: every marker read in it is main-actor isolated.
@MainActor
@Suite("Both run slots are answered from one reading of the markers (#3646)")
final class SlotStatusTests {
    private let sandboxes = TemporarySandboxes()

    private func emptyDefaults() -> UserDefaults {
        UserDefaults(suiteName: "slot-status-\(UUID().uuidString)") ?? .standard
    }

    // Two markers, two reads, whatever the answer turns out to be. This is what the queue pays once per
    // render pass, and the figure everything below is measured against.
    @Test func anIdleMachineCostsOneReadPerSlot() throws {
        let dir = try sandboxes.make(named: "slot-status")

        var status: PrepQueueService.SlotStatus?
        let tally = DetachedRunner.MarkerReadTally.measure {
            status = PrepQueueService.slotStatus(now: Date(), support: dir, defaults: emptyDefaults())
        }

        #expect(tally.reads == 2)
        #expect(status?.prepSlotRunning == false)
        #expect(status?.checkSlotRunning == false)
        #expect(status?.inFlight == nil)
    }

    // THE reason the per-slot facts exist rather than `inFlight` alone. Since #3015 a prep run and a
    // check may go at once, and `inFlight` then answers `.prep`, because the prep slot is asked first.
    // A row's "Check again" control is greyed by whether a CHECK is running, so reading `inFlight` for it
    // would offer the control while a check was live and fail after the press.
    @Test func aCheckBesideALivePrepIsVisibleInItsOwnSlot() throws {
        let dir = try sandboxes.make(named: "slot-status")
        try Data().write(to: RunSlot.prep.markerURL(in: dir))
        try Data().write(to: RunSlot.check.markerURL(in: dir))

        let status = PrepQueueService.slotStatus(now: Date(), support: dir, defaults: emptyDefaults())

        #expect(status.prepSlotRunning)
        #expect(status.checkSlotRunning)
        #expect(status.inFlight == .prep)
    }

    // And the composed answer is still #2614's, so every surface that NAMES the run is unchanged.
    @Test func aCheckAloneIsTheRunInFlight() throws {
        let dir = try sandboxes.make(named: "slot-status")
        try Data().write(to: RunSlot.check.markerURL(in: dir))

        let status = PrepQueueService.slotStatus(now: Date(), support: dir, defaults: emptyDefaults())

        #expect(!status.prepSlotRunning)
        #expect(status.checkSlotRunning)
        #expect(status.inFlight == .reachabilityCheck)
        // The single-answer reader gives the same verdict, because it is now the same code.
        #expect(PrepQueueService.runInFlight(now: Date(), support: dir, defaults: emptyDefaults())
                == .reachabilityCheck)
    }
}

// The pass itself, measured rather than read. `QueueRenderPassIsPureTests` names the readers the pass may
// not contain, which is a source-text guard and so is answered by a spelling; this is the quantity (L63).
@MainActor
@Suite("A render pass reads no run markers at all (#3646)")
struct TheRenderPassReadsNoMarkersTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(
            for: Schema([Prospect.self, Recipient.self, Inquiry.self, OrgReachabilityAnswer.self,
                         WatchedSource.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    @Test func onePassReadsNothingOffDisk() throws {
        let ctx = ModelContext(try container())
        let now = Date()
        var rows: [Prospect] = []
        for n in 0..<12 {
            // Dated FROM the clock rather than pinned, so the shows stay inside the queue's own lead-time
            // window whatever year this runs in (L130).
            let p = Prospect(naturalKey: "row-\(n)", groupName: "Ensemble \(n)", discipline: "music",
                             venue: "Venue \(n)",
                             performanceDate: EasternDate.dayString(
                                 from: now.addingTimeInterval(Double(20 + n) * 86_400)),
                             sourceListingURL: nil, priorRelationship: "none", production: "self",
                             profile: "strong", coverage: "likely_uncovered", fitScore: 6, tier: "mid",
                             fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                             possibleMatchName: nil)
            ctx.insert(p)
            rows.append(p)
        }
        try? ctx.save()

        var data: QueueView.RenderData?
        let tally = DetachedRunner.MarkerReadTally.measure {
            data = QueueRenderPass.make(QueueRenderPass.Inputs(
                allProspects: QueueRenderPass.Corpus(rows),
                inquiries: [], orgAnswers: [],
                context: .at(EasternDate.dayString(from: now), now: now),
                focusedStage: .scout, focusedKeys: nil))
        }

        // The positive control first: a pass that derived nothing would read nothing either, and the
        // emptiest possible failure must not read as the cleanest possible pass (L98).
        #expect(data?.rows.count == 12)
        #expect(tally.reads == 0)
    }

    // The two new values, each carried from the slot it is about. They are separate fields rather than
    // one because the controls they grey start different runs: the Prep button starts a prep, the row's
    // "Check again" starts a check, and since #3015 either can be live while the other is.
    @Test func eachSlotsAnswerReachesTheRenderDataUnchanged() throws {
        let now = Date()
        var onlyCheck = QueueRenderPass.Inputs(
            allProspects: QueueRenderPass.Corpus([]), inquiries: [], orgAnswers: [],
            context: .at(EasternDate.dayString(from: now), now: now),
            focusedStage: .scout, focusedKeys: nil)
        onlyCheck.checkSlotRunning = true
        onlyCheck.prepSlotRunning = false
        let checking = QueueRenderPass.make(onlyCheck)
        #expect(checking.checkRunning)
        #expect(!checking.prepRunning)

        var onlyPrep = onlyCheck
        onlyPrep.checkSlotRunning = false
        onlyPrep.prepSlotRunning = true
        let prepping = QueueRenderPass.make(onlyPrep)
        #expect(!prepping.checkRunning)
        #expect(prepping.prepRunning)
    }
}

// The call sites, held to reading what the pass already derived. `MarkerReadsDoNotScaleWithTheQueueTests`
// is what MEASURES a drawn queue; these say where the answer has to come from, so a reintroduced read is
// named at the line rather than reaching somebody as a number that moved.
@Suite("The queue reads its run markers once per pass, never per row (#3646)")
struct TheQueueReadsItsMarkersOncePerPassTests {
    private var queueView: String { SourceGuardHelper.source("Overture/UI/QueueView.swift") }

    // The view reads no marker of its own AT ALL. Every file-backed answer this view needs arrives
    // through `makeRenderData`, which runs once per pass, exactly as the Gmail connection does (#1770).
    // A computed property is what made this per-row: it reads as free at the call site.
    @Test func theViewReadsNoRunMarkerOfItsOwn() {
        let source = queueView
        #expect(!source.isEmpty)
        #expect(!source.contains("PrepQueueService.isRunning"),
                "a marker read in QueueView is a disk read per call site, and its call sites are rows")
        #expect(!source.contains("private var checkRunning"),
                "a computed property reading a marker reads as free at the call site, which is #3646")
        #expect(!source.contains("private var prepRunning"))
    }

    // The date heading: once per date group, 235 of them on the live store.
    @Test func theDateHeadingReadsThePassesAnswer() {
        guard let body = SourceGuardHelper.bodyOfFunction(named: "dateSection", in: queueView) else {
            Issue.record("expected to find dateSection")
            return
        }
        #expect(body.contains("isRunning: data.checkRunning"))
    }

    // The card: once per rendered row, beside `probeRunning: data.probeRunning`, which was already free.
    @Test func theCardReadsThePassesAnswer() {
        guard let body = SourceGuardHelper.bodyOfFunction(named: "prospectRow", in: queueView) else {
            Issue.record("expected to find prospectRow")
            return
        }
        #expect(body.contains("checkRunning: data.checkRunning"))
        #expect(body.contains("probeRunning: data.probeRunning"))
    }

    // The Prep button: once per render rather than per row, so far cheaper and the same defect.
    @Test func thePrepButtonReadsThePassesAnswer() {
        guard let body = SourceGuardHelper.bodyOfFunction(named: "focusedSection", in: queueView) else {
            Issue.record("expected to find focusedSection")
            return
        }
        #expect(body.contains("prepRunning: data.prepRunning"))
    }

    // And the check bar over the scroll, which is the fourth reader of the same fact.
    @Test func theSelectionBarReadsThePassesAnswer() {
        guard let body = SourceGuardHelper.bodyOfFunction(named: "probeSelectionBar", in: queueView) else {
            Issue.record("expected to find probeSelectionBar")
            return
        }
        #expect(body.contains("checkRunning: data.checkRunning"))
    }
}
