import Testing
import Foundation
import AppKit
import SwiftUI
import SwiftData
@testable import Overture

// #4320: on Reached out, a change to one show redraws that show's row and no other.
//
// WHAT WAS WRONG. Measured with the view attribution probe on the live clone (2026-09-28): a one show
// dismissal on Reached out cost about 27 ms of main thread CPU a reading, and 31% of it (about 8.3 ms) was
// `ReachedOutSendAwareRow` bodies. Every row's wrapper carried a fresh content closure, which SwiftUI can
// never find equal to the last one, so every row's body re-ran on every queue body evaluation and re-read
// its show's and its contact's fields from SwiftData, whether or not anything about that row had changed.
//
// WHAT THIS PINS, three directions, all through the real view over a served pass on the Reached out
// stage (reached the production way, a deep link, `Phase0cViewRig.DeepLinkChannel`):
//
//   1. A served change that moves nothing a row draws re-runs NO row's body. Counted per row, never timed
//      (L63, L224). The positive control is the first draw, where every row's body ran (L159).
//   2. A row whose CONTACT changed still redraws, and draws the new fact. The failure mode of skipping a
//      body is a stale row (L14), so this direction is tested as hard as the saving: one contact's send
//      error is set on the model, and that row, and only that row, must draw the line it produces.
//   3. A row whose drawn time can have moved (the pass's clock crossing a minute) redraws, because nothing
//      in a model says the clock moved. Every row's reach out date is asserted unchanged first, so the
//      redraw is the clock's alone.
@MainActor
@Suite("A Reached out row redraws only when something it draws changed (#4320)")
final class AReachedOutRowRedrawsOnlyWhenItChangesTests {
    private let now = Date()

    private func night(_ n: Int) -> String {
        EasternDate.dayString(from: Calendar(identifier: .gregorian).date(byAdding: .day, value: 20 + n, to: now)!)
    }

    // Invented names and addresses (L155). Shows pitched by email two days ago, so each sits on Reached out
    // with its next nudge still days away.
    private func seed(_ ctx: ModelContext) throws -> (shows: [Prospect], sources: [WatchedSource]) {
        ctx.insert(WatchedSource(sourceId: "src-hollin", orgName: "Hollin Arts",
                                 listingsURL: "https://hollin.example/calendar", kind: .html))
        let sentAt = now.addingTimeInterval(-2 * 86_400)
        for n in 0..<5 {
            let p = Prospect(naturalKey: "pitched-\(n)", groupName: "Marrowby Quartet \(n)",
                             discipline: "music", venue: "Hollin Hall", performanceDate: night(n),
                             sourceListingURL: nil, priorRelationship: "none", production: "self",
                             profile: "strong", coverage: "likely_uncovered", fitScore: 7, tier: "high",
                             fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                             possibleMatchName: nil, status: .contacted)
            p.location = "New York, NY"
            p.sourceIds = ["src-hollin"]
            p.draftSubject = "S"; p.draftBody = "B"
            p.sentAt = sentAt
            ctx.insert(p)
            let r = Recipient(id: "desk\(n)@marrowby.example", email: "desk\(n)@marrowby.example",
                              name: "Desk \(n)", provenance: .presenter)
            r.sendState = .sent
            r.sentAt = sentAt
            r.gmailThreadId = "thread-\(n)"
            r.gmailMessageId = "<m-\(n)>"
            ctx.insert(r)
            p.setRecipients([r])
        }
        try ctx.save()
        return (try ctx.fetch(FetchDescriptor<Prospect>()), try ctx.fetch(FetchDescriptor<WatchedSource>()))
    }

    // For the reason `AStageListDerivesNothingPerBodyTests.release` gives: the deep link arms a 2.5 s
    // highlight timer, and the host dies in the NEXT test's save if anything here still observes (#3874).
    private func release(_ window: NSWindow?) {
        HostedPassCounting.unmountAndClose(window)
        turnTheRunLoop(seconds: 3)
    }

