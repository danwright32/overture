import Testing
import Foundation
import SwiftData

// #1913: what one render pass of the queue is allowed to cost.
//
// Every issue in this milestone was found by reading code AFTER Dan reported the queue stuttering on
// 2026-07-29. Nothing measured what a pass costs, so once they were fixed there was no mechanism that
// would notice the cost creeping back: the detector was Dan, months later, and the same investigation
// would run again.
//
// The cost here is countable rather than timed, which is what makes it a test rather than a flaky
// benchmark. A whole-store sweep is the unit: the pass can only reach the rows through `Corpus.all`, so
// every sweep is counted whether or not whoever added it thought about the cost. A counter the new code
// had to opt into would only ever measure the costs somebody already knew about.
//
// The number below is pinned deliberately, and is meant to be READ and argued with rather than updated to
// whatever the code happens to do. Raising it is a decision about how much a keystroke, a dismiss and a
// scroll are allowed to cost Dan.
@MainActor
@Suite("One render pass of the queue costs a pinned number of sweeps (#1913)")
struct QueueRenderPassCostTests {
    // The live store measured 724 prospects on 2026-08-01, 511 of them untriaged. A corpus that size is
    // what makes the count meaningful: at ten rows every shape is fast and nothing is learned.
    private static let corpusSize = 724
    private static let untriaged = 511

    // Eight sweeps of the store, once each, and every one of them named. If this number moves, one of
    // these lines has changed or a new one has appeared, and either is a decision rather than an accident:
    //
    //   1. resolving each show's place for the pass (#1962)
    //   2. building the queue's rows
    //   3. the whole-store corpus those rows are judged against (venue brands, inherited answers)
    //   4. the shows already reached out to
    //   5. which shows are in a stage at all
    //   6. which of those the focused stage renders
    //   7. the agent strip's inputs
    //   8. the possible-match fan-out scan
    private static let allowedSweeps = 8

