import Testing
import Foundation
import SwiftData

// #3738: every show's stages are decided ONCE per render pass.
//
// WHAT THIS IS ABOUT. `QueueRenderPass.make` asked the same question three times over one corpus in one
// pass: `queueKeys` for the masthead's membership, `counts` for the nine pill numbers, and `focusedKeys`
// for the focused stage's rows. `matches` faults a prospect's `recipients`, and on 1,230 rows that came
// to roughly 23,000 evaluations per render. #3736 measured the three at 75.2, 36.1 and 31.4 ms, which is
// 152.1 ms of the pass's 421.6 ms floor.
//
// COUNTED, NEVER TIMED, and counted as PLACEMENTS rather than as calls to the functions that read one. A
// call count reads 1 whether the callee decides every show's stages or reads a table it was handed, so it
// is the same number for the defect and for the fix (L63). #3438's `selfBookingShowsExamined` exists for
// exactly this reason and is the precedent.
@MainActor
@Suite("Every show's stages are decided once per pass (#3738)")
struct StagePlacedOncePerPassTests {
    private static let corpusSize = 40

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    // A corpus spread across several stages, because a placement over shows that all land in one focus
    // could not tell a table read four ways from four separate sweeps that happen to agree.
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

    private func inputs(_ rows: [Prospect]) -> QueueRenderPass.Inputs {
        QueueRenderPass.Inputs(
            allProspects: QueueRenderPass.Corpus(rows), inquiries: [], orgAnswers: [],
            context: StageContext(now: Date(timeIntervalSince1970: 4_070_908_800),
                                  geo: .none, clients: .none),
            focusedStage: .scout)
    }

    // THE ONE THAT MATTERS.
    @Test("one render pass decides every show's stages exactly once")
    func onePassPlacesOnce() throws {
        let ctx = ModelContext(try container())
        let shows = seed(ctx)

        let work = QueueRenderPass.WorkTally.measure { _ = QueueRenderPass.make(inputs(shows)) }

        #expect(work.stagePlacements == 1,
                Comment(rawValue: "the pass decided every show's stages \(work.stagePlacements) times. "
                        + "Each one walks the corpus evaluating `matches` against nine focuses, and "
                        + "`matches` faults a prospect's recipients (#3738)."))
    }

    // The floor, so the guard above cannot be satisfied by a pass that stopped placing anything at all:
    // zero and one are different answers and both have to be sayable (L11, L98).
    @Test("the pass really does place the corpus it was given")
    func thePassPlacesTheWholeCorpus() throws {
        let ctx = ModelContext(try container())
        let shows = seed(ctx)

        let placement = StageNavigation.placements(
            in: shows, context: StageContext(now: Date(timeIntervalSince1970: 4_070_908_800),
                                             geo: .none, clients: .none))

        #expect(placement.count == Self.corpusSize,
                Comment(rawValue: "placed \(placement.count) shows of \(Self.corpusSize)"))
    }

    // MARK: - The two entry points give one answer

    // Every reader, asked BOTH ways over the same corpus, must agree. Two entry points onto one
    // derivation is the shape that drifts, and the drift would be silent because both halves go on
    // returning perfectly good keys (L263). This is what makes the forwarders safe.
    @Test("a placement and the direct path agree, reader by reader")
    func bothEntryPointsAgree() throws {
        let ctx = ModelContext(try container())
        let shows = seed(ctx)
        let context = StageContext(now: Date(timeIntervalSince1970: 4_070_908_800),
                                   geo: .none, clients: .none)
        let placement = StageNavigation.placements(in: shows, context: context)
        let reachedOut: Set<String> = ["k4", "k8"]

        #expect(StageNavigation.counts(in: placement)
                == StageNavigation.counts(in: shows, context: context))
        #expect(StageNavigation.queueKeys(in: placement, reachedOutKeys: reachedOut)
                == StageNavigation.queueKeys(in: shows, reachedOutKeys: reachedOut, context: context))
        #expect(StageNavigation.stagedKeys(in: placement, reachedOutKeys: reachedOut)
                == StageNavigation.stagedKeys(in: shows, reachedOutKeys: reachedOut, context: context))

        // EVERY focus, including the two that resolve no keys, and in ORDER, because `naturalKeys`
        // returns its keys in the prospects' own order and its callers render them.
        for focus in StageFocus.allCases {
            #expect(StageNavigation.naturalKeys(for: focus, in: placement)
                    == StageNavigation.naturalKeys(for: focus, in: shows, context: context),
                    Comment(rawValue: "the two paths disagree about \(focus)"))
            #expect(StageNavigation.focusedKeys(stage: focus, leadKeys: [], in: placement)
                    == StageNavigation.focusedKeys(stage: focus, leadKeys: [], in: shows,
                                                   context: context))
        }
        // The nil stage is the #308 away-alert leads path, which is not a stage: its keys come back
        // verbatim. A separate case because the guard between them is one `if let`.
        #expect(StageNavigation.focusedKeys(stage: nil, leadKeys: ["a", "b"], in: placement) == ["a", "b"])

        // And which stage a deep link lands in, per show, which is the one reader that depends on the
        // ORDER of a show's own focuses rather than on the order of the shows.
        for show in shows {
            #expect(StageNavigation.stage(containing: show.naturalKey, in: placement,
                                          reachedOutKeys: reachedOut)
                    == StageNavigation.stage(containing: show.naturalKey, in: shows,
                                             reachedOutKeys: reachedOut, context: context),
                    Comment(rawValue: "the two paths put \(show.naturalKey) in different stages"))
        }
        // A key no show answers to is in no stage either way, which is what routes it to Archive.
        #expect(StageNavigation.stage(containing: "nobody", in: placement, reachedOutKeys: reachedOut)
                == nil)
    }

    // #863's invariant, re-asserted through the new path: the number a pill shows is the count of the
    // rows its tap lands on. `StageNavigationCountsTests` holds it for the direct path; this holds it for
    // the table, because a projection that lost an entry would keep both halves self-consistent while
    // both were wrong (L70).
    @Test("a pill's count is the number of rows its tap resolves")
    func aCountIsItsOwnDestination() throws {
        let ctx = ModelContext(try container())
        let shows = seed(ctx)
        let context = StageContext(now: Date(timeIntervalSince1970: 4_070_908_800),
                                   geo: .none, clients: .none)
        let placement = StageNavigation.placements(in: shows, context: context)
        let counts = StageNavigation.counts(in: placement)

        var checked = 0
        for focus in StageFocus.allCases {
            let keys = StageNavigation.naturalKeys(for: focus, in: placement)
            #expect((counts[focus] ?? 0) == keys.count,
                    Comment(rawValue: "\(focus) counts \(counts[focus] ?? 0) and resolves \(keys.count)"))
            if !keys.isEmpty { checked += 1 }
        }
        // Non-vacuous: the corpus really does land in several stages, or every comparison above was
        // zero against zero (L98).
        #expect(checked >= 3, "only \(checked) focuses hold any show, so this compared mostly zeroes")
    }
}
