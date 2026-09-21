import Testing
import Foundation
import SwiftData

// #4040: the `samedatevenue:` prefix is a namespace this app reserves for ids it mints ITSELF, and
// `matchByConcertIdentity` re-keys on one with no title check and no run overlap check on the strength
// of that. The arm's header states the reason outright:
//
//   Gated on isMerged, and the synthetic id is minted only for a mergeSameDateVenue source, so it can
//   NEVER fuse two genuinely different shows.
//
// That is a claim about MINTING, which is a statement about every writer, and `SameDateVenueMerge.isMerged`
// is a bare `hasPrefix`, which asks nothing about who wrote the string. The two are different questions and
// only the first was ever checked: `MergedIdArbitraryPickTests`'s header enumerates where this app
// CONSTRUCTS the prefix and concludes the premise holds.
//
// A string can arrive already carrying it. `docs/scout-extract-runbook.md` 3b instructs the extract run, in
// capitals, to "copy its value VERBATIM into `seriesId`", and that value rides `ScoutExtractEvent` to
// `ExtractedEvent` to `Prospect.seriesId` with nothing stripping, rejecting or namespacing it. So a page
// is able to hand Overture a value that disables every corroboration on a re-key, which carries a stored
// row's dismissal, its recipients, its sent record and its thread id onto whatever the listing is (#797).
//
// Not a live incident: measured 2026-09-20, 9 rows carry a synthetic id, none is held by more than one row,
// and no stored value looks forged. This is the namespace being owned rather than assumed (L452, L506).
@MainActor
@Suite("The samedatevenue namespace cannot be forged from outside (#4040)")
struct ReservedSeriesIdNamespaceTests {

    private static let venue = "Weill Recital Hall"
    private static let night = "2026-11-14"

