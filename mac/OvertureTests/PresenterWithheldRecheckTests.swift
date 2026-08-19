import Testing
import Foundation
import SwiftData

// #2988: the shows whose contact answer was produced while the app was withholding the producing
// organisation it already held (#2983) are offered for re-checking, rather than reading "No email found"
// for the 90 days the badge trusts a stamp.
//
// Measured on the live store 2026-08-19: 23 shows read `no_email_found` and 12 of them carry a presenter
// the run was never told about. Four name an organisation that appears in no check transcript at all.
@MainActor
@Suite("Shows checked before the presenter was carried are offered again (#2988)")
struct PresenterWithheldRecheckTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func show(_ ctx: ModelContext, _ name: String, presenter: String?,
                      result: Reachability.ProbeResult?, probedAt: Date?) -> Prospect {
        let key = Prospect.makeNaturalKey(groupName: name, performanceDate: "2026-09-12",
                                          venue: "The Green Room 42")
        let p = Prospect(naturalKey: key, groupName: name, discipline: "theater",
                         venue: "The Green Room 42", performanceDate: "2026-09-12",
                         sourceListingURL: nil, websiteURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 6, tier: "mid", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .new)
        p.presenter = presenter
        p.reachabilityResult = result
        p.reachabilityProbedAt = probedAt
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    // Both ends of every comparison in this suite are pinned literals, never the live clock, so real time
    // cannot walk a fixture into a different case (L130, and #2986 the same afternoon).
    private let before = Date(timeIntervalSince1970: 1_786_492_800)   // 2026-08-12, before the boundary
    private let boundary = Date(timeIntervalSince1970: 1_787_097_600) // 2026-08-19, the boundary itself
    private let after = Date(timeIntervalSince1970: 1_787_702_400)    // 2026-08-26, after the boundary

    @Test func aShowCheckedWhileItsProducerWasWithheldIsOfferedAgain() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, "Punk Goes Broadway!", presenter: "Underbelly Theatre Company",
                     result: .noEmailFound, probedAt: before)

        let flagged = PresenterWithheldRecheck.run(in: ctx, presenterCarriedSince: boundary, now: after)

        #expect(flagged == 1)
        #expect(p.reachabilityRecheckRequestedAt == after)
    }

    // L5: the recorded answer STAYS. #2261 chose a flag over a clearing precisely so a re-check that finds
    // nothing leaves Dan no worse off than before, and this pass must not quietly choose differently.
    @Test func theRecordedAnswerIsKeptRatherThanCleared() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, "Song & Word", presenter: "Vivace Arts Collective",
                     result: .noEmailFound, probedAt: before)

        _ = PresenterWithheldRecheck.run(in: ctx, presenterCarriedSince: boundary, now: after)

        #expect(p.reachabilityResult == .noEmailFound, "the verdict must survive until a new one lands")
        #expect(p.reachabilityProbedAt == before, "the stamp is evidence, not something to destroy")
    }

    // The boundary is what makes this terminate. A show checked AFTER the presenter began being carried has
    // had its real answer, so flagging it would re-offer a correct verdict forever and spend on it (L174).
    @Test func aShowCheckedAfterTheBoundaryIsLeftAlone() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, "Checked with the name in hand", presenter: "Moore Productions",
                     result: .noEmailFound, probedAt: after)

        let flagged = PresenterWithheldRecheck.run(in: ctx, presenterCarriedSince: boundary,
                                                   now: after.addingTimeInterval(86_400))

        #expect(flagged == 0)
        #expect(p.reachabilityRecheckRequestedAt == nil)
    }

    // A show that names nobody had no producer to withhold, so its empty answer is not evidence of this
    // defect and re-checking it would spend real money to learn the same thing.
    @Test func aShowThatNamedNoProducerIsLeftAlone() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, "Broadway's Bad Guys!", presenter: nil, result: .noEmailFound, probedAt: before)
        let blank = show(ctx, "Drained to the room", presenter: "   ", result: .noEmailFound,
                         probedAt: before)

        let flagged = PresenterWithheldRecheck.run(in: ctx, presenterCarriedSince: boundary, now: after)

        #expect(flagged == 0)
        #expect(p.reachabilityRecheckRequestedAt == nil)
        // Whitespace is not a name, asked through the SAME predicate the queue builders use, so this pass
        // and the field it exists to compensate for cannot disagree about who counts as named.
        #expect(blank.reachabilityRecheckRequestedAt == nil)
    }

    // Only the empty verdict. A show that HAS an address was answered, whatever it was or was not told.
    @Test func aShowWhoseCheckFoundSomebodyIsLeftAlone() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, "Answered fine", presenter: "ICB Productions",
                     result: .emailFound, probedAt: before)

        #expect(PresenterWithheldRecheck.run(in: ctx, presenterCarriedSince: boundary, now: after) == 0)
        #expect(p.reachabilityRecheckRequestedAt == nil)
    }

    // Idempotent, and it must not move a request Dan made himself: the row reads that timestamp to decide
    // it has already acknowledged him, so overwriting it would reset an acknowledgement he has seen.
    @Test func aSecondRunChangesNothingAndNeverMovesAnExistingRequest() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, "Already asked", presenter: "Something from Abroad",
                     result: .noEmailFound, probedAt: before)
        let dansOwnRequest = before.addingTimeInterval(3_600)
        p.reachabilityRecheckRequestedAt = dansOwnRequest
        try? ctx.save()

        let flagged = PresenterWithheldRecheck.run(in: ctx, presenterCarriedSince: boundary, now: after)

        #expect(flagged == 0)
        #expect(p.reachabilityRecheckRequestedAt == dansOwnRequest)
    }

    // The count is what Dan is told before he spends anything, so it must be the rows actually changed and
    // never the rows considered (L12).
    @Test func theCountIsTheRowsItChanged() throws {
        let ctx = ModelContext(try container())
        _ = show(ctx, "One", presenter: "Underbelly Theatre Company", result: .noEmailFound, probedAt: before)
        _ = show(ctx, "Two", presenter: "Vivace Arts Collective", result: .noEmailFound, probedAt: before)
        _ = show(ctx, "Three", presenter: nil, result: .noEmailFound, probedAt: before)
        _ = show(ctx, "Four", presenter: "Moore Productions", result: .noEmailFound, probedAt: after)

        #expect(PresenterWithheldRecheck.run(in: ctx, presenterCarriedSince: boundary, now: after) == 2)
    }

    // The pass reports what it WOULD do without touching anything, so the count can be stated before any
    // decision to spend is made.
    @Test func itCanReportWithoutChangingAnything() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, "Punk Goes Broadway!", presenter: "Underbelly Theatre Company",
                     result: .noEmailFound, probedAt: before)

        let would = PresenterWithheldRecheck.candidates(in: ctx, presenterCarriedSince: boundary)

        #expect(would.map(\.groupName) == ["Punk Goes Broadway!"])
        #expect(p.reachabilityRecheckRequestedAt == nil, "reporting must not be a write")
    }

    // MARK: the boundary, and the wiring that supplies it

    // Stamped ONCE. A boundary recomputed every launch would walk forward with the clock and close the
    // window behind whichever rows had not been reached yet.
    @Test func theBoundaryIsStampedOnceAndThenNeverMoves() throws {
        let defaults = UserDefaults(suiteName: "presenter-withheld-\(UUID().uuidString)")!
        defer { defaults.removeObject(forKey: PresenterWithheldRecheck.boundaryKey) }

        let first = PresenterWithheldRecheck.boundary(defaults: defaults, now: boundary)
        let second = PresenterWithheldRecheck.boundary(defaults: defaults, now: after)

        #expect(first == boundary)
        #expect(second == boundary, "a later launch reads the stamp rather than restamping it")
    }

    // #2988's wiring, and this file's own warning applies (see LaunchMigrations' note on
    // `possibleMatchInputs`): a wiring test that cannot supply the boundary would assert against whatever
    // this Mac happened to have stamped. Both seams are driven here, and the call was confirmed load-bearing
    // by deleting it and watching this test go red.
    @Test func launchOffersTheWithheldShowsWithoutBeingAskedTwice() throws {
        let ctx = ModelContext(try container())
        let withheld = show(ctx, "Punk Goes Broadway!", presenter: "Underbelly Theatre Company",
                            result: .noEmailFound, probedAt: before)
        let named = show(ctx, "Broadway's Bad Guys!", presenter: nil,
                         result: .noEmailFound, probedAt: before)
        let defaults = UserDefaults(suiteName: "presenter-withheld-launch-\(UUID().uuidString)")!
        defer { defaults.removeObject(forKey: PresenterWithheldRecheck.boundaryKey) }

        _ = LaunchMigrations.run(in: ctx, possibleMatchInputs: { _ in nil },
                                 defaults: defaults, now: after)

        #expect(withheld.reachabilityRecheckRequestedAt == after, "launch must offer this row again")
        #expect(named.reachabilityRecheckRequestedAt == nil, "and must not offer one with no producer")
        // The verdict survives the launch pass, which is what makes it safe to run unattended (L5).
        #expect(withheld.reachabilityResult == .noEmailFound)
    }
}
