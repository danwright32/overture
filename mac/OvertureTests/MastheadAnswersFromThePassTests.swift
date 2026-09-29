import Testing
import Foundation
import SwiftData

// #4106 view workstream: the masthead's two whole-queue answers, the high-fit summary and whether a check
// missed any show, are taken ONCE by the render pass and published on RenderData, and the masthead reads
// them there. `TheMastheadFoldsNothingPerBodyTests` (hosted) pins that the body folds nothing; this suite
// pins that moving the answer changed NOTHING about it, and that the fold now asks its cheap date test
// before the geography verdict.
//
// THE EQUALITY is against the function the masthead used to call, with the arguments it used to call it
// with: every queue row, Dan's refusals UNRESOLVED, and the day and instant. The pass answers from its
// own resolved geography, which is a memo of the same pure verdict (#1962), so the two must agree on
// every row, and the fixture holds one row for each way the answer can go (L159): one a check missed,
// one excluded ONLY by geography, one excluded ONLY by the date test (its mark is past the freshness
// window). A positive control shows the comparison can see a wrong set: with the refusal dropped, the
// geography row comes back.
//
// Both ends of every date relationship pinned (L130). Invented names throughout (L155).
@MainActor
@Suite("The masthead's queue answers come from the pass, unchanged (#4106)")
struct MastheadAnswersFromThePassTests {
    private let today = "2026-08-16"
    private var now: Date { EasternDate.date(from: today)!.addingTimeInterval(15 * 3_600) }
    // Dan's refusal of one in-region town, so geography alone decides one row.
    private let geo = GeoRefusals(userExcludedTowns: ["poughkeepsie"])

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func show(_ ctx: ModelContext, _ key: String, location: String, tier: String = "mid",
                      unansweredAt: Date?) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: "Ashgrove \(key)", discipline: "theater",
                         venue: "Wickerlane Playhouse", performanceDate: "2026-10-03",
                         sourceListingURL: nil, priorRelationship: "none", production: "self",
                         profile: "strong", coverage: "likely_uncovered", fitScore: 6, tier: tier,
                         fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil, status: .new)
        p.location = location
        p.reachabilityUnansweredAt = unansweredAt
        ctx.insert(p)
        return p
    }

    private func seed(_ ctx: ModelContext) throws -> [Prospect] {
        let recently = now.addingTimeInterval(-3_600)
        let longAgo = now.addingTimeInterval(-(Reachability.probeFreshness + 86_400))
        show(ctx, "missed", location: "New York, NY", tier: "high", unansweredAt: recently)
        show(ctx, "geography", location: "Poughkeepsie, NY", unansweredAt: recently)
        show(ctx, "stale", location: "New York, NY", unansweredAt: longAgo)
        show(ctx, "never", location: "New York, NY", tier: "high", unansweredAt: nil)
        try ctx.save()
        return try ctx.fetch(FetchDescriptor<Prospect>())
    }

    private func pass(_ rows: [Prospect]) -> QueueView.RenderData {
        QueueRenderPass.make(QueueRenderPass.Inputs(
            allProspects: QueueRenderPass.Corpus(rows), inquiries: [], orgAnswers: [],
            context: .at(today, now: now, geo: geo), focusedStage: .scout))
    }

    // The fixture must reach each branch, or the equality below is vacuous (L159).
    @Test func theFixtureHoldsEveryWayTheAnswerCanGo() throws {
        let data = pass(try seed(try context()))
        let byKey = Dictionary(uniqueKeysWithValues: data.rows.map { ($0.id, $0) })
        #expect(Set(byKey.keys) == ["missed", "geography", "stale", "never"],
                "the pass dropped a fixture row before the fold could see it")
        func missed(_ k: String) -> Bool {
            Reachability.wasMissedByACheck(probedAt: byKey[k]?.reachabilityProbedAt,
                                           unansweredAt: byKey[k]?.reachabilityUnansweredAt, now: now)
        }
        #expect(missed("missed") && missed("geography"))
        #expect(!missed("stale"), "the stale row passes the date test, so nothing is excluded only by date")
        #expect(geo.hidesFromQueue(location: "Poughkeepsie, NY", discipline: .theater))
        #expect(!geo.hidesFromQueue(location: "New York, NY", discipline: .theater))
    }

    @Test func thePassPublishesTheSameMissedSetTheMastheadUsedToDerive() throws {
        let data = pass(try seed(try context()))
        let old = QueueModel.keysMissedByACheck(data.rows, now: now, today: today, geo: geo)
        #expect(data.missedByACheckKeys == old,
                "the pass's missed-by-a-check set differs from the masthead's old derivation")
        #expect(data.missedByACheckKeys == ["missed"])
        // The positive control: the comparison can see a wrong set. Without the refusal the geography
        // row is offered, so a pass that ignored geography would fail the line above.
        let unrefused = QueueModel.keysMissedByACheck(data.rows, now: now, today: today, geo: .none)
        #expect(Set(unrefused) == ["missed", "geography"])
    }

    @Test func thePassPublishesTheSameSummaryTheMastheadUsedToDerive() throws {
        let data = pass(try seed(try context()))
        let old = QueueModel.summary(data.visibleRows)
        #expect(data.summary.total == old.total && data.summary.high == old.high,
                "the pass's summary differs from the masthead's old derivation")
        #expect(old.total > 0 && old.high > 0, "the fixture shows the masthead nothing to count")
    }

    // THE ORDER. The answer is identical whichever test runs first, so only a count can hold it: over
    // the fixture the fold asks for a geography verdict only on the two rows a check really missed.
    @Test func theFoldAsksTheDateTestBeforeTheGeographyVerdict() throws {
        let rows = pass(try seed(try context())).rows
        let work = QueueRenderPass.WorkTally.measure {
            _ = QueueModel.keysMissedByACheck(rows, now: now, today: today, geo: geo)
        }
        #expect(work.wholeQueueFoldRows == rows.count, "the fold's rows were not counted, so the count below is unread")
        #expect(work.candidacyGeographyVerdicts == 2,
                "the fold asked for a geography verdict on a row no check missed; ask Reachability.wasMissedByACheck first (#4106)")
    }
}