    // THE DOOR THE RUNBOOK OPENS. An id copied off a page verbatim must not be able to claim a namespace
    // this app reserves for itself, so the wire type disowns it on the way in.
    //
    // Disowned rather than the whole event refused: the show is real and Dan should still see it. What is
    // untrustworthy is one field, and dropping it costs the row nothing but a run collapse it was never
    // entitled to (L93: name what the fallback gets wrong, which is that a genuine feed id spelled this way
    // would be lost, and no ticketing platform mints one, because the prefix is ours).
    @Test func anExtractReadIdCannotClaimTheReservedPrefix() {
        let forged = ScoutExtractEvent(title: "A Recital", venue: Self.venue,
                                       performanceDate: Self.night,
                                       seriesId: SameDateVenueMerge.syntheticSeriesId(date: Self.night,
                                                                                      venue: Self.venue))

        #expect(forged.asExtractedEvent.seriesId == nil,
                "a value copied off a page claimed the namespace this app reserves for ids it mints")
    }

    // An ORDINARY feed id is untouched, so the disown above is not a filter that quietly drops the real
    // thing it was written to protect (L104: an over match reads as the guard working).
    @Test func arealFeedIdIsCarriedThroughUntouched() {
        let real = ScoutExtractEvent(title: "A Recital", venue: Self.venue,
                                     performanceDate: Self.night, seriesId: "run-1")

        #expect(real.asExtractedEvent.seriesId == "run-1")
    }

    // THE READER, which is the half no call site can forget. Even where a forged value reaches the arm by
    // some door nobody has thought of, it may only re-key rows whose date and venue it actually names.
    //
    // A synthetic id IS its row's date and venue, so demanding that it matches them takes nothing away from
    // the path this branch exists for (#1260, a concert whose NAME changed on one date at one room) and
    // removes every case where the id says something the row does not.
    @Test func amergedIdThatNamesAnotherNightIsNotTreatedAsMerged() {
        let elsewhere = SameDateVenueMerge.syntheticSeriesId(date: "2026-12-25", venue: Self.venue)

        #expect(SameDateVenueMerge.isMerged(elsewhere, naming: Self.night, venue: Self.venue) == false,
                "an id naming a different night was accepted as this row's own merged identity")
    }

    @Test func amergedIdThatNamesAnotherVenueIsNotTreatedAsMerged() {
        let elsewhere = SameDateVenueMerge.syntheticSeriesId(date: Self.night, venue: "Zankel Hall")

        #expect(SameDateVenueMerge.isMerged(elsewhere, naming: Self.night, venue: Self.venue) == false,
                "an id naming a different venue was accepted as this row's own merged identity")
    }

    // The path this branch is FOR still works, or the two above would be satisfied by a check that refuses
    // everything (L159: a test asserting something did not happen is satisfied by a fixture where it could
    // not, so the positive has to fire in the same shape).
    @Test func agenuineSyntheticIdForThisRowIsStillMerged() {
        let own = SameDateVenueMerge.syntheticSeriesId(date: Self.night, venue: Self.venue)

        #expect(SameDateVenueMerge.isMerged(own, naming: Self.night, venue: Self.venue),
                "the id this row's own date and venue mint was refused, which disables the #1260 path")
    }

    // Folded, not raw. The venue arrives spelled however the page spelled it, and `syntheticSeriesId` already
    // folds it through `VenueNormalization`, so the check has to fold the same way or one respelling defeats
    // the guard written for the other (#1686 is the same defect on `sameVenue`).
    @Test func avenueSpeltDifferentlyStillMatchesItsOwnId() {
        let own = SameDateVenueMerge.syntheticSeriesId(date: Self.night, venue: "Weill Recital Hall")

        #expect(SameDateVenueMerge.isMerged(own, naming: Self.night, venue: "WEILL RECITAL HALL "),
                "one respelling of the room defeated the check, which is the #1686 defect")
    }

    // THROUGH THE REAL `apply`, which is what this issue asks for: the predicate above is only a claim
    // about a function until the pipeline is seen to act on it (#4040's own direction, and the pattern
    // `SeasonPageStableSourceTests` set for #4032).
    //
    // The forged id names a night in December. The stored row and the incoming listing both carry it and
    // both play in November, and their titles are nothing like each other. Before the anchoring, the bare
    // prefix test accepted it, the branch skipped its title check and its run overlap check, and the stored
    // row was re-keyed onto a show with no relation to it, carrying its dismissal with it (#797).
    @Test func aforgedIdCannotRekeyAStoredRowThroughTheRealApply() throws {
        let ctx = try context()
        let forged = SameDateVenueMerge.syntheticSeriesId(date: "2026-12-25", venue: Self.venue)
        let stored = row(ctx, title: "Jinhyung Park", seriesId: forged)
        stored.markDismissed(reason: .dontWantToShoot)
        try ctx.save()

        // The fixture really is one the branch WOULD have taken, or a pass here says nothing (L159).
        #expect(SameDateVenueMerge.isMerged(forged),
                "the fixture's id does not carry the reserved prefix, so the branch under test is not reached")

        let incoming = ExtractedEvent(title: "An Evening of Piano", presenter: "Carnegie Hall",
                                      venue: Self.venue, performanceDate: Self.night,
                                      sourceUrl: nil, seriesId: forged)
        _ = ScoutService.apply(events: [incoming], clients: [], history: [], blocked: .empty,
                               today: "2026-10-01", sourceIds: ["carnegiehall-org"], into: ctx)
        try ctx.save()

        let rows = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(rows.count == 2,
                Comment(rawValue: "expected the forged id to be refused and the show inserted as its own "
                        + "row, got \(rows.count): \(rows.map(\.groupName).sorted())"))
        #expect(rows.contains { $0.groupName == "Jinhyung Park" },
                "the stored row was re-keyed onto an unrelated show and its dismissal went with it")
    }

    // The SAME shape with an id that genuinely names this row, so the two above cannot be satisfied by a
    // branch that now refuses everything (L159 again, from the other side).
    @Test func agenuineIdStillRekeysThroughTheRealApply() throws {
        let ctx = try context()
        let own = SameDateVenueMerge.syntheticSeriesId(date: Self.night, venue: Self.venue)
        _ = row(ctx, title: "Jinhyung Park", seriesId: own)
        try ctx.save()

        let incoming = ExtractedEvent(title: "An Evening of Piano", presenter: "Carnegie Hall",
                                      venue: Self.venue, performanceDate: Self.night,
                                      sourceUrl: nil, seriesId: own)
        _ = ScoutService.apply(events: [incoming], clients: [], history: [], blocked: .empty,
                               today: "2026-10-01", sourceIds: ["carnegiehall-org"], into: ctx)
        try ctx.save()

        let rows = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(rows.count == 1,
                Comment(rawValue: "the #1260 path stopped recognising a concert whose name changed on its "
                        + "own night at its own room, leaving \(rows.count) rows"))
    }

    private func context() throws -> ModelContext {
        let schema = Schema([Prospect.self, Recipient.self])
        return ModelContext(try ModelContainer(for: schema,
                            configurations: [ModelConfiguration(schema: schema,
                                                                isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func row(_ ctx: ModelContext, title: String, seriesId: String) -> Prospect {
        let key = Prospect.makeNaturalKey(groupName: title, performanceDate: Self.night,
                                          venue: Self.venue)
        let p = Prospect(naturalKey: key, groupName: title, discipline: "music", venue: Self.venue,
                         performanceDate: Self.night, sourceListingURL: nil,
                         priorRelationship: "none", production: "unknown", profile: "unknown",
                         coverage: "unknown", fitScore: 3, tier: "medium", fitReason: "",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         runEndDate: nil, partOfRelatedRun: false, runSourceURLs: [],
                         runNights: [Self.night])
        p.seriesId = seriesId
        ctx.insert(p)
        return p
    }

    // A row with no date or no venue cannot name itself, so it can never satisfy the check. It is the same
    // direction `stamped` already takes for such a row (it refuses to stamp one) and the same direction
    // `runsOverlap` takes for an unknown date: an absent value must never authorize a re-key.
    @Test func arowThatNamesNoNightCanNeverSatisfyTheCheck() {
        let own = SameDateVenueMerge.syntheticSeriesId(date: Self.night, venue: Self.venue)

        #expect(SameDateVenueMerge.isMerged(own, naming: nil, venue: Self.venue) == false)
        #expect(SameDateVenueMerge.isMerged(own, naming: Self.night, venue: nil) == false)
    }
}
