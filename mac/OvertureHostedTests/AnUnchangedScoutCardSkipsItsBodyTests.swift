import Testing
import Foundation
import AppKit
import SwiftUI
import SwiftData
@testable import Overture

// #4322: on Scout, a served change that moves nothing a card draws re-runs no card's body.
//
// THE QUESTION. The date grouped list's cards (`QueueSendAwareRow` into `ProspectRowFactory.row` in
// `QueueView.prospectRow`) are handed a fresh content closure on every evaluation of the queue's body, the
// shape #4320 found re-running every Reached out row (PR #4321). Whether an unchanged CARD skips its body on
// a served change was unpinned, so this measures it, per card, through the real view over a served pass,
// counted and never timed (L63, L224), with the card's own body counter (`QueueRenderCounter.recordCardBody`,
// the first line of `ProspectRowView.body`).
//
// MEASURED on main before the fix (2026-09-29): the served change re-ran the queue's body once and re-ran
// all 6 of 6 drawn cards' bodies. So the fix went in (`ScoutCardInputs`), and this pins both directions: an
// unchanged card skips, and a card whose show changed redraws with its new name while its neighbours skip.
//
// THE POSITIVE CONTROLS, in the same fixture (L159). The first draw ran every drawn card's body, so a zero
// below is a body that was skipped rather than one never counted. And the served change really did re-run
// the queue's body, so the zero is cards that were asked and declined rather than a change nobody drew.
@MainActor
@Suite("An unchanged Scout card skips its body on a served change (#4322)")
final class AnUnchangedScoutCardSkipsItsBodyTests {
    private let now = Date()

    private func night(_ n: Int) -> String {
        EasternDate.dayString(from: Calendar(identifier: .gregorian).date(byAdding: .day, value: 20 + n, to: now)!)
    }

    // Invented names (L155). Untriaged shows on three nights, two on each.
    private func seed(_ ctx: ModelContext) throws -> [Prospect] {
        for n in 0..<6 {
            let p = Prospect(naturalKey: "scout-\(n)", groupName: "Pellowby Ensemble \(n)", discipline: "music",
                             venue: "Ashgrove Hall", performanceDate: night(n / 2), sourceListingURL: nil,
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
        HostedPassCounting.unmountAndClose(window)
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

    private func delta(_ after: [String: Int], _ before: [String: Int], _ keys: [String]) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: keys.map { ($0, (after[$0] ?? 0) - (before[$0] ?? 0)) })
    }

    @Test func aServedChangeThatMovesNothingReRunsNoCardBody() throws {
        let c = try TestModelContainer.inMemory(AppSchema.models)
        let shows = try seed(c.mainContext)
        let served = pass(shows)
        #expect(served.dateGroups.count == 3, "the fixture drew \(served.dateGroups.count) Scout nights, not three")
        let keys = shows.map(\.naturalKey)

        let feed = Phase0cServedFeed(served)
        var window: NSWindow?
        defer { release(window) }
        let beforeFirst = QueueRenderCounter.cardBodyCounts()
        _ = Phase0cView.settle(bodyMustRun: true) {
            let w = Phase0cViewRig.host(c, rows: shows, feed: feed, size: NSSize(width: 1000, height: 2400))
            window = w
            return w
        }
        let firstDraw = delta(QueueRenderCounter.cardBodyCounts(), beforeFirst, keys)
        let drawn = firstDraw.filter { $0.value >= 1 }.map(\.key).sorted()
        #expect(drawn.count >= 2, Comment(rawValue:
            "the first draw ran these card bodies \(firstDraw.sorted { $0.key < $1.key }), so fewer than two "
            + "cards were drawn and the zeros below would mean nothing (L159)"))

        let same = pass(shows)
        let beforeSame = QueueRenderCounter.cardBodyCounts()
        let sameBodies = Phase0cView.settle(window!, bodyMustRun: true) { feed.data = same }.bodies
        let unchanged = delta(QueueRenderCounter.cardBodyCounts(), beforeSame, drawn)
        Swift.print("probe4322 queue bodies \(sameBodies); card bodies re-run over \(drawn.count) drawn cards: "
                    + "\(unchanged.values.reduce(0, +)) (\(unchanged.sorted { $0.key < $1.key }))")
        #expect(sameBodies >= 1, Comment(rawValue:
            "the served change never re-ran the queue's body, so the zeros below are cards nobody asked to redraw"))
        #expect(unchanged.values.allSatisfy { $0 == 0 }, Comment(rawValue:
            "a served change that moved nothing a card draws re-ran these card bodies "
            + "\(unchanged.sorted { $0.key < $1.key }) (#4322, L471)"))

        // The other direction, which is the one that fails silently: a card whose show CHANGED redraws, and
        // draws the new fact, while its neighbours still skip (L14).
        let target = try #require(drawn.first)
        let show = try #require(shows.first { $0.naturalKey == target })
        show.groupName = "Pellowby Ensemble Renamed"
        let changed = pass(shows)
        let beforeChange = QueueRenderCounter.cardBodyCounts()
        _ = Phase0cView.settle(window!, bodyMustRun: true) { feed.data = changed }
        let redrawn = delta(QueueRenderCounter.cardBodyCounts(), beforeChange, drawn)
        #expect((redrawn[target] ?? 0) >= 1, Comment(rawValue:
            "the card whose show was renamed did not redraw, so it still draws the old name (L14)"))
        #expect(QueueRenderCounter.cardDrew(target) == "Pellowby Ensemble Renamed", Comment(rawValue:
            "the renamed card redrew without its new name: it drew '\(QueueRenderCounter.cardDrew(target) ?? "")'"))
        #expect(redrawn.filter { $0.key != target }.values.allSatisfy { $0 == 0 }, Comment(rawValue:
            "renaming one show re-ran these other cards' bodies \(redrawn.sorted { $0.key < $1.key })"))
    }
}
