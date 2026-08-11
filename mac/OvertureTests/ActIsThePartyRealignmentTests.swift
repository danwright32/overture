import Testing
import Foundation
import SwiftData

// #2504: the act-named rows ALREADY in the store.
//
// LIVE-STORE-CLAIM verified=2026-08-11 measure="rows naming no presenting organisation, and their mean fit score against the rest"
// Measured on the live store 2026-08-11: 439 of 877 rows name no presenting organisation, and they
// average a fit score of 0.4 against 3.2 for the rest. Teaching `EventClassifier` to read the act as the
// party reaches none of them: the classification is a snapshot written when a show was last read, and the
// scout skips a source whose page bytes have not changed, so Dan would see two rankings of the same kind
// of show with nothing on the card to explain the difference.
@MainActor
@Suite("Act-named rows already in the store are put back in step (#2504)")
struct ActIsThePartyRealignmentTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self, DayOff.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func insert(_ ctx: ModelContext, title: String, presenter: String?, venue: String? = "The Green Room 42",
                        discipline: String = "other", production: String = "unknown",
                        profile: String = "neutral", coverage: String = "unknown",
                        fitScore: Int = 0, fitReason: String = "",
                        configure: (Prospect) -> Void = { _ in }) -> Prospect {
        let p = Prospect(naturalKey: "\(title)|2026-09-01|\(venue ?? "")", groupName: title,
                         discipline: discipline, venue: venue, performanceDate: "2026-09-01",
                         sourceListingURL: nil, websiteURL: nil, priorRelationship: "none",
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

    // The commonest live shape: a soloist at a room that rents itself out, stored at zero.
    @Test func aStoredSoloistStopsBeingUnanswerableAndIsScoredForIt() throws {
        let ctx = try context()
        let row = insert(ctx, title: "Amanda Duarte", presenter: nil)
        let before = row.fitScore

        let summary = ActIsThePartyRealignment.run(in: ctx, now: now)

        #expect(row.production == "self")
        #expect(summary.productionLifted == 1)
        #expect(row.fitScore > before)
    }

    // A whitespace presenter is the same row: the extraction boundary writes an empty string rather than
    // nil when it drains a room's own name, which is the commonest way a row reaches this state.
    @Test func aDrainedPresenterIsTheSameRow() throws {
        let ctx = try context()
        let row = insert(ctx, title: "Christopher Zelno", presenter: "   ")
        ActIsThePartyRealignment.run(in: ctx, now: now)
        #expect(row.production == "self")
    }

    // An act that names an organisation reaches the profile axis, which it could never do before, and
    // coverage follows it because the two are one pair drawn from one set of axes (#1949).
    @Test func anEnsembleBilledAsTheActReachesProfileAndCoverage() throws {
        let ctx = try context()
        let row = insert(ctx, title: "Indianapolis Children's Choir", presenter: nil,
                         venue: "Zankel Hall", discipline: "music")
        ActIsThePartyRealignment.run(in: ctx, now: now)
        #expect(row.profile == "strong")
        #expect(row.coverage == "likely_uncovered")
    }

    // The one direction this must not move. An agency-routed rental is the dead zone whoever is billed,
    // and its penalty is the point.
    //
    // The title here deliberately carries NO agency word, so a fresh read of this row says self-produced
    // and the stored verdict is the only thing keeping it out of the lift. Written the obvious way first
    // (a title that DOES say "Winners Recital") this test passed against a version that lifted every row,
    // because the classifier answered `agency` on its own and the guard was never reached: it proved a
    // property of the classifier while claiming to prove one of this pass. Caught by mutation.
    @Test func anAgencyRowKeepsItsPenalty() throws {
        let ctx = try context()
        let row = insert(ctx, title: "Amanda Duarte", presenter: nil,
                         production: "agency", profile: "weak", fitScore: -4)
        let summary = ActIsThePartyRealignment.run(in: ctx, now: now)
        #expect(row.production == "agency")
        #expect(row.profile == "weak")
        #expect(summary.productionLifted == 0)
        #expect(row.fitScore == -4)
    }

    // A row that names a presenting organisation is not this pass's business at all.
    @Test func aRowWithAPresenterIsUntouched() throws {
        let ctx = try context()
        let row = insert(ctx, title: "An Evening Of Song", presenter: "Some Real Company")
        let summary = ActIsThePartyRealignment.run(in: ctx, now: now)
        #expect(row.production == "unknown")
        #expect(summary.rescored == 0)
    }

    // Dan's own correction is his.
    @Test func aClassificationDanOverrodeIsLeftAlone() throws {
        let ctx = try context()
        let row = insert(ctx, title: "Amanda Duarte", presenter: nil) { $0.classificationOverriddenByDan = true }
        ActIsThePartyRealignment.run(in: ctx, now: now)
        #expect(row.production == "unknown")
    }

    // The genre is not what this is about, and re-reading a stored title could move it. It must not.
    @Test func theGenreIsNeverReDecided() throws {
        let ctx = try context()
        // A title full of dance words on a row stored as theater: the classifier would read this as
        // dance, and this pass must still leave the stored genre exactly where it is.
        let row = insert(ctx, title: "Burstin' Boots Dance Party", presenter: nil, discipline: "theater")
        ActIsThePartyRealignment.run(in: ctx, now: now)
        #expect(row.discipline == "theater")
    }

    // An empty reason is a decision (#1600), and FitReasonRealignment owns the non-empty ones. This pass
    // stays out of that field entirely, so the two cannot contradict each other.
    @Test func theFitReasonIsNotThisPassesBusiness() throws {
        let ctx = try context()
        let empty = insert(ctx, title: "Amanda Duarte", presenter: nil, fitReason: "")
        let stale = insert(ctx, title: "Aziza Miller", presenter: nil, fitReason: "an older sentence")
        ActIsThePartyRealignment.run(in: ctx, now: now)
        #expect(empty.fitReason == "")
        #expect(stale.fitReason == "an older sentence")
    }

    // Idempotent by construction, not by a flag: a second launch must change nothing.
    @Test func asecondRunChangesNothing() throws {
        let ctx = try context()
        let row = insert(ctx, title: "Amanda Duarte", presenter: nil)
        ActIsThePartyRealignment.run(in: ctx, now: now)
        let settled = row.fitScore

        let again = ActIsThePartyRealignment.run(in: ctx, now: now)
        #expect(again == ActIsThePartyRealignment.Summary())
        #expect(row.fitScore == settled)
    }

    // And it has to actually RUN at launch. A pass nothing calls is indistinguishable from no pass (L3).
    @Test func launchRunsIt() {
        let source = SourceGuardHelper.source("Overture/Domain/LaunchMigrations.swift")
        #expect(source.contains("ActIsThePartyRealignment.run("))
    }
}
