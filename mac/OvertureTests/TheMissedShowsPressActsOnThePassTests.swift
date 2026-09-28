import Testing
import Foundation
import SwiftData

// #4312: "Check the rest" runs the set the masthead OFFERED, never a second derivation of it.
//
// WHAT WAS WRONG. Since #4106 the masthead decides whether to offer the control from the render pass's own
// answer, `RenderData.missedByACheckKeys`. The press did not read that answer: it derived the set again
// through `QueueView.items`, the whole store built as full cards, at its own instant, its own day and Dan's
// refusals unresolved. So the offer he saw and the run it started were two answers to one question (L16),
// and the press paid a whole-store card build to get the second one.
//
// WHAT THIS PINS. The served notice CARRIES the pass's set, the same way `showShowsOneSweepBroke(keys:)`
// carries its rows, and the confirm the press raises is built from exactly those keys and builds no card
// and folds no row to do it. Counted, never timed (L63, L224).
//
// THE POSITIVE CONTROL is in the same fixture (L159): the old route, the whole store built as cards and then
// folded, moves the same counters under the same tally, so a zero below is a press that did no work rather
// than counters nobody reaches.
//
// Both ends of every date relationship pinned (L130). Invented names throughout (L155).
@MainActor
@Suite("Finishing the shows a check missed runs the set the masthead offered (#4312)")
struct TheMissedShowsPressActsOnThePassTests {
    private let today = "2026-08-16"
    private var now: Date { EasternDate.date(from: today)!.addingTimeInterval(15 * 3_600) }
    private let geo = GeoRefusals(userExcludedTowns: ["poughkeepsie"])

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private func show(_ ctx: ModelContext, _ key: String, location: String, unansweredAt: Date?) {
        let p = Prospect(naturalKey: key, groupName: "Brackenmoor \(key)", discipline: "theater",
                         venue: "Quillhaven Playhouse", performanceDate: "2026-10-03",
                         sourceListingURL: nil, priorRelationship: "none", production: "self",
                         profile: "strong", coverage: "likely_uncovered", fitScore: 6, tier: "mid",
                         fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil, status: .new)
        p.location = location
        p.reachabilityUnansweredAt = unansweredAt
        ctx.insert(p)
    }

    // Two shows a check missed, one excluded by geography alone, and one no check touched, so the set is
    // neither empty nor everything.
    private func seed(_ ctx: ModelContext) throws -> [Prospect] {
        let recently = now.addingTimeInterval(-3_600)
        show(ctx, "missed-a", location: "New York, NY", unansweredAt: recently)
        show(ctx, "missed-b", location: "Brooklyn, NY", unansweredAt: recently)
        show(ctx, "geography", location: "Poughkeepsie, NY", unansweredAt: recently)
        show(ctx, "never", location: "New York, NY", unansweredAt: nil)
        try ctx.save()
        return try ctx.fetch(FetchDescriptor<Prospect>())
    }

    private func pass(_ rows: [Prospect]) -> QueueView.RenderData {
        QueueRenderPass.make(QueueRenderPass.Inputs(
            allProspects: QueueRenderPass.Corpus(rows), inquiries: [], orgAnswers: [],
            context: .at(today, now: now, geo: geo), focusedStage: .scout))
    }

    // What RootView writes when a check comes home short: the REQUEST, which names no rows because the
    // writer of the report has none.
    private var request: AppNotice {
        AppNotice(text: "Reachability: 2 of 9 shows never got an answer", tone: .warning,
                  action: .finishShowsACheckMissed)
    }

    @Test func thePressRunsExactlyTheSetTheMastheadOffered() throws {
        let rows = try seed(try context())
        let data = pass(rows)
        #expect(Set(data.missedByACheckKeys) == ["missed-a", "missed-b"],
                "the fixture's pass does not hold the two missed shows, so the equality below is vacuous")

        let served = AppNotices.servable([request], missedByACheckKeys: data.missedByACheckKeys)
        guard case .finishTheseShowsACheckMissed(let offered)? = served.first?.action else {
            Issue.record("the served offer does not carry a set of shows, so the press has to derive one")
            return
        }
        #expect(offered == data.missedByACheckKeys,
                "the offer carries a different set from the one the pass published for the masthead")

        var confirm: ProbeConfirm?
        let press = QueueRenderPass.WorkTally.measure {
            confirm = ProbeConfirm.finishingShowsACheckMissed(keys: offered, secondsPerRound: 30)
        }
        #expect(confirm?.keys == data.missedByACheckKeys,
                "the confirm the press raises runs a different set from the one the masthead offered")
        #expect(press.queueItems == 0 && press.queueRows == 0 && press.wholeQueueFoldRows == 0,
                Comment(rawValue: "the press built \(press.queueItems) cards and \(press.queueRows) rows and "
                        + "folded \(press.wholeQueueFoldRows) rows; it must read the offer's keys (#4312, L383)"))

        // The positive control: the route the press used to take moves these counters under a tally.
        let old = QueueRenderPass.WorkTally.measure {
            _ = QueueModel.keysMissedByACheck(QueueModel.items(from: rows, now: now), now: now,
                                              today: today, geo: geo)
        }
        #expect(old.queueItems > 0 && old.wholeQueueFoldRows > 0, Comment(rawValue:
            "the old press route counted no cards or folds, so the zeros above would mean nothing (L159)"))
    }

    // With nothing left to finish there is no offer at all: the sentence stays, the control goes (L44).
    @Test func nothingLeftToFinishOffersNoControl() {
        let served = AppNotices.servable([request], missedByACheckKeys: [])
        #expect(served.first?.action == nil)
        #expect(served.first?.text == request.text)
        #expect(ProbeConfirm.finishingShowsACheckMissed(keys: [], secondsPerRound: 30) == nil,
                "a confirm over no shows would start a paid run over nobody")
    }

    // Every other action passes through untouched, so this rule can never disarm an unrelated control.
    @Test func anotherActionIsNeverRewritten() {
        let other = AppNotice(text: "OmniFocus sync failing", tone: .warning, action: .retryOmniFocusSync)
        #expect(AppNotices.servable([other], missedByACheckKeys: ["missed-a"]).first?.action == .retryOmniFocusSync)
        #expect(AppNotices.servable([other], missedByACheckKeys: []).first?.action == .retryOmniFocusSync)
    }

    // The view's half, which no value test can reach: the press is HANDED the keys and derives none. A
    // source guard because the press lives on a private function of a SwiftUI view.
    @Test func thePressInTheQueueIsHandedTheKeysAndDerivesNone() throws {
        let file = SourceGuardHelper.source("Overture/UI/QueueView.swift")
        let body = try #require(SourceGuardHelper.bodyOfFunction(named: "finishShowsACheckMissed", in: file),
                                "QueueView.finishShowsACheckMissed is gone, so this guard asks nothing")
        let code = SourceGuardHelper.normalizedCode(body)
        #expect(!code.contains("keysMissedByACheck"),
                "the press derives the missed set again rather than running the one the offer carries")
        #expect(!code.contains("items"),
                "the press reads the whole-store cards again rather than the offer's keys (#4312)")
        #expect(SourceGuardHelper.containsCode("func finishShowsACheckMissed(_ keys: [String])", in: file))
        #expect(SourceGuardHelper.containsCode("case .finishTheseShowsACheckMissed(let keys) = action", in: file),
                "the queue no longer performs the served offer with the keys it carries")
    }
}
