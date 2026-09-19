import Testing
import Foundation
import SwiftData

// #3324, plan section 2: the record of which nights of a run Dan judged, and how.
//
// Every date and stamp is pinned (L130).
@MainActor
@Suite("Which nights of a run were judged, and how (#3324)")
struct NightDecisionTests {

    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private static let nights = ["2026-11-06", "2026-11-13", "2026-11-20"]

    private func container() throws -> ModelContainer {
        try ModelContainer(for: AppSchema.schema,
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func run(_ ctx: ModelContext, nights: [String] = NightDecisionTests.nights) -> Prospect {
        let p = Prospect(naturalKey: Prospect.makeNaturalKey(groupName: "Decision Revue",
                                                             performanceDate: nights.first,
                                                             venue: "Room One"),
                         groupName: "Decision Revue", discipline: "theater",
                         venue: "Room One", performanceDate: nights.first,
                         sourceListingURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 5, tier: "medium", fitReason: "",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        p.runEndDate = nights.last
        p.runNights = nights
        ctx.insert(p)
        return p
    }

    // MARK: the stored form (plan 2.2)

    @Test func anEntryRoundTrips() {
        for origin in NightDecision.Origin.allCases {
            for accepted in [nil, "bookedShoot|2026-11-13|A | tricky = name %20"] {
                let d = NightDecision(night: "2026-11-13", at: now, origin: origin, acceptedClashKey: accepted)
                #expect(NightDecision(stored: d.stored) == d, "\(d.stored) did not read back as itself")
            }
        }
    }

    // A future build appends a field. This one must still read the decision rather than drop it, which
    // is exactly what `DroppedNight`'s exact arity parser would have done (L501).
    @Test func aFieldAddedByAFutureBuildIsIgnoredRatherThanLosingTheEntry() {
        let raw = "2026-11-13|1790000000|chosen|accepted=bookedShoot%7C2026-11-13%7C|reason=late|extra"
        let d = NightDecision(stored: raw)
        #expect(d?.night == "2026-11-13")
        #expect(d?.origin == .chosen)
        #expect(d?.acceptedClashKey == "bookedShoot|2026-11-13|")
    }

    @Test func anEntryThatCannotBeReadIsDroppedAndTheNightReadsAsUnjudged() throws {
        for raw in ["", "2026-11-13", "2026-11-13|x|chosen", "2026-11-13|1790000000|maybe",
                    "not-a-date|1790000000|chosen", "2026-11-13|1790000000"] {
            #expect(NightDecision(stored: raw) == nil, "\(raw) was read as a decision")
        }
        let ctx = ModelContext(try container())
        let p = run(ctx)
        p.pitchedRunNights = ["2026-11-13|garbage|chosen"]
        #expect(p.nightState("2026-11-13") == .unjudged)
    }

    // The scan the plan asks for (2.2): the minimum arity lives HERE, and the dropped list keeps its own
    // exact arity. Nothing may widen `droppedRunNights`'s entries to carry this record's facts, which is
    // the tempting shortcut this pair of columns exists to avoid.
    @Test func theDroppedNightParserStillRequiresExactlyThreeFields() {
        let source = SourceGuardHelper.source("Overture/Domain/RunNightDrop.swift")
        #expect(!source.isEmpty, "the guard read no source, so it asserts nothing")
        #expect(SourceGuardHelper.containsCode("guard parts.count == 3,", in: source))
        #expect(DroppedNight(stored: "2026-11-13|dateConflict|1790000000|chosen") == nil)
    }

    // MARK: one night, one state (plan 2.4)

    // Every combination of the four memberships over one night lands in EXACTLY one state, and the state
    // is the one the table names. A test checking one bucket is satisfied by a night that fell out of all
    // of them (L517).
    @Test func everyCombinationOfMembershipsIsExactlyOneNamedState() throws {
        let ctx = ModelContext(try container())
        let night = "2026-11-13"
        for inRun in [true, false] {
            for pitched in [true, false] {
                for skipped in [true, false] {
                    for dropped in [true, false] {
                        let p = run(ctx, nights: inRun ? Self.nights : ["2026-11-06", "2026-11-20"])
                        p.pitchedRunNights = pitched
                            ? [NightDecision(night: night, at: now, origin: .chosen).stored] : []
                        p.skippedRunNights = skipped
                            ? [NightDecision(night: night, at: now, origin: .chosen).stored] : []
                        p.droppedRunNights = dropped
                            ? [DroppedNight(night: night, reason: .dateConflict, at: now).stored] : []
                        let state = p.nightState(night)
                        let label = "inRun \(inRun) pitched \(pitched) skipped \(skipped) dropped \(dropped)"
                        switch (inRun, pitched, skipped, dropped) {
                        case (_, _, _, true):
                            #expect(state == .dropped, Comment(rawValue: label))
                        case (true, false, false, false):
                            #expect(state == .unjudged, Comment(rawValue: label))
                        case (true, true, false, false):
                            guard case .pitched = state else { Issue.record(Comment(rawValue: label)); break }
                        case (true, false, true, false):
                            guard case .skipped = state else { Issue.record(Comment(rawValue: label)); break }
                        case (true, true, true, false):
                            #expect(state == .contradictory, Comment(rawValue: label))
                        case (false, false, false, false):
                            #expect(state == .notInRun, Comment(rawValue: label))
                        case (false, _, _, false):
                            guard case .goneFromFeed = state else { Issue.record(Comment(rawValue: label)); break }
                        }
                    }
                }
            }
        }
    }

    // MARK: the writer (plan 2.4, precedence at WRITE time)

    @Test func theWriterRefusesANightInBothListsAndWritesNothing() throws {
        let ctx = ModelContext(try container())
        let p = run(ctx)
        let d = NightDecision(night: "2026-11-13", at: now, origin: .chosen)
        #expect(throws: Prospect.NightDecisionRefusal.decidedTwice("2026-11-13")) {
            try p.recordNightDecisions(pitched: [NightDecision(night: "2026-11-06", at: now, origin: .chosen), d],
                                       skipped: [d])
        }
        #expect(p.pitchedRunNights.isEmpty, "a refused commit wrote part of itself")
        #expect(p.skippedRunNights.isEmpty)
    }

    @Test func theWriterRefusesADroppedNightAndANightTheRunDoesNotPlay() throws {
        let ctx = ModelContext(try container())
        let p = run(ctx)
        p.droppedRunNights = [DroppedNight(night: "2026-11-20", reason: .tooSoon, at: now).stored]
        #expect(throws: Prospect.NightDecisionRefusal.dropped("2026-11-20")) {
            try p.recordNightDecisions(pitched: [NightDecision(night: "2026-11-20", at: now, origin: .chosen)],
                                       skipped: [])
        }
        #expect(throws: Prospect.NightDecisionRefusal.notANightOfThisRun("2026-12-25")) {
            try p.recordNightDecisions(pitched: [NightDecision(night: "2026-12-25", at: now, origin: .chosen)],
                                       skipped: [])
        }
        #expect(p.pitchedRunNights.isEmpty)
    }

