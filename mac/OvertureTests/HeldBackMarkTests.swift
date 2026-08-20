import Testing
import Foundation
import SwiftData

// #3013, phase 5 of the revised #2765 plan. Dan's call, 2026-08-20: he finds out a show was left out both
// from the launch and from a mark on the show's own card, the mark surviving after the message clears.
//
// A launch message alone is the defect L126 names: it describes a condition that PERSISTS in the data,
// and once the notice clears an excluded show is indistinguishable from one Dan never picked.
//
// A STAMPED EVENT, never a standing "a live run holds this". A boolean asserting that is simply FALSE the
// moment the holding run is cancelled or dies, and the only thing that would clear it is a future run
// taking the show, which for a show Dan never re-preps may never come (L200, filed from this repo as
// #3001 this month; L121). So: when it was left out, and by which slot. Whether it is STILL held is
// derived at read time.
//
// The clearing is the half the first plan got provably wrong, and both reviewers caught it independently.
@MainActor
@Suite("A show left out of a run is marked, and the mark clears (#3013)")
struct HeldBackMarkTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, OrgReachabilityAnswer.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func dir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @discardableResult
    private func newProspect(_ ctx: ModelContext, group: String) -> String {
        let key = Prospect.makeNaturalKey(groupName: group, performanceDate: "2026-09-12", venue: "Weill Recital Hall")
        let p = Prospect(naturalKey: key, groupName: group, discipline: "music", venue: "Weill Recital Hall",
                         performanceDate: "2026-09-12", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .new)
        ctx.insert(p)
        try? ctx.save()
        return key
    }

    private func prospect(_ ctx: ModelContext, _ key: String) -> Prospect? {
        ((try? ctx.fetch(FetchDescriptor<Prospect>())) ?? []).first { $0.naturalKey == key }
    }

    // MARK: - Writing the mark

    @Test func aDroppedShowIsStampedWithWhenAndWhichRun() throws {
        let ctx = ModelContext(try container())
        let dropped = newProspect(ctx, group: "Aurora Strings")
        let now = Date()

        PrepQueueService.recordHeldBack(dropped: [dropped], carried: [], by: .check, at: now, in: ctx)

        #expect(prospect(ctx, dropped)?.heldBackAt == now)
        #expect(prospect(ctx, dropped)?.heldBackBySlot == "check",
                "a mark that does not say which run left the show out is anonymous the moment it goes stale")
    }

    @Test func aShowTheRunCarriedIsNotMarked() throws {
        let ctx = ModelContext(try container())
        let carried = newProspect(ctx, group: "Borealis Quartet")
        PrepQueueService.recordHeldBack(dropped: [], carried: [carried], by: .prep, at: Date(), in: ctx)
        #expect(prospect(ctx, carried)?.heldBackAt == nil)
    }

    // MARK: - Clearing it

    // The case that killed the first plan. It proposed clearing through `markHandedToRun`, which is keyed
    // `where keys.contains(...) && p.isReprepQueued`, so it touches only shows with a pending re-prep
    // request. This show has none, which is the ORDINARY case, and it must still be cleared.
    @Test func aShowWithNoReprepRequestIsStillClearedWhenARunCarriesIt() throws {
        let ctx = ModelContext(try container())
        let key = newProspect(ctx, group: "Aurora Strings")
        PrepQueueService.recordHeldBack(dropped: [key], carried: [], by: .check, at: Date(), in: ctx)
        #expect(prospect(ctx, key)?.heldBackAt != nil)
        #expect(prospect(ctx, key)?.isReprepQueued == false, "the fixture must be the ordinary case, with no request pending")

        PrepQueueService.recordHeldBack(dropped: [], carried: [key], by: .prep, at: Date(), in: ctx)

        #expect(prospect(ctx, key)?.heldBackAt == nil,
                "a show carried by a later run kept its mark, so the card says it was left out of a run that took it")
        #expect(prospect(ctx, key)?.heldBackBySlot == nil)
    }

    // MARK: - The sweep, for a run that never carried it and then ended

    @Test func aMarkLeftByARunThatEndedIsSweptAway() throws {
        let ctx = ModelContext(try container())
        let key = newProspect(ctx, group: "Aurora Strings")
        let d = dir()
        PrepQueueService.recordHeldBack(dropped: [key], carried: [], by: .check, at: Date(), in: ctx)

        // No live coverage anywhere: whatever was holding it has ended.
        PrepQueueService.sweepStaleHeldBackMarks(support: d, now: Date(), in: ctx)

        #expect(prospect(ctx, key)?.heldBackAt == nil,
                "a mark outlived the run that caused it, which is exactly the failure L200 records")
    }

    // THE POSITIVE CONTROL, same fixture plus the one thing that should keep the mark: the run is still
    // live and still holding this show. Without it the sweep could clear everything always and pass.
    @Test func aMarkSurvivesWhileTheRunHoldingItIsStillLive() throws {
        let ctx = ModelContext(try container())
        let key = newProspect(ctx, group: "Aurora Strings")
        let d = dir()
        try RunCoverage.write(keys: [key], slot: .check, in: d)
        try Data().write(to: RunSlot.check.markerURL(in: d))
        PrepQueueService.recordHeldBack(dropped: [key], carried: [], by: .check, at: Date(), in: ctx)

        PrepQueueService.sweepStaleHeldBackMarks(support: d, now: Date(), in: ctx)

        #expect(prospect(ctx, key)?.heldBackAt != nil,
                "the sweep cleared a mark whose run is still holding the show, so the card stops saying why it was skipped")
    }

    @Test func theSweepLeavesUnmarkedShowsAlone() throws {
        let ctx = ModelContext(try container())
        let key = newProspect(ctx, group: "Borealis Quartet")
        let d = dir()
        PrepQueueService.sweepStaleHeldBackMarks(support: d, now: Date(), in: ctx)
        #expect(prospect(ctx, key)?.heldBackAt == nil)
    }
}

