import Testing
import Foundation
import SwiftData

// #4121: the probe selection bar's rows are a PROJECTION of the placement the pass already decided, not
// a second placement of the whole queue.
//
// WHAT WAS MEASURED. Dan ticked several nights for a reachability check and the window froze: 0.97s,
// 0.94s and 0.60s stalls at 20:51:12 to 20:51:14Z on 2026-09-21, on a quiet Mac (load 4.1). In the two
// kept samples `ProbeSelectionBar.body` carried 7.1% then 7.6%, effectively all of it under
// `summaryAndKeys`, and beneath that `QueueView.scoutRows` 5.6% then 6.2%, `StageNavigation.placements`
// 5.5% then 6.1%, `StageNavigation.matches` 4.6% then 5.4%, `GeoRefusals.hidesFromQueue` 4.3%.
//
// WHY IT RAN AT ALL. `summaryAndKeys` is a computed property read from a body, so from the first tick
// onwards it runs on EVERY render pass, and its `rows` argument was a closure calling
// `QueueView.scoutRows(data)`, which called `StageNavigation.focusedKeys(stage:leadKeys:in:context:)`,
// the overload that DECIDES every show's stages from scratch. #3738 had already taken that question to
// once per pass inside `QueueRenderPass.make`; this call site asked it a second time, from outside the
// pass where the counter #3738 installed could see it but nobody was reading it.
//
// COUNTED, NEVER TIMED, for #3738's own reason: a call count reads 1 whether the callee decides every
// show's stages or reads a table it was handed, so it is the same number for the defect and for the fix
// (L63). What is asserted here is `stagePlacements`, the counter `StageNavigation.placements` records at
// the one place a placement is built.
//
// AND THE ANSWER MUST NOT MOVE, which is the other half and the one a cost assertion cannot see. Reading
// the pass's table also means reading the pass's CONTEXT, and the two differed: the old route built
// `StageContext(geo: geo, clients: clientWindow)` with `now` defaulted to a fresh `Date()` and the
// geography UNRESOLVED, while the pass's context carries its own instant and `geo.resolving(...)`.
// `GeoRefusals.resolving` is a memo of a pure function of exactly the two town sets, and `==` on
// `GeoRefusals` ignores the table for that reason, so the verdicts are identical and the clock is now one
// instant per pass rather than two. `theProjectionIsTheSameAnswer` below pins that rather than leaving it
// to this paragraph (L70).
@MainActor
@Suite("The probe bar's rows come from the pass's own placement (#4121)")
struct ScoutRowsReadThePassesPlacementTests {
    private static let corpusSize = 40
    private static let instant = Date(timeIntervalSince1970: 4_070_908_800)

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    // Spread across several stages, so a projection that returned EVERY row and one that returns the
    // scoutable ones are distinguishable. A corpus that all lands in one focus could not tell them apart.
    private func seed(_ ctx: ModelContext) -> [Prospect] {
        var out: [Prospect] = []
        for n in 0..<Self.corpusSize {
            let p = Prospect(naturalKey: "k\(n)", groupName: "Show \(n)", discipline: "choral",
                             venue: "Room \(n % 5)",
                             performanceDate: "2099-01-\(String(format: "%02d", n % 28 + 1))",
                             sourceListingURL: nil, priorRelationship: "none", production: "self",
                             profile: "strong", coverage: "likely_uncovered",
                             fitScore: n % 10, tier: "mid", fitReason: "r",
                             matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
            switch n % 4 {
            case 1: p.status = .queued
            case 2: p.status = .drafted
            case 3: p.status = .approved
            default: p.status = .new
            }
            ctx.insert(p)
            out.append(p)
        }
        return out
    }

    private func context() -> StageContext {
        StageContext(now: Self.instant, geo: .none, clients: .none)
    }

    private func inputs(_ rows: [Prospect]) -> QueueRenderPass.Inputs {
        QueueRenderPass.Inputs(
            allProspects: QueueRenderPass.Corpus(rows), inquiries: [], orgAnswers: [],
            context: context(), focusedStage: .scout)
    }

    // THE POSITIVE CONTROL, first, because the claim below is a zero and a zero proves nothing until the
    // instrument has been seen to produce a one (L159, L98). This is the route the bar used to take.
    @Test("deciding the scoutable rows the old way places the whole corpus, so a zero below is measured")
    func theOldRoutePlacesOnce() throws {
        let ctx = ModelContext(try container())
        let shows = seed(ctx)
        let work = QueueRenderPass.WorkTally.measure {
            _ = StageNavigation.focusedKeys(stage: .scout, leadKeys: [], in: shows, context: context())
        }
        #expect(work.stagePlacements == 1, Comment(rawValue:
            "the old route recorded \(work.stagePlacements) placements, so `stagePlacements` is not "
            + "measuring what this suite thinks it measures"))
    }

    // THE ONE THAT MATTERS.
    @Test("projecting the scoutable rows from a finished pass decides no show's stages again")
    func theProjectionPlacesNothing() throws {
        let ctx = ModelContext(try container())
        let shows = seed(ctx)
        let data = QueueRenderPass.make(inputs(shows))

        let work = QueueRenderPass.WorkTally.measure { _ = data.scoutRows() }

        #expect(work.stagePlacements == 0, Comment(rawValue:
            "asking a finished pass for its scoutable rows decided every show's stages "
            + "\(work.stagePlacements) more times. `summaryAndKeys` reads this on every render pass "
            + "from the first tick onwards, so the whole queue is re-placed per pass while Dan chooses "
            + "nights (#4121)"))
    }

    // The floor. A projection that returned nothing would satisfy the count above and say nothing, and a
    // projection that returned everything would be a different defect (L98, L11).
    @Test("the projection really does return the scoutable rows, and not all of them")
    func theProjectionIsNeitherEmptyNorEverything() throws {
        let ctx = ModelContext(try container())
        let shows = seed(ctx)
        let data = QueueRenderPass.make(inputs(shows))

        let scoutable = data.scoutRows()
        #expect(!scoutable.isEmpty, Comment(rawValue:
            "the projection returned no rows at all, so the cost assertion above is measuring nothing"))
        #expect(scoutable.count < data.rows.count, Comment(rawValue:
            "the projection returned every row in scope (\(scoutable.count) of \(data.rows.count)), so "
            + "it is not filtering to the scoutable ones"))
    }

    // And it is the SAME answer the old route gave, which is what makes reading the pass's table a
    // consolidation rather than a second, cheaper opinion (L70, L263).
    @Test("the projection is the same answer the old route gave")
    func theProjectionIsTheSameAnswer() throws {
        let ctx = ModelContext(try container())
        let shows = seed(ctx)
        let data = QueueRenderPass.make(inputs(shows))

        let oldWanted = Set(StageNavigation.focusedKeys(stage: .scout, leadKeys: [], in: shows,
                                                        context: context()))
        let oldRows = data.rows.filter { oldWanted.contains($0.id) }

        #expect(data.scoutRows().map(\.id) == oldRows.map(\.id), Comment(rawValue:
            "the projection and the old whole-corpus placement disagree about which rows are scoutable, "
            + "so this change moves the answer rather than only its cost"))
    }

    // The placement the projection reads was built over the corpus the pass was given, so a pass that
    // stopped placing anything cannot answer every question with silence (L98).
    @Test("the pass carries a placement over the whole corpus it was given")
    func thePassCarriesItsPlacement() throws {
        let ctx = ModelContext(try container())
        let shows = seed(ctx)
        let data = QueueRenderPass.make(inputs(shows))
        #expect(data.placement.count == Self.corpusSize, Comment(rawValue:
            "the pass's placement covers \(data.placement.count) shows of \(Self.corpusSize)"))
    }
}
