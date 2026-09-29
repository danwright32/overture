import Testing
import Foundation
import AppKit
import SwiftUI
import SwiftData
@testable import Overture

// #4106 view workstream: the masthead folds over the whole queue NOWHERE but in the render pass.
//
// WHAT WAS MEASURED. The view attribution probe (#4306) sampled the main thread while a real QueueView
// drew a SERVED pass on the live clone, so the derivation was outside every reading, and one frame kept
// coming back: `QueueModel.keysMissedByACheck`, called from the masthead as
// `!missedByACheckKeys(in: items).isEmpty`. It was 41.6% of the busy time on a one row dismissal, 27.7%
// on a stage change and 15.9% on a first draw (Debug, 409 rows). The masthead asked it over EVERY row of
// the queue on EVERY body evaluation, and a body runs on events that change no data (L471).
//
// WHAT THIS PINS. Over a served pass the body derives nothing, so any row a whole-queue fold examines
// while the queue draws is a fold the BODY did. The count is `WorkTally.wholeQueueFoldRows`, recorded by
// both folds the masthead shows (the high-fit summary and the missed-by-a-check offer), and it must be
// zero. Counted, never timed (L63, L224).
//
// THE POSITIVE CONTROL is in the same fixture (L159): building the pass itself examines rows, so the
// counter is live under this tally and a zero below is the body doing nothing rather than a counter
// nobody reaches.
@MainActor
@Suite("The masthead folds over the whole queue nowhere but the pass (#4106)")
final class TheMastheadFoldsNothingPerBodyTests {
    private static let rows = 40

    private static func night(_ n: Int) -> String {
        let day = Calendar(identifier: .gregorian).date(byAdding: .day, value: 20 + n, to: Date())!
        return EasternDate.dayString(from: day)
    }

    // Invented names (L155). A row a check missed, so the offer the masthead gates is really answered
    // "yes" in this fixture and the fold would have to look at every row to say so.
    private func seed(_ ctx: ModelContext) throws -> [Prospect] {
        for n in 0..<Self.rows {
            let p = Prospect(naturalKey: "fold-\(n)", groupName: "Marrowby Consort \(n)", discipline: "music",
                             venue: "Tallowfield Hall \(n % 5)", performanceDate: Self.night(n / 4),
                             sourceListingURL: nil, priorRelationship: "none",
                             production: "self", profile: "strong",
                             coverage: "likely_uncovered", fitScore: 4 + (n % 5),
                             tier: n % 3 == 0 ? "high" : "mid",
                             fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                             possibleMatchName: nil, status: .new)
            p.location = "New York, NY"
            if n % 7 == 0 { p.reachabilityUnansweredAt = Date().addingTimeInterval(-3_600) }
            ctx.insert(p)
        }
        try ctx.save()
        return try ctx.fetch(FetchDescriptor<Prospect>())
    }

    private func pass(_ shows: [Prospect], stage: StageFocus) -> QueueView.RenderData {
        QueueRenderPass.make(QueueRenderPass.Inputs(
            allProspects: QueueRenderPass.Corpus(shows), inquiries: [], orgAnswers: [],
            context: StageContext(now: Date(), geo: .none, clients: .none),
            focusedStage: stage))
    }

    @Test func aDrawnQueueFoldsNoRowOutsideThePass() throws {
        let c = try TestModelContainer.inMemory(AppSchema.models)
        let shows = try seed(c.mainContext)

        // The positive control: the pass's own folds are counted under a tally.
        var scout: QueueView.RenderData?
        let built = QueueRenderPass.WorkTally.measure { scout = pass(shows, stage: .scout) }
        let served = try #require(scout)
        #expect(!served.rows.isEmpty, "the fixture put no row in the queue, so nothing below measures a fold")
        #expect(built.wholeQueueFoldRows > 0, Comment(rawValue:
            "building the pass examined no rows under the tally, so the counter is not reached and the "
            + "zero below would mean nothing (L159)"))

        let feed = Phase0cServedFeed(served)
        var window: NSWindow?
        defer { window?.close() }

        // A first draw, then a served change the body must re-run for: two body evaluations at least.
        var first: Phase0cView.Settled?
        let drawing = QueueRenderPass.WorkTally.measure {
            first = Phase0cView.settle(bodyMustRun: true) {
                let w = Phase0cViewRig.host(c, rows: shows, feed: feed, size: NSSize(width: 1000, height: 800))
                window = w
                return w
            }
        }
        let other = pass(shows, stage: .prep)
        var second: Phase0cView.Settled?
        let changing = QueueRenderPass.WorkTally.measure {
            second = Phase0cView.settle(window!, bodyMustRun: true) { feed.data = other }
        }

        let bodies = (first?.bodies ?? 0) + (second?.bodies ?? 0)
        #expect(bodies >= 2, Comment(rawValue:
            "the queue's body ran \(bodies) time(s) over the two readings, so the zero below is a body "
            + "that never ran rather than one that folded nothing"))
        let folded = drawing.wholeQueueFoldRows + changing.wholeQueueFoldRows
        #expect(folded == 0, Comment(rawValue:
            "the queue's body examined \(folded) rows in a whole-queue fold over \(bodies) evaluations of a "
            + "SERVED pass, which derives nothing, so the masthead is folding over the queue again from its "
            + "body. Read the answer the pass published on RenderData instead (#4106, L471)"))
    }
}
