import Testing
import Foundation
import SwiftData
import SwiftUI
import ViewInspector
@testable import Overture

// #1466: can a live performer-match correction ever be INVISIBLE on the row?
//
// The row's flag renders only while the correction is held AND Dan has not rejected it
// (`relationshipCorrectedByPerformerMatch && !performerMatchDismissed`). The issue asks whether a show
// can end up holding BOTH at once: the correction live and scoring the lead warm, with nothing on the row
// for Dan to confirm or reject, and the drafting-tone gate therefore holding it cold forever.
//
// The issue also says the premise is a claim, not a fact, and asks for a probe first. This suite is that
// probe. It found the state UNREACHABLE, so the tests below pin it that way rather than fixing anything:
// the first test builds the bad state by hand and shows what it would cost, so nothing here is vacuous,
// and the rest drive every real path that touches the pair.
@Suite("A live performer match is never invisible on the row (#1466)")
struct PerformerMatchVisibilityTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private let vega = DownbeatClient(id: "client-larkin", displayName: "Larkin Sable", shortName: nil,
                                      email: "", contractEmail: "", phoneNumber: nil, isTaxExempt: nil,
                                      hasLeftReview: false, specialBehaviors: [], notes: nil, hostingSite: "")
    private let tanaka = DownbeatClient(id: "client-aki", displayName: "Aki Tanaka", shortName: nil,
                                        email: "", contractEmail: "", phoneNumber: nil, isTaxExempt: nil,
                                        hasLeftReview: false, specialBehaviors: [], notes: nil, hostingSite: "")

    // A show the scout scored cold, with no correction on it yet.
    private func coldShow(_ ctx: ModelContext) -> Prospect {
        let key = Prospect.makeNaturalKey(groupName: "Emerging Artists Series",
                                          performanceDate: "2026-08-02", venue: "Weill Recital Hall")
        let p = Prospect(naturalKey: key, groupName: "Emerging Artists Series", discipline: "music",
                         venue: "Weill Recital Hall", performanceDate: "2026-08-02",
                         sourceListingURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 7, tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .queued)
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    private func prepResults(_ key: String, performer: String) -> PrepResults {
        PrepResults(version: 3, generatedAt: "now", results: [
            PrepResult(naturalKey: key,
                       contacts: [PrepContact(name: performer, role: "Violinist", email: nil,
                                              method: "named_decision_maker", confidence: "high",
                                              formUrl: nil, provenance: "performer")],
                       draft: nil)
        ])
    }

    private func rowShowsTheMatch(_ p: Prospect) throws -> Bool {
        let item = QueueItem(id: p.naturalKey, groupName: p.groupName, discipline: p.discipline,
                             venue: p.venue, performanceDate: p.performanceDate, sourceListingURL: nil, priorRelationship: p.priorRelationship,
                             production: p.production, profile: p.profile, coverage: p.coverage,
                             fitScore: p.fitScore, tier: p.tier, fitReason: p.fitReason,
                             matchedClientName: p.matchedClientName, possibleMatchSource: nil,
                             possibleMatchName: nil, status: p.status,
                             relationshipCorrectedByPerformerMatch: p.relationshipCorrectedByPerformerMatch,
                             performerMatchNote: p.performerMatchNote,
                             performerMatchDismissed: p.performerMatchDismissed,
                             performerMatchReviewed: p.performerMatchReviewed)
        let view = ProspectRowView(item: item, today: "2026-07-11", onKeep: {}, onDismiss: { _ in })
        let texts = try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        return texts.contains { $0.contains("Matched performer") }
    }

    // MARK: - What the bad state would cost

    // Built by hand, because nothing in the app can produce it. This is the harm #1466 describes, and it
    // is what stops every assertion below from being vacuous: the two fields really can disagree, and
    // when they do the row goes quiet while the lead keeps the warm score the match gave it.
    @Test func holdingBothAtOnceWouldHideACorrectionThatIsStillScoringTheLeadWarm() throws {
        let ctx = ModelContext(try container())
        let p = coldShow(ctx)
        p.priorRelationship = "booked"
        p.fitScore = 27
        p.relationshipCorrectedByPerformerMatch = true
        p.performerMatchNote = "Matched performer 'Larkin Sable' to Downbeat client Larkin Sable."
        p.performerMatchDismissed = true

        #expect(try rowShowsTheMatch(p) == false)   // Dan is shown nothing to confirm or reject
        #expect(p.priorRelationship == "booked")    // while the correction still scores the lead warm
        #expect(p.fitScore == 27)
        // And it cannot be escaped: the drafting gate reads the pre-correction value until Dan confirms,
        // which he has no way to do, so the show is warm in the ranking and cold in every email forever.
        #expect(p.priorRelationshipForDrafting == "none")
    }

    // MARK: - Every real path leaves the two fields agreeing

    @Test func applyingAFindingLeavesItVisible() throws {
        let ctx = ModelContext(try container())
        let p = coldShow(ctx)

        _ = PrepImporter.ingest(prepResults(p.naturalKey, performer: "Larkin Sable"),
                                into: ctx, clients: [vega], history: [])

        #expect(p.relationshipCorrectedByPerformerMatch)
        #expect(p.performerMatchDismissed == false)
        #expect(try rowShowsTheMatch(p))
    }

    @Test func dismissingTurnsTheCorrectionOffRatherThanHidingIt() throws {
        let ctx = ModelContext(try container())
        let p = coldShow(ctx)
        _ = PrepImporter.ingest(prepResults(p.naturalKey, performer: "Larkin Sable"),
                                into: ctx, clients: [vega], history: [])

        p.dismissPerformerMatch()

        #expect(p.relationshipCorrectedByPerformerMatch == false)   // never both at once
        #expect(p.performerMatchDismissed)
        #expect(try rowShowsTheMatch(p) == false)
        #expect(p.priorRelationship == "none")   // and the warm score went with it
    }

    @Test func confirmingKeepsItVisible() throws {
        let ctx = ModelContext(try container())
        let p = coldShow(ctx)
        _ = PrepImporter.ingest(prepResults(p.naturalKey, performer: "Larkin Sable"),
                                into: ctx, clients: [vega], history: [])

        p.confirmPerformerMatch()

        #expect(p.relationshipCorrectedByPerformerMatch)
        #expect(p.performerMatchDismissed == false)
        #expect(try rowShowsTheMatch(p))
    }

    // The scout's own path: a fresh confident ORG match supersedes the performer guess and wipes the
    // whole finding, so the pair goes to false together rather than half-clearing.
    @Test func aSupersedingOrgMatchClearsBothTogether() throws {
        let ctx = ModelContext(try container())
        let p = coldShow(ctx)
        _ = PrepImporter.ingest(prepResults(p.naturalKey, performer: "Larkin Sable"),
                                into: ctx, clients: [vega], history: [])

        p.clearPerformerMatch()

        #expect(p.relationshipCorrectedByPerformerMatch == false)
        #expect(p.performerMatchDismissed == false)
        #expect(p.performerMatchNote == nil)
        #expect(try rowShowsTheMatch(p) == false)
    }

    // MARK: - The worry behind the issue

    // The failure #1466 is really about: a genuine SECOND finding on a group Dan already corrected once
    // must still reach him. Dismissing the first match keeps the rejected performer's name (so the same
    // evidence cannot resurrect it) but must not deafen the show to a different performer entirely.
    @Test func aSecondFindingOnAShowWhoseFirstMatchWasRejectedStillReachesDan() throws {
        let ctx = ModelContext(try container())
        let p = coldShow(ctx)
        _ = PrepImporter.ingest(prepResults(p.naturalKey, performer: "Larkin Sable"),
                                into: ctx, clients: [vega], history: [])
        p.dismissPerformerMatch()
        try ctx.save()
        #expect(try rowShowsTheMatch(p) == false)

        // A later Prep run finds a DIFFERENT performer on the same show, who is also a past client.
        _ = PrepImporter.ingest(prepResults(p.naturalKey, performer: "Aki Tanaka"),
                                into: ctx, clients: [vega, tanaka], history: [])

        #expect(p.relationshipCorrectedByPerformerMatch)
        #expect(p.performerMatchDismissed == false)
        #expect(p.matchedPerformerName == "Aki Tanaka")
        #expect(p.performerMatchReviewed == false)   // a finding Dan has not judged yet
        #expect(try rowShowsTheMatch(p))
    }
}

