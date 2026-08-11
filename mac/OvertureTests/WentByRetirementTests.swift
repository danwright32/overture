import Testing
import Foundation
import SwiftData

// #864: a show that quietly goes by was never cleaned up, only hidden.
//
// #861 stopped COUNTING shows that had already happened, so Dan's Scout backlog reads correctly again.
// But those 25 June shows are still in the store, still marked `new`, and always will be: nothing ever
// retires an untriaged show that simply went by. Today that is only untidy. But the store grows
// monotonically with rows in a state that can never be resolved, and any FUTURE feature that asks "what
// has Overture never triaged?" gets the same wrong answer #861 got, in a new place, for the same reason.
// #861 taught one caller to ask better. The underlying data is still lying.
//
// So a show whose last night has passed without a decision is retired at launch: dismissed, with a
// reason of its own ("Went by"), which is the honest record. It is a fact about the calendar, not a
// judgement Dan made, so it must never read as one: not in his Dismissed list, which is where he undoes
// a cut HE made by mistake (#28), and not in the history that teaches the next scout what he likes.
@MainActor
@Suite("A show that quietly went by is retired, not left to rot (#864)")
struct WentByRetirementTests {
    private let today = ScoutTestClock.wentByRetirementAnchor

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func show(_ ctx: ModelContext, _ key: String, date: String?, runEnd: String? = nil,
                      status: ReviewStatus = .new) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: key, discipline: "music", venue: "Merkin Hall",
                         performanceDate: date, sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: status)
        p.runEndDate = runEnd
        ctx.insert(p)
        return p
    }

    // MARK: - What gets retired

    @Test func anUntriagedShowWhoseLastNightHasPassedIsRetired() throws {
        let ctx = try context()
        let june = show(ctx, "june", date: "2026-06-27")

        let retired = WentByRetirement.run(in: ctx, today: today)

        #expect(retired == 1)
        #expect(june.status == .dismissed)
        #expect(june.showOutcome == .wentBy)
    }

    @Test func aShowStillToComeIsLeftAlone() throws {
        let ctx = try context()
        let september = show(ctx, "september", date: "2026-09-19")

        #expect(WentByRetirement.run(in: ctx, today: today) == 0)
        #expect(september.status == .new)
    }

    // #1540, REVERSING what this test used to assert: a run that OPENED on an earlier day is retired,
    // even though it plays for another eight nights. Dan's ruling (2026-07-26) is that a client's need
    // for photos is over once they have opened, so an untriaged opened run is not a lead he will ever
    // work. He chose archiving it over leaving it in the store as `new`, so that the one rule behind the
    // Scout pill, the triage list and this sweep stays one rule, with no invisible class in between.
    @Test func aRunThatOpenedOnAnEarlierDayIsRetired() throws {
        let ctx = try context()
        let running = show(ctx, "run", date: "2026-07-09", runEnd: "2026-07-20")

        #expect(WentByRetirement.run(in: ctx, today: today) == 1)
        #expect(running.status == .dismissed)
        #expect(running.showOutcome == .wentBy)
    }

    // The other side of Dan's cut, and the reason it is `days < 0` and not `days < 1`: a run OPENING
    // tonight has not started. It is still his to decide on, and the sweep must not take it.
    @Test func aRunOpeningTonightIsStillHisToDecide() throws {
        let ctx = try context()
        let opening = show(ctx, "opens-tonight", date: today, runEnd: "2026-07-20")

        #expect(WentByRetirement.run(in: ctx, today: today) == 0)
        #expect(opening.status == .new)
    }

    // An undated show is NOT past. "Date to be confirmed" is a normal state on an org's season page, and
    // retiring it would silently delete a real lead whose date simply has not been announced yet. The
    // question asked is "has it demonstrably happened", never "is it demonstrably live".
    @Test func anUndatedShowIsNeverRetired() throws {
        let ctx = try context()
        let tbc = show(ctx, "tbc", date: nil)

        #expect(WentByRetirement.run(in: ctx, today: today) == 0)
        #expect(tbc.status == .new)
    }

    // Only the UNTRIAGED rot. A show Dan kept, drafted, approved or emailed is his business and carries
    // real history; a past one he was pursuing stays exactly as it is (#133).
    @Test func aShowDanActuallyActedOnIsNeverTouched() throws {
        let ctx = try context()
        let acted: [Prospect] = [
            show(ctx, "kept", date: "2026-06-01", status: .queued),
            show(ctx, "drafted", date: "2026-06-02", status: .drafted),
            show(ctx, "approved", date: "2026-06-03", status: .approved),
            show(ctx, "emailed", date: "2026-06-04", status: .contacted),
        ]

        #expect(WentByRetirement.run(in: ctx, today: today) == 0)
        for p in acted { #expect(p.status != .dismissed, "\(p.naturalKey) was not Overture's to retire") }
    }

    // Assume it runs twice: it runs on every launch, so a second pass must find nothing left to do and
    // must not touch what the first one settled.
    @Test func runningItTwiceChangesNothingTheSecondTime() throws {
        let ctx = try context()
        let june = show(ctx, "june", date: "2026-06-27")
        show(ctx, "cut-by-dan", date: "2026-06-27", status: .dismissed).showOutcome = .notAFit

        #expect(WentByRetirement.run(in: ctx, today: today) == 1)
        #expect(WentByRetirement.run(in: ctx, today: today) == 0)
        #expect(june.showOutcome == .wentBy)
    }

    // MARK: - It must never read as a decision Dan made

    // Archive keeps them apart: "Went by" is a fact about the calendar, "Dismissed" is a cut Dan made.
    // Mixing them would bury a genuinely mistaken cut (the thing the Dismissed list exists to let him
    // undo, #28) under two dozen shows he never even looked at.
    @Test func aRetiredShowLandsInItsOwnArchiveBucketNotDismissed() throws {
        let ctx = try context()
        let june = show(ctx, "june", date: "2026-06-27")
        let cut = show(ctx, "cut", date: "2026-09-19", status: .dismissed)
        cut.showOutcome = .notAFit

        WentByRetirement.run(in: ctx, today: today)

        #expect(ArchiveStatus.of(QueueItem(june)) == .wentBy)
        #expect(ArchiveStatus.of(QueueItem(cut)) == .dismissed)
    }

    // The guarantee that matters most: it must not teach the next scout anything. A retirement is not a
    // preference, and LocalHistory feeds the prior-relationship signal that ranks future leads.
    @Test func aRetiredShowTeachesTheNextScoutNothing() throws {
        let ctx = try context()
        show(ctx, "june", date: "2026-06-27")

        WentByRetirement.run(in: ctx, today: today)
        let all = try ctx.fetch(FetchDescriptor<Prospect>())

        #expect(LocalHistory.records(from: all).isEmpty,
                "retiring a show Dan never looked at must never become a signal about the org")
    }

    // MARK: - The rule is shared, so the two halves cannot disagree

    // The Scout pill's "still waiting on Dan" and this retirement's "no longer his to work" are the same
    // question. If they ever answered it differently, a show could be retired while still being counted,
    // or counted while already retired. They are one predicate (Prospect.hasOpened), and this pins it:
    // for every untriaged show, exactly one of the two claims it, with nothing in between. #1540 moved
    // that predicate to the OPENING night, which is why `still-running` now sits with `past` rather than
    // with the shows waiting on him. Note "today" belongs to Dan, not to the sweep: a show opening
    // tonight has not started.
    @Test func everyUntriagedShowIsEitherWaitingOnDanOrRetired() throws {
        let ctx = try context()
        show(ctx, "past", date: "2026-06-27")
        show(ctx, "tonight", date: today)
        show(ctx, "future", date: "2026-09-19")
        show(ctx, "still-running", date: "2026-07-09", runEnd: "2026-07-20")
        show(ctx, "undated", date: nil)
        let all = try ctx.fetch(FetchDescriptor<Prospect>())

        let waiting = Set(StageNavigation.naturalKeys(for: .scout, in: all, context: .at(today)))
        let opened = Set(all.filter { $0.hasOpened(today: today) }.map(\.naturalKey))

        #expect(opened == Set(["past", "still-running"]))
        #expect(waiting.isDisjoint(with: opened), "a show cannot be both waiting on Dan and already open")
        #expect(waiting.union(opened) == Set(all.map(\.naturalKey)), "every untriaged show is one or the other")
    }

    // #1540 + #863: the sweep and the triage LIST are separate code (a SwiftData predicate here, the stage
    // predicate there), and a pill's number is a promise about the rows the list will render. So assert
    // them against each other on the exact row the reversal turns on, rather than trusting that two
    // hand-written date checks say the same thing. #2348 dropped a third assertion from this test, over
    // QueueModel.toSendQueue, once that filter was deleted: it was the retired copy of the same rule.
    @Test func theSweepAndTheTriageListAgreeAboutAnOpenedRun() throws {
        let ctx = try context()
        let running = show(ctx, "run", date: "2026-07-09", runEnd: "2026-07-20")

        #expect(running.hasOpened(today: today))
        #expect(StageNavigation.naturalKeys(for: .scout, in: [running], context: .at(today)).isEmpty)
    }
}
