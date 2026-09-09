import Testing
import Foundation
import SwiftData

// #3518: sixteen of a render pass's draft-lint runs happen somewhere other than card construction, and
// nobody had looked at where.
//
// #3498 removed the repeated linting INSIDE the card build: every reader on a card now shares one pass of
// the lint per pending contact carrying a body. What it did not touch is the rest, which is now the
// LARGER share, and `allowedLintRunsOutsideTheCardBuild` pins it so it cannot grow unnoticed without
// saying anything about where it comes from. That is the term #3498's own text called out and left open.
//
// It is also the part a future change is most likely to grow, because it is diffuse: the card build has
// one obvious chokepoint and this does not.
//
// HOW THEY ARE ATTRIBUTED. #3518's direction is to measure a pass with each of its other whole-store
// derivations excluded in turn, or to add a per-caller distinction. This does the first, the other way
// round: each derivation is run ALONE with a tally bound, over the same corpus and the same context the
// pass uses, and what it counts is what it accounts for. That needs no seam in the app and no second
// definition of the pass, and it is checked against the whole pass's own figure, so a derivation nobody
// listed shows up as a remainder rather than being silently absorbed (L98).
@MainActor
@Suite("Where the draft lint runs outside the card build (#3518)")
struct LintRunsOutsideTheCardBuildTests {

    private static let corpusSize = 1142

    // THE ANSWER, pinned, so it cannot move to a different caller without anybody noticing. Measured
    // 2026-09-05 on this corpus: every one of the sixteen runs outside card construction belongs to
    // `StageNavigation.counts`, reached through `AgentInputs.from`, and every other whole-store
    // derivation in the pass runs the lint zero times.
    //
    // Zero is pinned for the others deliberately and beside the assertion that says why it is zero: a
    // counter whose only input is a value nothing produces reports zero indistinguishably from a real
    // measurement (L90). Here the zeroes are the finding.
    // #3738 MOVED WHERE THEY HAPPEN AND NOT HOW MANY. They were reached through
    // `StageNavigation.counts`, which evaluated `matches` against all nine focuses for every show. That
    // evaluation now happens once, in `StageNavigation.placements`, and `counts` reads the table it
    // produced. So the sixteen belong to the PLACEMENT and the three readers of it run the lint zero
    // times, which is a better answer to #3518's question than the one this suite first recorded: they
    // are one derivation's cost rather than a term inside the agent strip.
    private static let allowedLintRunsInThePlacement = 16
    private static let allowedLintRunsInEveryOtherDerivation = 0

    // A generous ceiling on what those cost, set far above the measured 0.595% rather than at a round
    // number just over it, so anything approaching it is a change in kind rather than noise (L172).
    private static let allowedShareOfOnePass = 0.05
    private static let prospectsWithADraftBody = 39
    private static let recipientsOnDraftBodyRows = 42
    private static let pendingRecipientsWithADraftBody = 16