    // A night decided again replaces its entry, so moving it from pitched to skipped leaves it in one list.
    @Test func decidingANightAgainMovesItRatherThanAddingASecondEntry() throws {
        let ctx = ModelContext(try container())
        let p = run(ctx)
        try p.recordNightDecisions(pitched: Self.nights.map { NightDecision(night: $0, at: now, origin: .byDefault) },
                                   skipped: [])
        try p.recordNightDecisions(pitched: [], skipped: [NightDecision(night: "2026-11-13", at: now, origin: .chosen)])
        #expect(p.pitchedNightDecisions.map(\.night) == ["2026-11-06", "2026-11-20"])
        #expect(p.skippedNightDecisions.map(\.night) == ["2026-11-13"])
        guard case .skipped(let s) = p.nightState("2026-11-13") else { Issue.record("not skipped"); return }
        #expect(s.origin == .chosen)
        guard case .pitched(let first) = p.nightState("2026-11-06") else { Issue.record("not pitched"); return }
        #expect(first.origin == .byDefault, "a night committed with the picker closed must not read as chosen")
    }

    @Test func droppingANightRemovesItsPitchEntryInTheSameWrite() throws {
        let ctx = ModelContext(try container())
        let p = run(ctx)
        try p.recordNightDecisions(pitched: Self.nights.map { NightDecision(night: $0, at: now, origin: .chosen) },
                                   skipped: [])
        try ctx.save()
        _ = p.dropNight("2026-11-06", reason: .tooSoon, now: now, in: ctx)
        #expect(p.nightState("2026-11-06") == .dropped)
        #expect(!p.pitchedNightDecisions.contains { $0.night == "2026-11-06" },
                "a night is pitched and dropped at once")
        #expect(p.pitchedNightDecisions.map(\.night) == ["2026-11-13", "2026-11-20"])
    }

    // Plan 3.8 / L574: the drop removed the dropped night's decision entry, so its undo must put it back,
    // or undo is not the drop's inverse. Asserted as a ROUND TRIP, not the restore alone.
    @Test func undoingADropPutsTheDecisionEntriesBackExactly() throws {
        let ctx = ModelContext(try container())
        let p = run(ctx)
        try p.recordNightDecisions(pitched: [NightDecision(night: "2026-11-06", at: now, origin: .chosen),
                                             NightDecision(night: "2026-11-20", at: now, origin: .byDefault)],
                                   skipped: [NightDecision(night: "2026-11-13", at: now, origin: .chosen)])
        try ctx.save()
        let before = (p.pitchedRunNights, p.skippedRunNights, p.runNights, p.naturalKey)
        let prior = NightDecisionLists(p)
        let priorStatus = p.status, priorReason = p.showOutcomeRaw
        let priorStamp = p.showOutcomeAt, priorExit = p.dismissedAt, priorCleared = p.conflictClearedKey
        guard case .moved(_, let released) = p.dropNight("2026-11-06", reason: .tooSoon, now: now, in: ctx) else {
            Issue.record("the precondition failed: the drop did not move the run"); return
        }
        let entry = QueueUndoEntry(recording: "Dismiss", on: p, priorStatus: priorStatus,
                                   priorShowOutcomeRaw: priorReason, priorShowOutcomeAt: priorStamp,
                                   priorDismissedAt: priorExit, priorConflictClearedKey: priorCleared,
                                   droppedNights: ["2026-11-06"] + released, priorNightDecisions: prior)
        #expect(p.pitchedRunNights != before.0, "the precondition failed: the drop removed no entry")
        #expect(QueueUndo.apply(entry, to: p, in: ctx, export: (bookings: [], blockedDates: [], health: .ok)))
        #expect(p.pitchedRunNights == before.0, "the undo did not restore the pitched entries")
        #expect(p.skippedRunNights == before.1)
        #expect(p.runNights == before.2)
        #expect(p.naturalKey == before.3)
    }

    @Test func theUnjudgedNightsAreEnumerable() throws {
        let ctx = ModelContext(try container())
        let p = run(ctx)
        try p.recordNightDecisions(pitched: [NightDecision(night: "2026-11-06", at: now, origin: .chosen)],
                                   skipped: [])
        #expect(p.unjudgedNights == ["2026-11-13", "2026-11-20"])
    }

    // MARK: the scout's fold (plan 2.6)

    // The scout rewrites `runNights` wholesale. A decided night that leaves the feed keeps its entry as
    // evidence, and when it comes back it is honoured rather than asked again. Tested against a REAL
    // re-fold, not only against the writer.
    @Test func aDecisionSurvivesTheNightLeavingTheFeedAndIsHonouredWhenItReturns() throws {
        let ctx = ModelContext(try container())
        let title = "Fold Revue", venue = "Fold Room"
        let url = { (n: String) in "https://example.test/fold/\(n)" }
        let p = Prospect(naturalKey: Prospect.makeNaturalKey(groupName: title, performanceDate: Self.nights[0],
                                                             venue: venue),
                         groupName: title, discipline: "theater", venue: venue,
                         performanceDate: Self.nights[0], sourceListingURL: url(Self.nights[0]),
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "medium", fitReason: "",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         runEndDate: Self.nights.last, partOfRelatedRun: true,
                         runSourceURLs: Self.nights.map(url), runNights: Self.nights)
        ctx.insert(p)
        try p.recordNightDecisions(pitched: [NightDecision(night: "2026-11-06", at: now, origin: .chosen),
                                             NightDecision(night: "2026-11-20", at: now, origin: .chosen)],
                                   skipped: [NightDecision(night: "2026-11-13", at: now, origin: .chosen)])
        try ctx.save()

        func scout(_ nights: [String]) throws {
            let events = nights.map {
                ExtractedEvent(title: title, presenter: "Fold Players", venue: venue,
                               performanceDate: $0, sourceUrl: url($0))
            }
            _ = ScoutService.apply(events: events, clients: [], history: [], blocked: .empty,
                                   today: "2026-10-01", sourceIds: ["fold"], into: ctx)
            try ctx.save()
        }

        try scout(["2026-11-06", "2026-11-20"])     // the skipped night leaves the feed
        #expect(p.runNights == ["2026-11-06", "2026-11-20"], "the precondition: the fold really ran")
        guard case .goneFromFeed(_, let skipped?) = p.nightState("2026-11-13") else {
            Issue.record("the skip was lost when its night left the feed"); return
        }
        #expect(skipped.origin == .chosen)

        try scout(Self.nights)                        // and it comes back
        guard case .skipped = p.nightState("2026-11-13") else {
            Issue.record("a night that left and returned was not honoured"); return
        }
        #expect(p.unjudgedNights.isEmpty, "a returning night read as new")
    }
}
