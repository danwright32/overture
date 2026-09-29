import Testing
import Foundation
import AppKit
import SwiftUI
import SwiftData
@testable import Overture

// #4317: a Scout date heading asks no geography verdict in its body.
//
// WHAT WAS WRONG. `QueueView.dateSection` asked `QueueModel.probeKeysForTickedDate(group.items, geo: geo)`
// for its tick box and handed the group's rows to `ReachabilityProbeControl`, whose body asked the
// candidacy rule twice more, for every date group the lazy stack realised, on every body evaluation, with
// `geo` the view's computed property: a fresh, UNRESOLVED `GeoRefusals` per read, so each verdict could
// parse a place string. A body runs on events that change no data (L471). The same class #4106 removed
// from the masthead and #4311 from the stage lists, one level down.
//
// WHAT THIS PINS. Over a SERVED pass the body derives nothing, so any geography verdict the candidacy rule
// records while the queue draws is the BODY's work, and the count must be zero. Counted, never timed (L63,
// L224).
//
// THE POSITIVE CONTROLS, in the same fixture (L159). Building the pass itself records verdicts, so the
// counter is live under this tally. And each date heading records that it was drawn, so a zero is a set of
// headings that were DRAWN and asked nothing, never a list the view did not reach.
@MainActor
@Suite("A date heading asks no geography verdict per body (#4317)")
final class ADateHeadingAsksNoGeographyPerBodyTests {
    private let now = Date()

    private func night(_ n: Int) -> String {
        EasternDate.dayString(from: Calendar(identifier: .gregorian).date(byAdding: .day, value: 20 + n, to: now)!)
    }

    // Invented names (L155). Untriaged shows on four nights, two on each, somewhere Dan travels, so every
    // heading is one a check could still be about and the candidacy rule reaches its geography verdict.
    private func seed(_ ctx: ModelContext) throws -> [Prospect] {
        for n in 0..<8 {
            let p = Prospect(naturalKey: "scout-\(n)", groupName: "Tamberlin Consort \(n)", discipline: "music",
                             venue: "Oakhollow Hall", performanceDate: night(n / 2), sourceListingURL: nil,
                             priorRelationship: "none", production: "self", profile: "strong",
                             coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                             matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                             status: .new)
            p.location = "New York, NY"
            ctx.insert(p)
        }
        try ctx.save()
        return try ctx.fetch(FetchDescriptor<Prospect>())
    }

    // For the reason `AStageListDerivesNothingPerBodyTests.release` gives (#3874's signature, L86).
    private func release(_ window: NSWindow?) {
        window?.close()
        let until = Date().addingTimeInterval(1)
        while Date() < until {
            autoreleasepool { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        }
    }

    private func pass(_ shows: [Prospect]) -> QueueView.RenderData {
        QueueRenderPass.make(QueueRenderPass.Inputs(
            allProspects: QueueRenderPass.Corpus(shows), inquiries: [], orgAnswers: [],
            context: StageContext(now: now, geo: .none, clients: .none), focusedStage: .scout))
    }

    @Test func aDrawnDateHeadingAsksNoGeographyVerdict() throws {
        let c = try TestModelContainer.inMemory(AppSchema.models)
        let shows = try seed(c.mainContext)

        var scout: QueueView.RenderData?
        let built = QueueRenderPass.WorkTally.measure { scout = pass(shows) }
        let served = try #require(scout)
        #expect(served.dateGroups.count == 4, "the fixture drew \(served.dateGroups.count) Scout nights, not four")
        #expect(built.candidacyGeographyVerdicts > 0, Comment(rawValue:
            "building the Scout pass asked no geography verdict under the tally, so the counter is not reached "
            + "and the zero below would mean nothing (L159)"))

        let feed = Phase0cServedFeed(served)
        var window: NSWindow?
        defer { release(window) }
        let other = pass(shows)
        let before = QueueRenderCounter.stageListBodyCount(QueueRenderCounter.dateHeading)
        var bodies = 0
        let drawing = QueueRenderPass.WorkTally.measure {
            bodies += Phase0cView.settle(bodyMustRun: true) {
                let w = Phase0cViewRig.host(c, rows: shows, feed: feed, size: NSSize(width: 1000, height: 800))
                window = w
                return w
            }.bodies
            bodies += Phase0cView.settle(window!, bodyMustRun: true) { feed.data = other }.bodies
        }
        let drawn = QueueRenderCounter.stageListBodyCount(QueueRenderCounter.dateHeading) - before
        #expect(bodies >= 2 && drawn >= 2, Comment(rawValue:
            "the queue's body ran \(bodies) time(s) and drew \(drawn) date heading(s), so the zero below is a "
            + "list that was never drawn rather than one that asked nothing"))
        #expect(drawing.candidacyGeographyVerdicts == 0, Comment(rawValue:
            "drawing \(drawn) Scout date headings over a SERVED pass asked \(drawing.candidacyGeographyVerdicts) "
            + "geography verdicts, which the pass had already answered. Read `RenderData.dateProbeHeadings` "
            + "instead (#4317, L471)"))
    }
}
