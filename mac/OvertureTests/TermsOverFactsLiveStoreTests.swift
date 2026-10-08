import Testing
import Foundation
import SwiftData

// #4357 (plan v7 Phase 3 step 3, oracle part two on real data): every ported queue term, over a clone of
// Dan's live store and over its fourfold copy, answers the same over the live models as over the same rows
// extracted to `RowFacts`. A LIVE STORE TEST, so it gates every merge, as the plan asks.
//
// WHY REAL DATA AS WELL AS THE FIXTURES. A fixture only holds the field shapes its author thought of, and an
// extraction fault is exactly a field shape nobody thought of: a nil where a fixture always sets a value, a
// dropped night entry in its self describing form, a scout title that differs from the display one. The
// clone holds every shape the app has actually written, and the 4x copy holds them at the size the plan
// budgets for.
//
// UNLIKE `FeedBreakEventLiveStoreTests`, THIS ASSERTS. That suite reports because a venue's website changing
// must not block a merge (L68). Nothing in the DATA can make the two arms here disagree: they read the same
// rows through the same term code, so a difference is always a fault in the code between a model and its
// value, and it should stop a merge. The findings name a term, a field and a row's identifier, never a title.
//
// SKIPPED, never red, on a machine with no live store (L411), through the one shared presence check.
@MainActor
@Suite("Every ported queue term answers the same over facts as over models on the live store (#4357)")
final class TermsOverFactsLiveStoreTests {
    private let sandboxes = TemporarySandboxes()

    @Test(.enabled(if: LiveStorePresence.exists, LiveStorePresence.absenceReason))
    func theCloneAndItsFourfoldCopyAnswerTheSameOverFactsAsOverModels() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let dir = try sandboxes.make(named: "terms-over-facts")
            guard let base = try LiveStoreClone.makeClone(in: dir) else {
                throw LiveStoreClone.Refusal.backupFailed("no live store on this machine")
            }
            let corpora = [("live clone", base), ("4x", try Phase0.scaledCopy(of: base, factor: 4, in: dir))]
            let asOf = EasternDate.today(Date())
            for (label, url) in corpora {
                let container = try Phase0.openContainer(at: url)
                let context = ModelContext(container)
                let models = try context.fetch(FetchDescriptor<Prospect>())
                // An empty read is a failed open, never a clean bill of health (L98).
                #expect(!models.isEmpty, "the \(label) holds no shows, so nothing below compared anything")
                let drawn = Set(QueueModel.queueScope(models).map(\.naturalKey))
                // T4 and T5 read Dan's producer corrections, the stored organisation answers and the
                // struck addresses, from the same clone. The ledger is judged at the NEWEST answer's
                // instant rather than today's: at today's clock every answer older than the freshness
                // window drops out before a row is read, and the comparison would be two empty tables
                // that agree for that reason alone (L159). Today's count is printed beside it.
                let answers = try context.fetch(FetchDescriptor<OrgReachabilityAnswer>())
                let overrides = ProducerOverrideEditing.overrides(in: context)
                let ledger = TermsOverFacts.Ledger(answers: answers, refusals: ContactRefusal.ledger(in: context),
                                                   now: answers.map(\.probedAt).max() ?? Date())
                let started = Phase0.now()
                let findings = TermsOverFacts.findings(models, asOf: asOf, drawn: drawn,
                                                     rowByRow: label == "live clone",
                                                     overrides: overrides, ledger: ledger)
                let elapsed = Phase0.ms(since: started)
                let flagged = models.filter(\.disappearedFromFeed).count
                func inheritedCount(at instant: Date) -> Int {
                    QueueModel.inheritedAnswers(answers, corpus: models, overrides: overrides,
                                                refusals: ledger.refusals, heldKeys: [], now: instant).count
                }
                print("terms over facts, \(label): \(models.count) row(s), \(flagged) flagged, "
                      + "\(drawn.count) drawn, \(answers.count) answer(s), "
                      + "\(inheritedCount(at: ledger.now)) inherited at the newest answer, "
                      + "\(inheritedCount(at: Date())) today, \(findings.count) finding(s), "
                      + String(format: "%.0f ms", elapsed))
                #expect(findings.isEmpty, Comment(rawValue: "\(label):\n" + findings.prefix(20).joined(separator: "\n")))
            }
            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }
}

// #4358 slice E4a (oracle part two for the WHOLE pass, on real data): `QueueRenderPass.make` over the clone's live
// models answers what it answers over the same store as the engine will hold it (every show extracted, every
// inquiry, answer and source as its record), member by member through the RenderData comparator. A LIVE STORE
// TEST, read only on a clone, so it gates every merge as plan item 14 asks: nothing in the DATA can make the two
// arms differ, since both run the one generic pass, so a finding is a fault between a model and its value. The
// clone at every stage with every card built; the 4x copy at three stages with a sample of cards, the size the
// plan budgets for. Findings name a stage and a member, never a title (L222).
@MainActor
@Suite("The whole queue pass answers the same over facts as over models on the live store (#4358)")
final class WholePassOverFactsLiveStoreTests {
    private let sandboxes = TemporarySandboxes()