    private func container() throws -> ModelContainer {
        try ModelContainer(
            for: Schema([Prospect.self, Recipient.self, Inquiry.self, OrgReachabilityAnswer.self,
                         WatchedSource.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    // The same shape the cost fixture carries, because the lint scales with the pairing #3506 recorded
    // (pending contacts on rows that have a body) and a corpus without it measures a different world.
    private func seed(_ ctx: ModelContext) -> [Prospect] {
        let dates = LiveDateClustering.dates(forRows: Self.corpusSize)
        var rows: [Prospect] = []
        for n in 0..<Self.corpusSize {
            let p = Prospect(naturalKey: "row-\(n)", groupName: "Ensemble \(n % 90)", discipline: "music",
                             venue: "Venue \(n % 169) Hall", performanceDate: dates[n],
                             sourceListingURL: nil, priorRelationship: "none",
                             production: n % 3 == 0 ? "self" : "presenter", profile: "strong",
                             coverage: "likely_uncovered", fitScore: 4 + (n % 5), tier: "mid",
                             fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                             possibleMatchName: nil, status: n % 3 == 0 ? .drafted : .new)
            p.presenter = "Ensemble \(n % 90) Presents"
            p.location = "New York, NY"
            if n < Self.prospectsWithADraftBody {
                p.draftBody = "Hello there,\n\nI photograph performances in New York and would love to "
                    + "cover this one. My work is at the link below.\n\nBest,\nDan"
            }
            ctx.insert(p)
            rows.append(p)
        }
        var made = 0, pendingMade = 0
        let bodyRowsWithAContact = Self.prospectsWithADraftBody - 1
        for n in 0..<bodyRowsWithAContact {
            let howMany = n < (Self.recipientsOnDraftBodyRows - bodyRowsWithAContact) ? 2 : 1
            for _ in 0..<howMany {
                let pending = pendingMade < Self.pendingRecipientsWithADraftBody
                let r = Recipient(id: "contact-\(made)", email: "contact\(made)@example.com",
                                  name: "Contact \(made)", role: "programming", provenance: .presenter)
                r.sendState = pending ? SendState.pending : SendState.sent
                r.prospect = rows[n]
                ctx.insert(r)
                if pending { pendingMade += 1 }
                made += 1
            }
        }
        try? ctx.save()
        return rows
    }

    private func inputs(_ rows: [Prospect]) -> QueueRenderPass.Inputs {
        QueueRenderPass.Inputs(
            allProspects: QueueRenderPass.Corpus(rows),
            inquiries: [], orgAnswers: [],
            context: .at("2026-08-02", now: Date(timeIntervalSince1970: 1_785_000_000)),
            focusedStage: .scout, focusedKeys: nil)
    }

    private func lintRuns(_ work: () -> Void) -> Int {
        QueueRenderPass.WorkTally.measure { work() }.draftLintRuns
    }

    @Test func everyLintRunOutsideTheCardBuildIsAttributed() throws {
        let ctx = ModelContext(try container())
        let rows = seed(ctx)

        // The pass's own resolved context, so each derivation below is asked the question the pass asks
        // rather than one written beside it (L107).
        let resolved = QueueRenderPass.Inputs(
            allProspects: QueueRenderPass.Corpus(rows), inquiries: [], orgAnswers: [],
            context: .at("2026-08-02", now: Date(timeIntervalSince1970: 1_785_000_000)),
            focusedStage: .scout, focusedKeys: nil).context.resolvingPlaces(of: rows)

        let wholePass = lintRuns { _ = QueueRenderPass.make(inputs(rows)) }
        let cardBuild = lintRuns { for row in rows { _ = QueueItem(row) } }

        // Each whole-store derivation the pass makes, run alone. `QueueModel.items` is the card build's
        // own home and is measured through it above, so it is not repeated here.
        let reachedOut = lintRuns { _ = ReachedOutQueue.activeWithDates(from: rows, now: resolved.now) }
        let keys = Set(ReachedOutQueue.activeWithDates(from: rows, now: resolved.now)
            .map(\.prospect.naturalKey))
        // #3738: the pass decides every show's stages ONCE and reads that table three ways, so the
        // attribution follows the pass. Measured through the prospect-taking forwarders instead, each of
        // the three built its own table and each reported the same sixteen runs, which reads as the pass
        // running them three times when it runs them once (L118).
        let placing = lintRuns { _ = StageNavigation.placements(in: rows, context: resolved) }
        let placement = StageNavigation.placements(in: rows, context: resolved)
        let inAStage = lintRuns {
            _ = StageNavigation.queueKeys(in: placement, reachedOutKeys: keys)
        }
        let focused = lintRuns {
            _ = StageNavigation.focusedKeys(stage: .scout, leadKeys: [], in: placement)
        }
        let agentStrip = lintRuns {
            _ = AgentInputs.from(prospects: rows, allProspects: rows, inquiries: [], context: resolved,
                                 gmailConnected: false, runInFlight: nil, replyRunAlive: false,
                                 placement: placement)
        }
        let fanOut = lintRuns { _ = QueueRenderPass.fanOutWarning(rows) }
        let places = lintRuns { _ = resolved }

        // One level deeper into the agent strip, which is where they all turn out to be. Each of its own
        // whole-store derivations run alone, so "the agent strip" is an answer somebody can act on rather
        // than a bigger box to put the number in.
        let stageCounts = lintRuns { _ = StageNavigation.counts(in: placement) }
        let dueWork = lintRuns {
            _ = DueWork.counts(prospects: rows, now: resolved.now, replyRunAlive: false)
        }
        let deadEnds = lintRuns { _ = DraftedDeadEnd.count(in: rows) }
        let stalledDrafts = lintRuns {
            _ = StalledReplyDraft.dueRecipients(from: rows, now: resolved.now, runAlive: false)
        }
        let insideTheStrip = stageCounts + dueWork + deadEnds + stalledDrafts

        let outside = wholePass - cardBuild
        let attributed = reachedOut + placing + inAStage + focused + agentStrip + fanOut + places
        print("""
        lint-runs-outside-the-card-build: where the other \(outside) come from (#3518)
          whole pass                        \(wholePass)
          card construction                 \(cardBuild)
          OUTSIDE card construction         \(outside)

          run alone, over the same corpus:
            resolving every show's place    \(places)
            the shows already reached out   \(reachedOut)
            placing every show in a stage  \(placing)
            which shows are in a stage      \(inAStage)
            which the focused stage renders \(focused)
            the agent strip's inputs        \(agentStrip)
            the possible-match fan-out      \(fanOut)
            ---------------------------------------
            accounted for                   \(attributed)
            unaccounted for                 \(outside - attributed)

          inside the agent strip, each run alone:
            the stage counts                \(stageCounts)
            the follow-ups due              \(dueWork)
            the drafted dead ends           \(deadEnds)
            the stalled reply drafts        \(stalledDrafts)
            ---------------------------------------
            accounted for                   \(insideTheStrip)
            unaccounted for                 \(agentStrip - insideTheStrip)

          Each figure is that derivation run ALONE with a tally bound, not a difference between passes,
          so a derivation that shares a term with another is not credited twice by subtraction.
        """)

        // WHAT THEY COST, because "where do they come from" only decides anything beside a price. #3518
        // says to decide from the number, and both of its outcomes are open until there is one: fix it
        // the way #3498 did, or record that this is what the pass costs (L248).
        //
        // Timed as the same work at the same volume, against a pass timed in the SAME RUN, because a
        // fixed millisecond figure measures what else this Mac is running (L224).
        let body = rows.first(where: { ($0.draftBody ?? "").isEmpty == false })?.draftBody ?? ""
        func seconds(_ work: () -> Void) -> Double {
            let start = Date(); work(); return Date().timeIntervalSince(start)
        }
        _ = QueueRenderPass.make(inputs(rows))                      // warm
        let passSeconds = seconds { _ = QueueRenderPass.make(inputs(rows)) }
        let lintSeconds = seconds { for _ in 0..<outside { _ = DraftCheck.blockingFindings(in: body) } }
        let share = passSeconds > 0 ? lintSeconds / passSeconds : 1

        print("""
        lint-runs-outside-the-card-build: what those \(outside) cost (#3518)
          one pass                          \(String(format: "%.1f", passSeconds * 1000)) ms
          \(outside) lint runs over one body        \(String(format: "%.3f", lintSeconds * 1000)) ms
          share of one pass                 \(String(format: "%.3f%%", share * 100))

          Read the SHARE, never the milliseconds (L224). They are an exact DUPLICATE of the sixteen the
          card build already ran, over the same sixteen pending contacts, so removing them is possible;
          whether it is worth doing is what this figure answers.
        """)
        #expect(!body.isEmpty, "no row in the corpus carries a body, so the lint was timed over nothing")
        #expect(lintSeconds >= 0)

        // The measurement is real before anything is concluded from it (L98).
        #expect(wholePass > 0, "a whole pass ran the lint zero times, so nothing was attributed")
        #expect(cardBuild > 0, "building every card ran the lint zero times")
        #expect(outside > 0, "nothing happens outside card construction, so this suite has no subject")

        // The finding: every run outside the card build belongs to a derivation named above. A remainder
        // is a caller nobody has listed, which is what this exists to surface, and it is reported with
        // its size rather than absorbed.
        // The attribution itself, pinned. Without this the table above is a report somebody reads once.
        #expect(placing == Self.allowedLintRunsInThePlacement,
                Comment(rawValue: "placing every show in its stages ran the lint \(placing) times, "
                        + "against the \(Self.allowedLintRunsInThePlacement) this pass is pinned at"))
        // ZERO for the three readers, and that is the #3738 finding rather than a formality: each is a
        // projection of the table above, so a reader that ran the lint at all would be deciding
        // something rather than reading a record (L263).
        #expect(stageCounts == Self.allowedLintRunsInEveryOtherDerivation)
        #expect(dueWork == Self.allowedLintRunsInEveryOtherDerivation)
        #expect(deadEnds == Self.allowedLintRunsInEveryOtherDerivation)
        #expect(stalledDrafts == Self.allowedLintRunsInEveryOtherDerivation)
        #expect(places == Self.allowedLintRunsInEveryOtherDerivation)
        #expect(reachedOut == Self.allowedLintRunsInEveryOtherDerivation)
        #expect(inAStage == Self.allowedLintRunsInEveryOtherDerivation)
        #expect(focused == Self.allowedLintRunsInEveryOtherDerivation)
        #expect(fanOut == Self.allowedLintRunsInEveryOtherDerivation)
        #expect(share < Self.allowedShareOfOnePass,
                Comment(rawValue: "the duplicated lint runs cost "
                        + "\(String(format: "%.2f%%", share * 100)) of one pass, against the 0.595% "
                        + "measured when #3518 was closed on that number. If this is real rather than a "
                        + "loaded Mac, the decision recorded there is worth re-taking."))

        // #3738: the agent strip now runs the lint zero times, because the one term inside it that did
        // (`StageNavigation.counts`) reads a table the caller built. The identity below still holds, at
        // zero on both sides, and that is deliberately NOT treated as it passing: `placing` above is
        // where the sixteen went, and it is asserted at sixteen rather than at "not zero", so an empty
        // measurement cannot satisfy this suite (L98, L182).
        #expect(agentStrip == insideTheStrip,
                Comment(rawValue: "\(agentStrip - insideTheStrip) of the agent strip's \(agentStrip) "
                        + "lint runs belong to none of its own derivations named here, so the strip is "
                        + "just a bigger box to put the number in rather than an answer (#3518)."))
        #expect(outside == attributed,
                Comment(rawValue: "\(outside - attributed) of the \(outside) lint runs outside card "
                        + "construction belong to no derivation listed here. Something in the pass "
                        + "reaches isSendablePending or isBlockedAwaitingReview and is not named, which "
                        + "is exactly what #3518 exists to find. Add it to the list above and re-read "
                        + "the attribution."))
    }

    // WHOSE laziness stops this being worse, asserted rather than left in a comment: both blocked-state
    // predicates take an `@autoclosure`, so a caller that refuses a contact early pays nothing. #3498
    // measured that an eager parameter made the pass WORSE, 66 runs against 90, before the laziness went
    // in (L62), and nothing since has held the shape that made it true.
    @Test func theBlockedPredicatesStillTakeTheirFindingsLazily() {
        let source = SourceGuardHelper.source("Overture/Domain/Recipient.swift")
        #expect(SourceGuardHelper.containsCode("@autoclosure", in: source), Comment(rawValue:
                "Recipient.swift no longer takes any finding lazily, so every caller now pays the lint "
                + "whether it needs the answer or not (#3498, L62)"))
    }
}