// The invariant itself, as a source fact rather than a behaviour (#1466). The suite above drives every
// path that exists TODAY; this is what keeps the state unreachable as the code changes, because a new
// writer of the lock would be invisible to every test until someone thought to write one for it.
@Suite("Nothing can hold a performer-match correction and its rejection at once (#1466)")
struct PerformerMatchLockPairingGuardTests {
    private func source(_ rel: String, file: StaticString = #filePath) -> String {
        SourceGuardHelper.source(rel, file: file)
    }

    // Exactly one place turns the lock ON, and it clears the rejection in the same straight run of
    // statements. Two writers would mean a second place to forget the reset.
    @Test func theOnlyPlaceThatTakesTheLockAlsoClearsTheRejection() {
        let importer = source("Overture/Persistence/PrepImporter.swift")
        let prospect = source("Overture/Domain/Prospect.swift")

        #expect(importer.components(separatedBy: "relationshipCorrectedByPerformerMatch = true").count - 1 == 1)
        #expect(prospect.contains("relationshipCorrectedByPerformerMatch = true") == false)
        let applied = importer.components(separatedBy: "p.relationshipCorrectedByPerformerMatch = true")[1]
            .prefix(400)
        #expect(applied.contains("p.performerMatchDismissed = false"))
        #expect(applied.contains("guard") == false)   // nothing can skip the reset
        #expect(applied.contains("if ") == false)
    }

    // And the rejection is only ever set while the lock is being released in the same method.
    @Test func theOnlyPlaceThatRecordsARejectionAlsoReleasesTheLock() {
        let prospect = source("Overture/Domain/Prospect.swift")
        #expect(prospect.components(separatedBy: "performerMatchDismissed = true").count - 1 == 1)
        let rejected = prospect.components(separatedBy: "performerMatchDismissed = true")[0].suffix(200)
        #expect(rejected.contains("relationshipCorrectedByPerformerMatch = false"))
    }
}