    private func container() throws -> ModelContainer {
        try ModelContainer(
            for: Schema([Prospect.self, Recipient.self, Inquiry.self, OrgReachabilityAnswer.self,
                         WatchedSource.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    // A corpus with the spread a real store has: most rows untriaged, the rest drafted or contacted, and
    // dates either side of today, so no sweep can short-circuit on an empty or uniform list.
    private func seed(_ ctx: ModelContext) -> [Prospect] {
        let venues = ["Weill Recital Hall", "SoHo Playhouse", "The Green Room 42", "Merkin Hall",
                      "Roulette Intermedium", "The Tank", "Bargemusic", "David Geffen Hall"]
        var rows: [Prospect] = []
        for n in 0..<Self.corpusSize {
            let day = 1 + (n % 27)
            let month = 8 + (n % 4)
            let date = String(format: "2026-%02d-%02d", month, day)
            let venue = venues[n % venues.count]
            let key = "row-\(n)"
            let p = Prospect(naturalKey: key, groupName: "Ensemble \(n % 90)", discipline: "music",
                             venue: venue, performanceDate: date, sourceListingURL: nil,
                             priorRelationship: "none", production: n % 3 == 0 ? "self" : "presenter",
                             profile: "strong", coverage: "likely_uncovered", fitScore: 4 + (n % 5),
                             tier: "mid", fitReason: "r", matchedClientName: nil,
                             possibleMatchSource: nil,
                             possibleMatchName: n % 40 == 0 ? "Carnegie Hall" : nil,
                             status: n < Self.untriaged ? .new : (n % 2 == 0 ? .drafted : .contacted))
            p.presenter = n % 5 == 0 ? venue : "Ensemble \(n % 90) Presents"
            p.location = "New York, NY"
            ctx.insert(p)
            rows.append(p)
        }
        try? ctx.save()
        return rows
    }

    private func inputs(_ rows: [Prospect], tally: QueueRenderPass.CostTally) -> QueueRenderPass.Inputs {
        QueueRenderPass.Inputs(
            prospects: QueueRenderPass.Corpus(rows, tally: tally),
            allProspects: QueueRenderPass.Corpus(rows, tally: tally),
            inquiries: [], orgAnswers: [],
            context: .at("2026-08-02", now: Date(timeIntervalSince1970: 1_785_000_000)),
            focusedStage: .scout, focusedKeys: nil)
    }

    // The measurement. One pass over a realistic store sweeps it a pinned number of times.
    @Test func onePassSweepsTheStoreAPinnedNumberOfTimes() throws {
        let ctx = ModelContext(try container())
        let rows = seed(ctx)
        let tally = QueueRenderPass.CostTally()

        let data = QueueRenderPass.make(inputs(rows, tally: tally))

        // The list at the top of this file names every one of them. Raising the number is a decision
        // about how much a keystroke, a dismiss and a scroll are allowed to cost Dan.
        #expect(tally.sweeps == Self.allowedSweeps)
        // And it really did derive the whole store, so the count above is not the cost of doing nothing.
        #expect(data.items.count == Self.corpusSize)
        #expect(!data.visible.isEmpty)
    }

    // The cost does not grow with what Dan is looking at. A stage focus, a frozen key set and a deep link
    // all change what renders, and none of them may add a trip through the store.
    @Test func lookingAtADifferentStageCostsTheSameSweeps() throws {
        let ctx = ModelContext(try container())
        let rows = seed(ctx)

        for stage in [StageFocus.scout, .review, .prep, .sendApproved, .followUps] {
            let tally = QueueRenderPass.CostTally()
            var i = inputs(rows, tally: tally)
            i.focusedStage = stage
            _ = QueueRenderPass.make(i)
            #expect(tally.sweeps == Self.allowedSweeps, "the \(stage) stage cost a different number")
        }
    }

    // A frozen key set (leads mode) is the other way the queue can be narrowed, and it must not cost more
    // either: the rows are filtered from what the pass already built.
    @Test func aFrozenKeySetCostsTheSameSweeps() throws {
        let ctx = ModelContext(try container())
        let rows = seed(ctx)
        let tally = QueueRenderPass.CostTally()
        var i = inputs(rows, tally: tally)
        i.focusedStage = nil
        i.focusedKeys = rows.prefix(20).map(\.naturalKey)

        let data = QueueRenderPass.make(i)

        #expect(tally.sweeps == Self.allowedSweeps)
        #expect(data.focusedRows.count == 20)
    }
}

// The other half of the cost, and the one a sweep count cannot see: a file read on the render path. The
// pass takes every file-backed answer as a value, so it cannot reach the filesystem at all, and this is
// what holds it to that.
@Suite("A render pass reads no files (#1913)")
struct QueueRenderPassIsPureTests {
    private var renderPass: String { SourceGuardHelper.source("Overture/UI/QueueRenderPass.swift") }

    @Test func thePassNeverTouchesTheFilesystem() {
        #expect(!renderPass.isEmpty)
        // Each of these was, at some point, read from inside the queue's own derivation: the Gmail token
        // (#1770), the shoot history and the Downbeat export (#1964), and the two detached run markers
        // (#1923, #1938). The rest are handed in as values now; the shoot history is not read here at
        // all any more (#2080 removed the only card that wanted it), and stays on this list so putting
        // a file read back on the render path is a red test rather than a silent regression.
        for reader in ["GmailConnection", "VenueShootHistory.current", "DownbeatBridge.loadedExport",
                       "ShootHistory.load", "PrepQueueService.isRunning", "ReplyClassifyService.isRunning",
                       "FileManager", "Data(contentsOf:"] {
            #expect(!renderPass.contains(reader),
                    "\(reader) is a filesystem read, and this runs on every render pass")
        }
    }

    // The counting is not optional. If the rows could be reached around the corpus, a new sweep would be
    // invisible to the measurement above and the guard would quietly stop guarding.
    @Test func theRowsCanOnlyBeReachedThroughTheCountedAccessor() {
        guard let corpus = SourceGuardHelper.propertyBody("struct Corpus {", in: renderPass) else {
            Issue.record("expected to find the corpus")
            return
        }
        #expect(corpus.contains("private let rows: [Prospect]"))
        #expect(corpus.contains("tally?.recordSweep()"))
    }
}