    private func turnTheRunLoop(seconds: Double) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            autoreleasepool { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        }
    }

    private func pass(_ t: (shows: [Prospect], sources: [WatchedSource]), at instant: Date) -> QueueView.RenderData {
        QueueRenderPass.make(QueueRenderPass.Inputs(
            allProspects: QueueRenderPass.Corpus(t.shows), inquiries: [], orgAnswers: [],
            sources: t.sources, context: StageContext(now: instant, geo: .none, clients: .none),
            focusedStage: .reachedOut))
    }

    private func rowBodies() -> [String: Int] { QueueRenderCounter.reachedOutRowBodyCounts() }

    private func delta(_ after: [String: Int], _ before: [String: Int], _ keys: [String]) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: keys.map { ($0, (after[$0] ?? 0) - (before[$0] ?? 0)) })
    }

    @Test func aRowRedrawsOnlyForAChangeToWhatItDraws() throws {
        let c = try TestModelContainer.inMemory(AppSchema.models)
        let t = try seed(c.mainContext)
        let served = pass(t, at: now)
        let keys = served.reachedOut.map(\.prospect.naturalKey)
        #expect(keys.count == 5, "the fixture put \(keys.count) shows on Reached out, not five")
        let target = try #require(keys.first)

        let feed = Phase0cServedFeed(served)
        let link = Phase0cViewRig.DeepLinkChannel()
        var window: NSWindow?
        defer { release(window) }
        _ = Phase0cView.settle(bodyMustRun: true) {
            let w = Phase0cViewRig.host(c, rows: t.shows, feed: feed, size: NSSize(width: 1000, height: 1400),
                                        link: link)
            window = w
            return w
        }
        let beforeLink = rowBodies()
        _ = Phase0cView.settle(window!, bodyMustRun: true) { link.key = LeadDeepLink(key: target) }
        let firstDraw = delta(rowBodies(), beforeLink, keys)
        // The positive control: on the first draw of the stage every row's body ran, so the counter is
        // reached for each of them and a zero below is a body that was skipped, not one never counted.
        #expect(firstDraw.values.allSatisfy { $0 >= 1 }, Comment(rawValue:
            "the first draw of Reached out ran these row bodies \(firstDraw.sorted { $0.key < $1.key }), so "
            + "some row was never drawn and the zeros below would mean nothing (L159)"))

        // The jump's gold mark clears itself after 2.5 s, and every row reads which row is marked, so it is
        // waited out here: a mark clearing mid reading would redraw every row for a reason none of the three
        // readings below is about.
        _ = Phase0cView.settle(window!, bodyMustRun: false) { turnTheRunLoop(seconds: 3) }

        // 1. A served change that moves nothing any row draws.
        let same = pass(t, at: now)
        let beforeSame = rowBodies()
        let listBefore = QueueRenderCounter.stageListBodyCount(QueueRenderCounter.reachedOutList)
        let sameBodies = Phase0cView.settle(window!, bodyMustRun: true) { feed.data = same }.bodies
        let listDrawn = QueueRenderCounter.stageListBodyCount(QueueRenderCounter.reachedOutList) - listBefore
        let unchanged = delta(rowBodies(), beforeSame, keys)
        #expect(sameBodies >= 1 && listDrawn >= 1, Comment(rawValue:
            "the queue's body ran \(sameBodies) time(s) and drew the Reached out list \(listDrawn) time(s), so "
            + "the zeros below are rows that were never asked to redraw rather than rows that declined"))
        #expect(unchanged.values.allSatisfy { $0 == 0 }, Comment(rawValue:
            "a served change that moved nothing a row draws re-ran these row bodies "
            + "\(unchanged.sorted { $0.key < $1.key }), each re-reading its show and contact from the store "
            + "(#4320, L471)"))

        // 2. One contact changes on the model, and only its row redraws, with the new fact.
        let recipient = try #require(t.shows.first { $0.naturalKey == target }?.recipients.first)
        let beforeEdit = rowBodies()
        _ = Phase0cView.settle(window!, bodyMustRun: false) { recipient.sendError = "mailbox full" }
        let edited = delta(rowBodies(), beforeEdit, keys)
        #expect((edited[target] ?? 0) >= 1, Comment(rawValue:
            "the row whose contact changed did not redraw, so it is still drawing the old contact (L14)"))
        let drew = QueueRenderCounter.reachedOutRowDrew(target) ?? ""
        #expect(drew.contains("Send failed: mailbox full"), Comment(rawValue:
            "the row whose contact changed redrew without the new fact: it drew '\(drew)' (L14)"))
        #expect(edited.filter { $0.key != target }.values.allSatisfy { $0 == 0 }, Comment(rawValue:
            "one contact's change re-ran these other rows' bodies \(edited.sorted { $0.key < $1.key })"))

        // 3. The pass's clock crosses a minute, and nothing else a row draws moves.
        let later = pass(t, at: now.addingTimeInterval(120))
        let nextBefore = served.reachedOut.map(\.next), nextAfter = later.reachedOut.map(\.next)
        #expect(nextBefore == nextAfter, "the later pass moved a reach out date, so a redraw would not be the clock's alone")
        let beforeClock = rowBodies()
        _ = Phase0cView.settle(window!, bodyMustRun: true) { feed.data = later }
        let clocked = delta(rowBodies(), beforeClock, keys)
        #expect(clocked.values.allSatisfy { $0 >= 1 }, Comment(rawValue:
            "the pass's clock moved two minutes and these rows did not redraw "
            + "\(clocked.sorted { $0.key < $1.key }), so a row's due label and countdown would go stale"))
    }
}
