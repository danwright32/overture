import Testing
import Foundation
import SwiftData

// #2565: the rows the OLD fragment-matching classifier lifted, corrected in place.
//
// #2508 stopped the three signal lists firing inside longer words ("opera" inside `Operation Mincemeat`,
// "band" inside `Sam Gelband`, "school" inside `Let's Get Schooled!`). That change reaches a row only when
// the scout next re-reads its page, and the scout skips a source whose bytes have not changed, so a row
// scored under the old rule keeps what the fragment gave it for as long as its page sits still.
//
// `ActIsThePartyRealignment` re-reads these same rows every launch and structurally cannot help: it only
// ever LIFTS (unknown to selfProduced, neutral to strong), by deliberate design, because a plain re-read
// of a stored row knows LESS than the read that wrote it. A presenter later drained, an axis merged from
// a second source, a title rewritten: each of those makes a re-read say less than the truth, and lowering
// on that basis would demote rows for reasons that have nothing to do with any classifier change.
//
// So this pass does NOT lower on disagreement. It lowers only on the DEFECT'S OWN SIGNATURE: the stored
// value is one the pre-#2508 pattern produces from this row's own inputs and the current pattern refuses.
// That is the difference these tests exist to hold, and the fixture in
// `aStrongNoRuleEverProducedFromThisRowIsLeftAlone` is a real live row that a plain re-read would have
// demoted (L68: assert the signature of the failure, never a proxy for it).
@MainActor
@Suite("Rows the old fragment-matching classifier lifted are corrected (#2565)")
struct FragmentMatchCorrectionTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self, DayOff.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func insert(_ ctx: ModelContext, title: String, presenter: String?,
                        venue: String? = "The Green Room 42",
                        discipline: String = "other", production: String = "self",
                        profile: String = "strong", coverage: String = "likely_uncovered",
                        fitScore: Int = 6, fitReason: String = "",
                        configure: (Prospect) -> Void = { _ in }) -> Prospect {
        let p = Prospect(naturalKey: "\(title)|2026-09-01|\(venue ?? "")", groupName: title,
                         discipline: discipline, venue: venue, performanceDate: "2026-09-01",
                         sourceListingURL: nil, priorRelationship: "none",
                         production: production, profile: profile, coverage: coverage,
                         fitScore: fitScore, tier: "longshot", fitReason: fitReason,
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .new)
        p.presenter = presenter
        configure(p)
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    private let now = Date(timeIntervalSince1970: 1_786_000_000)

    // The row the issue leads with. "school" inside "Schooled" reached BOTH lists, so the stored row is a
    // self-produced strong-profile organisation, worth 6 points, on a signal that was never real.
    @Test func aProfileAFragmentLiftedIsLoweredAndTheRowIsRescored() throws {
        let ctx = try context()
        let row = insert(ctx, title: "Let's Get Schooled!", presenter: nil)
        let before = row.fitScore

        let summary = FragmentMatchCorrection.run(in: ctx, now: now)

        #expect(row.profile == "neutral")
        #expect(summary.profileLowered == 1)
        #expect(summary.rescored == 1)
        #expect(row.fitScore < before)
        // Coverage is DERIVED from the axes and never left behind them (#1949): a row that is no longer a
        // strong-profile self-produced group is no longer "likely without its own photographer".
        #expect(row.coverage == "unknown")
    }

    // The other half of the defect, and the half that predates #2504: the same fragment match on a
    // PRESENTER string, where it has always been able to reach `production` as well.
    @Test func aProductionAFragmentLiftedIsLoweredToUnknown() throws {
        let ctx = try context()
        let row = insert(ctx, title: "An Evening of Songs", presenter: "Sam Gelband",
                         profile: "neutral", coverage: "unknown", fitScore: 4)

        let summary = FragmentMatchCorrection.run(in: ctx, now: now)

        #expect(row.production == "unknown")
        #expect(summary.productionLowered == 1)
    }

    // Dan's own correction is his, and a pass that overwrites his judgement is worse than the bug it
    // fixes. This is the guard the issue names first.
    @Test func aClassificationDanOverrodeIsLeftAlone() throws {
        let ctx = try context()
        let row = insert(ctx, title: "Let's Get Schooled!", presenter: nil) {
            $0.classificationOverriddenByDan = true
        }

        let summary = FragmentMatchCorrection.run(in: ctx, now: now)

        #expect(row.profile == "strong")
        #expect(row.production == "self")
        #expect(summary == FragmentMatchCorrection.Summary())
    }

    // A row that EARNS its stored value under today's rules is not this pass's business. "Brooklyn Youth
    // Chorus" names an organisation under the anchored lists exactly as it did under the old ones, so
    // nothing here may touch it.
    @Test func aRowThatStillEarnsItsValueTodayIsNotLowered() throws {
        let ctx = try context()
        let row = insert(ctx, title: "A Winter Concert", presenter: "Brooklyn Youth Chorus")

        let summary = FragmentMatchCorrection.run(in: ctx, now: now)

        #expect(row.production == "self")
        #expect(row.profile == "strong")
        #expect(summary == FragmentMatchCorrection.Summary())
    }

    // THE REASON THIS PASS IS SIGNATURE-SCOPED RATHER THAN A RE-READ.
    //
    // LIVE-STORE-CLAIM verified=2026-08-16 measure="rows a plain re-read would lower whose stored value no signal list, old or new, produces from the row's own inputs"
    // Measured on a clone of the live store 2026-08-16: three rows carry `self` + `strong` that NEITHER
    // the old pattern nor the new one produces from what the row now holds, because the presenter that
    // earned it has since been drained. `Timeless Melodies` is one of them, verbatim. A pass that lowered
    // on disagreement would demote all three for a reason unrelated to #2508, which is exactly what
    // `ActIsThePartyRealignment` refuses to do by only ever lifting.
    @Test func aStrongNoRuleEverProducedFromThisRowIsLeftAlone() throws {
        let ctx = try context()
        let row = insert(ctx, title: "Timeless Melodies: Masterpieces Inspiring Generations",
                         presenter: nil, venue: "Weill Recital Hall", discipline: "music")

        let summary = FragmentMatchCorrection.run(in: ctx, now: now)

        #expect(row.profile == "strong")
        #expect(summary == FragmentMatchCorrection.Summary())
    }

    // The same rule on the production axis: a stored `self` that no signal list ever produced from this
    // row's own inputs came from somewhere a re-read cannot see (a presenter since rewritten, an axis
    // merged from a second source under #1949), and is not this pass's to take back.
    @Test func aProductionNoRuleEverProducedFromThisRowIsLeftAlone() throws {
        let ctx = try context()
        let row = insert(ctx, title: "An Evening of Songs", presenter: "Amanda Duarte",
                         profile: "neutral", coverage: "unknown", fitScore: 4)

        let summary = FragmentMatchCorrection.run(in: ctx, now: now)

        #expect(row.production == "self")
        #expect(summary == FragmentMatchCorrection.Summary())
    }

    // This pass LOWERS. It is the one direction the launch's realignment avoids on purpose, and the
    // opposite direction stays that pass's alone: a row stored below what it would earn today is left
    // exactly where it is here, so the two can never fight over one row.
    @Test func nothingIsEverLifted() throws {
        let ctx = try context()
        let row = insert(ctx, title: "A Winter Concert", presenter: "Brooklyn Youth Chorus",
                         production: "unknown", profile: "neutral", coverage: "unknown", fitScore: 0)

        let summary = FragmentMatchCorrection.run(in: ctx, now: now)

        #expect(row.production == "unknown")
        #expect(row.profile == "neutral")
        #expect(summary == FragmentMatchCorrection.Summary())
    }

    // An agency row keeps its penalty. The dead zone is the one direction nothing here may lift, whatever
    // the fragment did, and #2508 measured no live row whose agency verdict a fragment produced anyway.
    @Test func anAgencyRowKeepsItsPenalty() throws {
        let ctx = try context()
        let row = insert(ctx, title: "Detour: A New Musical", presenter: nil,
                         production: "agency", profile: "weak", coverage: "unknown", fitScore: -4)

        FragmentMatchCorrection.run(in: ctx, now: now)

        #expect(row.production == "agency")
        #expect(row.profile == "weak")
        #expect(row.fitScore == -4)
    }

    // The genre is Dan's to correct (#1658/#1533) and is not what this is about. This row IS corrected on
    // its profile, and a re-read of its title names no genre at all, so a pass that wrote the genre back
    // alongside the axes would wipe the stored one.
    @Test func theGenreIsNeverReDecided() throws {
        let ctx = try context()
        let row = insert(ctx, title: "Let's Get Schooled!", presenter: nil, discipline: "theater")

        let summary = FragmentMatchCorrection.run(in: ctx, now: now)

        #expect(summary.profileLowered == 1)
        #expect(row.discipline == "theater")
    }

    // An empty reason is a decision (#1600) and `FitReasonRealignment` owns the non-empty ones, every
    // launch. Two passes with opposite rules about one field is how they come to contradict each other,
    // so this one stays out of it entirely, exactly as `ActIsThePartyRealignment` does.
    @Test func theFitReasonIsNotThisPassesBusiness() throws {
        let ctx = try context()
        let empty = insert(ctx, title: "Let's Get Schooled!", presenter: nil, fitReason: "")
        let stale = insert(ctx, title: "Operation Mincemeat: Mission Recast", presenter: nil,
                           fitReason: "an older sentence")

        FragmentMatchCorrection.run(in: ctx, now: now)

        #expect(empty.fitReason == "")
        #expect(stale.fitReason == "an older sentence")
    }

    // Idempotent by construction rather than by a flag: the condition is a stored value the current rules
    // refuse, and the pass writes what they allow, so a second launch finds nothing.
    @Test func aSecondRunChangesNothing() throws {
        let ctx = try context()
        let row = insert(ctx, title: "Let's Get Schooled!", presenter: nil)
        FragmentMatchCorrection.run(in: ctx, now: now)
        let settled = row.fitScore

        let again = FragmentMatchCorrection.run(in: ctx, now: now)

        #expect(again == FragmentMatchCorrection.Summary())
        #expect(row.fitScore == settled)
    }

    // The two passes run in the same launch, minutes apart, over the same rows. One lifts and one lowers,
    // so the thing to prove is that they cannot hand a row back and forth: after both have run, running
    // both again moves nothing.
    @Test func theLiftingPassAndThisOneDoNotOscillate() throws {
        let ctx = try context()
        let lifted = insert(ctx, title: "Amanda Duarte", presenter: nil, production: "unknown",
                            profile: "neutral", coverage: "unknown", fitScore: 0)
        let lowered = insert(ctx, title: "Let's Get Schooled!", presenter: nil)

        ActIsThePartyRealignment.run(in: ctx, now: now)
        FragmentMatchCorrection.run(in: ctx, now: now)
        let settledLift = (lifted.production, lifted.profile, lifted.fitScore)
        let settledLower = (lowered.production, lowered.profile, lowered.fitScore)

        let againLift = ActIsThePartyRealignment.run(in: ctx, now: now)
        let againLower = FragmentMatchCorrection.run(in: ctx, now: now)

        #expect(againLift == ActIsThePartyRealignment.Summary())
        #expect(againLower == FragmentMatchCorrection.Summary())
        #expect(lifted.production == settledLift.0)
        #expect(lifted.profile == settledLift.1)
        #expect(lifted.fitScore == settledLift.2)
        #expect(lowered.production == settledLower.0)
        #expect(lowered.profile == settledLower.1)
        #expect(lowered.fitScore == settledLower.2)
    }

    // And it has to actually RUN at launch. A pass nothing calls is indistinguishable from no pass (L3).
    @Test func launchRunsIt() {
        let source = SourceGuardHelper.source("Overture/Domain/LaunchMigrations.swift")
        #expect(source.contains("FragmentMatchCorrection.run("))
    }
}