// The sentence the card shows. Every branch has a test that PRODUCES it, including the one for a store
// written by a newer build, because a lookup keyed on a vocabulary takes its default branch silently and
// a default is indistinguishable from a deliberate choice (L113, L151).
@Suite("What the card says about a show that was left out (#3013)")
struct HeldBackNoteTests {

    private func item(heldBackFrom: String?) -> QueueItem {
        var i = QueueItem(id: "k", groupName: "Aurora Strings", discipline: "music",
                          venue: "Weill Recital Hall", performanceDate: "2026-09-12",
                          sourceListingURL: nil, websiteURL: nil,
                          priorRelationship: "none", production: "self", profile: "strong",
                          coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                          matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                          status: .new)
        i.heldBackFrom = heldBackFrom
        return i
    }

    @Test func aShowThatWasNotLeftOutSaysNothing() {
        #expect(QueueModel.heldBackNote(item(heldBackFrom: nil)) == nil)
    }

    @Test func aPrepRunNamesTheCheckThatHadIt() {
        let note = QueueModel.heldBackNote(item(heldBackFrom: RunSlot.prep.rawValue))
        #expect(note?.contains("prep run") == true)
        #expect(note?.contains("contact check") == true,
                "the note must name what was holding the show, or it says a run skipped it for no reason")
    }

    @Test func aContactCheckNamesThePrepThatHadIt() {
        let note = QueueModel.heldBackNote(item(heldBackFrom: RunSlot.check.rawValue))
        #expect(note?.contains("contact check") == true)
        #expect(note?.contains("prep run") == true)
    }

    // A slot this build does not recognise means a store written by a newer one. It must still say the
    // show was skipped, because that part is true and it is the part Dan needs, rather than guessing
    // which run it was or dropping the note and leaving the skip unexplained (L11).
    @Test func anUnknownSlotStillSaysTheShowWasLeftOut() {
        let note = QueueModel.heldBackNote(item(heldBackFrom: "something-newer"))
        #expect(note != nil)
        #expect(note?.contains("Left out") == true)
    }
}