    @Test(.enabled(if: LiveStorePresence.exists, LiveStorePresence.absenceReason))
    func theCloneAndItsFourfoldCopyPassTheSameOverFactsAsOverModels() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let dir = try sandboxes.make(named: "whole-pass-over-facts")
            guard let base = try LiveStoreClone.makeClone(in: dir) else {
                throw LiveStoreClone.Refusal.backupFailed("no live store on this machine")
            }
            let corpora = [("live clone", base), ("4x", try Phase0.scaledCopy(of: base, factor: 4, in: dir))]
            for (label, url) in corpora {
                let container = try Phase0.openContainer(at: url)
                let ctx = ModelContext(container)
                let shows = try ctx.fetch(FetchDescriptor<Prospect>())
                // An empty read is a failed open, never a clean bill of health (L98).
                #expect(!shows.isEmpty, "the \(label) holds no shows, so nothing below compared anything")
                let store = TermsOverFacts.PassStore(
                    shows: shows, inquiries: try ctx.fetch(FetchDescriptor<Inquiry>()),
                    answers: try ctx.fetch(FetchDescriptor<OrgReachabilityAnswer>()),
                    sources: try ctx.fetch(FetchDescriptor<WatchedSource>()),
                    refusals: ContactRefusal.ledger(in: ctx), overrides: ProducerOverrideEditing.overrides(in: ctx))
                let geo = GeoRefusals(
                    userExcludedTowns: Set(try ctx.fetch(FetchDescriptor<ExcludedTown>()).map(\.town)),
                    allowedSeedTowns: Set(try ctx.fetch(FetchDescriptor<AllowedSeedTown>()).map(\.town)))
                let context = StageContext(now: Date(), geo: geo, clients: .none)
                let wholeClone = label == "live clone"
                let focuses: [StageFocus?] = wholeClone ? StageFocus.allCases.map { $0 } + [nil]
                                                        : [.scout, .review, .reachedOut]
                let cards: Set<String>? = wholeClone
                    ? nil : Set(QueueModel.queueScope(shows).prefix(60).map(\.naturalKey))
                let started = Phase0.now()
                let (findings, passes) = TermsOverFacts.wholePassFindings(store, context: context, focuses: focuses,
                                                                          cards: cards)
                print("whole pass over facts, \(label): \(shows.count) show(s), \(store.inquiries.count) inquiry(s), "
                      + "\(store.answers.count) answer(s), \(store.sources.count) source(s), \(passes.count) stage(s), "
                      + "\(passes.first?.cards.builtCount ?? 0) card(s) on the first, \(findings.count) finding(s), "
                      + String(format: "%.0f ms", Phase0.ms(since: started)))
                #expect(passes.contains { !$0.rows.isEmpty }, "no pass over the \(label) built a row")
                #expect(findings.isEmpty, Comment(rawValue: "\(label):\n" + findings.joined(separator: "\n")))
            }
            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }
}

// #4358 slice E4a: what the queue's MEMO PATH derivation costs on the live clone and on its fourfold copy, so a
// change to `QueueRenderPass.make` is priced against main rather than argued (the milestone's "no slower" rule).
// The pass is handed what `QueueView.makeRenderData` hands it on a memo miss: every table read from the clone,
// the opening stage, a viewport of requested cards, and producer tables already built (the view keeps them in
// a memo of their own, so a pass pays nothing for them). Opt in, because it times rather than asserts; it says
// so when it is not asked rather than passing in silence (L98).
//
// ONE RUN IS ONE SIDE, AND IS NEVER A VERDICT (#4615). Before and after go through the comparison script, which
// runs them in alternating ABBA rounds and reports pooled medians per side beside the order effect:
//
//   scripts/compare-before-after.sh --before <main plus this probe> --after <the branch> \
//     --scope '-only-testing:OvertureTests/MemoPathDerivationCostProbeTests' \
//     --env TEST_RUNNER_MEASURE_4358_E4A=1 --rounds 4
//
// because two runs back to back under the shared test lock read the SECOND one slower: about 32 ms at 4x in all
// six of #4614's rounds, so a single before then after pair reads a change as a regression or hides one. The
// script refuses a verdict (UNMEASURED) from one round. Each reading prints a `probe reading:` line for it.
@MainActor
@Suite("What the queue's memo path derivation costs on the live clone and at 4x (#4358 E4a)")
final class MemoPathDerivationCostProbeTests {
    private let sandboxes = TemporarySandboxes()
    private static let samples = 7

    @Test(.enabled(if: LiveStorePresence.exists, LiveStorePresence.absenceReason))
    func measureTheMemoPathDerivation() async throws {
        guard ProcessInfo.processInfo.environment["MEASURE_4358_E4A"] != nil else {
            print("e4a memo derivation: not measured. Set TEST_RUNNER_MEASURE_4358_E4A=1 to run it.")
            return
        }
        await RealStoreTestLock.shared.acquire()
        do {
            let dir = try sandboxes.make(named: "e4a-memo-cost")
            guard let base = try LiveStoreClone.makeClone(in: dir) else {
                throw LiveStoreClone.Refusal.backupFailed("no live store on this machine")
            }
            for (label, url) in [("1x", base), ("4x", try Phase0.scaledCopy(of: base, factor: 4, in: dir))] {
                let container = try Phase0.openContainer(at: url)
                let ctx = ModelContext(container)
                let shows = try ctx.fetch(FetchDescriptor<Prospect>())
                #expect(!shows.isEmpty, "the \(label) corpus holds no shows, so nothing was timed")
                let inquiries = try ctx.fetch(FetchDescriptor<Inquiry>())
                let answers = try ctx.fetch(FetchDescriptor<OrgReachabilityAnswer>())
                let sources = try ctx.fetch(FetchDescriptor<WatchedSource>())
                let refused = try ctx.fetch(FetchDescriptor<RefusedContactAddress>())
                let overrides = ProducerOverrides(promotedRows: try ctx.fetch(FetchDescriptor<PromotedProducer>()),
                                                  demotedRows: try ctx.fetch(FetchDescriptor<DemotedHouse>()))
                let geo = GeoRefusals(
                    userExcludedTowns: Set(try ctx.fetch(FetchDescriptor<ExcludedTown>()).map(\.town)),
                    allowedSeedTowns: Set(try ctx.fetch(FetchDescriptor<AllowedSeedTown>()).map(\.town)))
                let tables = QueueModel.ProducerTables(shows: shows.map(ProducerGate.Show.init), overrides: overrides)
                let now = Date()
                func inputs(cards: Set<String>?) -> QueueRenderPass.Inputs {
                    QueueRenderPass.Inputs(allProspects: QueueRenderPass.Corpus(shows), inquiries: inquiries,
                                           orgAnswers: answers, sources: sources,
                                           refusals: ContactRefusal.ledger(from: refused), overrides: overrides,
                                           context: StageContext(now: now, geo: geo, clients: .none),
                                           focusedStage: StageNavigation.openingStage, focusedKeys: nil,
                                           requestedCardKeys: cards, producerTables: tables)
                }
                // The viewport: the opening stage's first rows, as the last frame would have drawn them.
                let viewport = Set(QueueRenderPass.make(inputs(cards: [])).focusedRows
                    .prefix(QueueViewportAssumption.rows).map(\.id))
                let before = Phase0.load()
                let reading = Phase0.reading("memo-derivation-\(label)", runs: (0..<Self.samples).map { _ in
                    Phase0.time { _ = QueueRenderPass.make(inputs(cards: viewport)) }
                })
                print("e4a memo derivation, \(label): \(shows.count) show(s), \(viewport.count) card(s) requested, "
                      + "median of \(Self.samples) " + reading.text + ", \(before) before, \(Phase0.load()) after")
                // #4371 (E4a part 2): the FIRST DRAW, which is where a card the pass did not build is built: the
                // build asked for no card, as the first build after a mount is, and then each viewport row's card
                // on demand through the store, as the queue's first frame asks for them. The resolver is made
                // fresh each run, so its identifier index is paid inside the reading, as the first miss after a
                // store change pays it.
                var onDemand: [Double] = []
                let drawBefore = Phase0.load()
                let firstDraw = Phase0.reading("first-draw-\(label)", runs: (0..<Self.samples).map { _ in
                    Phase0.time {
                        let data = QueueRenderPass.make(inputs(cards: []))
                        let rows = Array(data.focusedRows.prefix(QueueViewportAssumption.rows))
                        let live = LiveProspects()
                        live.adopt(shows)
                        onDemand.append(Phase0.time { for row in rows { _ = data.cards.card(for: row, resolving: live) } })
                    }
                })
                let cards = Phase0.reading("on-demand-cards-\(label)", runs: onDemand)
                print("e4a first draw, \(label): pass asked for no card then \(QueueViewportAssumption.rows) card(s) "
                      + "on demand, median of \(Self.samples) " + firstDraw.text + "; the on demand cards alone "
                      + cards.text + ", \(drawBefore) before, \(Phase0.load()) after")
                // #4617: the two ways the cards get built, timed one after the other in this order in every run, as
                // every figure #4371 and the E4 PRs quote was. Each is compared across checkouts, which the order
                // does not bias; a comparison between them inside one run carries it, which this line says.
                Phase0.fixedOrder(["memo-derivation-\(label)", "first-draw-\(label)"])
            }
            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }
}
