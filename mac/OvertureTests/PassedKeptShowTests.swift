import Testing
import Foundation
import SwiftData

// #4136: nothing in the funnel noticed a show Dan KEPT whose date had gone by.
//
// An untriaged show that opens is swept to `wentBy` (#864, #1540). A kept one was deliberately left alone
// by that sweep, and from then on nothing watched its date at all: `PrepQueueBuilder.needsPrep` took
// status, draft and the two re-prep requests and no date, so a passed kept show was counted as Prep work,
// listed, and handed to a paid run; `Recipient.isSendablePending` refused on nine conditions and none of
// them was the date, so an approved pitch for a performance that was over could still go out.
//
// Dan's call, 2026-09-24 (in session, picker answer): sweep them automatically. So:
//   1. a kept show whose LAST night has passed is not Prep work (count, list, button gate, handoff file);
//   2. the send gate refuses a pending email on such a show, and says why;
//   3. "Performance passed" is no longer drawn in the faint colour, decided for the whole urgency enum;
//   4. passed kept shows that were never pitched are swept, with a reason that teaches the ranker nothing.
//
// "Last night", never the opening night: a kept run that has opened keeps working (#1540 kept `underway`
// for exactly that case), so the line for a KEPT show is the run's closing night, the same line the
// "Performance passed" label is drawn on (`EasternDate.lastNightHasPassed`).

private func makeContext() throws -> ModelContext {
    ModelContext(try ModelContainer(
        for: Schema([Prospect.self, Recipient.self, PromotedProducer.self, DemotedHouse.self]),
        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
}

@discardableResult
private func makeShow(_ ctx: ModelContext, _ key: String, status: ReviewStatus,
                      date: String?, runEnd: String? = nil, hasDraft: Bool = false) -> Prospect {
    let p = Prospect(naturalKey: key, groupName: key, discipline: "music", venue: "Merkin Hall",
                     performanceDate: date, sourceListingURL: nil,
                     priorRelationship: "none", production: "self", profile: "strong",
                     coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                     matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                     status: status)
    p.runEndDate = runEnd
    if hasDraft {
        p.draftSubject = "Photographing your concert"
        p.draftBody = "Hello,\n\nI'd love to photograph the concert."
    }
    ctx.insert(p)
    return p
}

// MARK: - 1. Prep

@MainActor
@Suite("A kept show whose last night has passed is not Prep work (#4136)")
struct PassedKeptShowLeavesPrepTests {
    private let today = "2026-09-24"

    @Test func theSharedPredicateRefusesAPassedShowAndOnlyThat() {
        #expect(!PrepQueueBuilder.needsPrep(status: .queued, hasDraft: false, lastNightHasPassed: true))
        #expect(PrepQueueBuilder.needsPrep(status: .queued, hasDraft: false, lastNightHasPassed: false))
        // A re-prep request does not revive it either: there is nothing left to pitch or research for.
        #expect(!PrepQueueBuilder.needsPrep(status: .drafted, hasDraft: true, reprepDraftRequested: true,
                                            lastNightHasPassed: true))
        #expect(!PrepQueueBuilder.needsPrep(status: .contacted, hasDraft: true, reprepDraftRequested: true,
                                            lastNightHasPassed: true))
    }

    @Test func theLineIsTheLastNightNotTheOpeningNight() throws {
        let ctx = try makeContext()
        let over = makeShow(ctx, "over", status: .queued, date: "2026-09-20")
        let closesTonight = makeShow(ctx, "closes-tonight", status: .queued, date: "2026-09-18",
                                     runEnd: today)
        let underway = makeShow(ctx, "underway", status: .queued, date: "2026-09-20", runEnd: "2026-10-04")
        let undated = makeShow(ctx, "undated", status: .queued, date: nil)
        let ahead = makeShow(ctx, "ahead", status: .queued, date: "2026-10-10")

        #expect(!PrepQueueBuilder.needsPrepEligible(over, today: today))
        #expect(PrepQueueBuilder.needsPrepEligible(closesTonight, today: today))
        #expect(PrepQueueBuilder.needsPrepEligible(underway, today: today))
        // "Date to be confirmed" is a normal listing state, never a passed one (#798).
        #expect(PrepQueueBuilder.needsPrepEligible(undated, today: today))
        #expect(PrepQueueBuilder.needsPrepEligible(ahead, today: today))
    }

    // The handoff file the paid run actually consumes, built by the code that writes it.
    @Test func theHandoffFileLeavesItOut() throws {
        let ctx = try makeContext()
        makeShow(ctx, "over", status: .queued, date: "2026-09-20")
        makeShow(ctx, "ahead", status: .queued, date: "2026-10-10")
        try ctx.save()

        let queue = PrepQueueService.buildQueue(
            from: ctx, generatedAt: "2026-09-24T12:00:00.000Z", today: today,
            venueHistory: VenueShootHistory(shoots: [], bookings: [], today: today))

        #expect(queue.items.map(\.naturalKey) == ["ahead"])
    }

    // The Prep pill's number and the rows it lands on.
    @Test func thePrepPillNeitherCountsNorListsIt() throws {
        let ctx = try makeContext()
        makeShow(ctx, "over", status: .queued, date: "2026-09-20")
        makeShow(ctx, "ahead", status: .queued, date: "2026-10-10")
        try ctx.save()
        let all = try ctx.fetch(FetchDescriptor<Prospect>())
        let context = StageContext(geo: .none, clients: .none, today: today)

        #expect(StageNavigation.counts(in: all, context: context)[.prep] == 1)
        #expect(StageNavigation.naturalKeys(for: .prep, in: all, context: context) == ["ahead"])
    }

    // RootView's "Prep kept" gate reads a SwiftData @Query, which cannot carry a clock that moves, so the
    // query fetches the status half and `eligible(_:today:)` applies the whole rule over it. This is the
    // function that gate reads.
    @Test func thePrepKeptGateLeavesItOut() throws {
        let ctx = try makeContext()
        makeShow(ctx, "over", status: .queued, date: "2026-09-20")
        makeShow(ctx, "ahead", status: .queued, date: "2026-10-10")
        try ctx.save()
        let fetched = try ctx.fetch(FetchDescriptor<Prospect>(predicate: PrepQueueBuilder.needsPrepPredicate))
        #expect(fetched.count == 2, "the fixture did not reach the query, so nothing was compared")

        #expect(PrepQueueBuilder.eligible(fetched, today: today).map(\.naturalKey) == ["ahead"])
    }
}

// MARK: - 2. Send

@MainActor
@Suite("The send gate refuses a pending email on a show that has passed, and says why (#4136)")
struct PassedShowSendGateTests {
    private let today = "2026-09-24"

    private func approvedShow(_ ctx: ModelContext, date: String) -> Recipient {
        let p = makeShow(ctx, "show-\(date)", status: .approved, date: date, hasDraft: true)
        let r = Recipient(id: "jane@aurora.example", email: "jane@aurora.example", provenance: .act)
        p.recipients = [r]
        return r
    }

    @Test func aPendingEmailOnAPassedShowIsNotSendable() throws {
        let ctx = try makeContext()
        let passed = approvedShow(ctx, date: "2026-09-20")
        let ahead = approvedShow(ctx, date: "2026-10-10")

        // Non-vacuous: the same fixture on a show still to come IS sendable, so the date is what refuses.
        #expect(ahead.isSendablePending(today: today))
        #expect(!passed.isSendablePending(today: today))
    }

    // Not held for a review either: nothing Dan can glance at releases it, and counting it as held would
    // keep the show reading as waiting on him (#792's distinction).
    @Test func itIsNotCountedAsHeldForACheck() throws {
        let ctx = try makeContext()
        let passed = approvedShow(ctx, date: "2026-09-20")
        #expect(!passed.isBlockedAwaitingReview)
    }

    @Test func theNoteBesideTheButtonSaysWhy() {
        #expect(DraftReviewNotes.performancePassed(performanceDate: "2026-09-20", runEndDate: nil,
                                                   today: today) != nil)
        #expect(DraftReviewNotes.performancePassed(performanceDate: "2026-09-20", runEndDate: "2026-10-04",
                                                   today: today) == nil)
        #expect(DraftReviewNotes.performancePassed(performanceDate: nil, runEndDate: nil, today: today) == nil)
    }
}

// MARK: - 3. The timing colour, for the whole urgency enum

@Suite("The timing colour rule covers every urgency, and a passed show is not drawn faint (#4136)")
struct TimingToneTests {
    @Test func theExceptionsAreNotTheQuietestThingOnTheRow() {
        #expect(QueueModel.timingTone(.past, on: .queue) != .quiet)
        #expect(QueueModel.timingTone(.tooSoon, on: .queue) != .quiet)
        #expect(QueueModel.timingTone(.imminent, on: .queue) == .actNow)
        #expect(QueueModel.timingTone(.underway, on: .queue) == .actNow)
        #expect(QueueModel.timingTone(.booked, on: .queue) == .confirmed)
        // The ordinary case keeps the quiet treatment, so the exceptions stand out against it (L609).
        #expect(QueueModel.timingTone(.soon, on: .queue) == .quiet)
        #expect(QueueModel.timingTone(.ahead, on: .queue) == .quiet)
        #expect(QueueModel.timingTone(.unknown, on: .queue) == .quiet)
    }

    // Dan's call, 2026-09-24 (in session, picker answer "Rust only in the queue"): in Archive a passed
    // date is the ordinary state, so "Performance passed" there is quiet, while the queue draws it rust.
    @Test func archiveDrawsAPassedShowQuietWhileTheQueueDrawsItRust() {
        #expect(QueueModel.timingTone(.past, on: .queue) == .actNow)
        #expect(QueueModel.timingTone(.past, on: .archive) == .quiet)
        #expect(QueueModel.timingTone(.tooSoon, on: .archive) == .quiet)
    }

    // Archive is the queue's rule with ONE difference, derived here rather than restated: every urgency
    // reads the same on both surfaces except the two that are only exceptional where work is still owed.
    @Test func archiveDiffersFromTheQueueOnlyWhereAPassedDateIsNormal() {
        let all: [QueueModel.Urgency] = [.past, .tooSoon, .imminent, .soon, .ahead, .unknown, .booked, .underway]
        let differing = all.filter { QueueModel.timingTone($0, on: .archive) != QueueModel.timingTone($0, on: .queue) }
        #expect(differing == [.past, .tooSoon])
    }

    // Each surface names itself where it builds the row, and the row paints from the rule.
    @Test func eachSurfaceHandsTheRowItsOwnName() throws {
        let ui = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Overture/UI")
        let archive = try String(contentsOf: ui.appendingPathComponent("ArchiveView.swift"), encoding: .utf8)
        let queue = try String(contentsOf: ui.appendingPathComponent("QueueView.swift"), encoding: .utf8)
        #expect(archive.contains("timingSurface: .archive"), "Archive no longer tells the row it is Archive")
        #expect(queue.contains("timingSurface: .queue"), "the queue no longer tells the row it is the queue")
    }

    // The label and the rules above agree about which shows have passed, because both read one helper.
    @Test func theLabelIsDrawnOnTheSameLineThePrepAndSendRulesUse() {
        let t = QueueModel.outreachTiming(performanceDate: "2026-09-18", runEndDate: "2026-09-23",
                                          today: "2026-09-24")
        #expect(t.urgency == .past)
        #expect(EasternDate.lastNightHasPassed(performanceDate: "2026-09-18", runEndDate: "2026-09-23",
                                               today: "2026-09-24"))
    }

    // The row draws its colour FROM this rule, rather than keeping a second list of urgencies beside it.
    @Test func theRowReadsTheRuleRatherThanComparingUrgencies() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Overture/UI/ProspectRowView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(!source.isEmpty)
        #expect(source.contains("QueueModel.timingTone(timing.urgency, on: timingSurface)"),
                "the timing label no longer takes its colour from QueueModel.timingTone")
        #expect(!source.contains("timing.urgency =="),
                "the row compares urgencies itself again, which is how five of them ended up faint")
    }
}

// MARK: - 4. The sweep

@MainActor
@Suite("A passed kept show that was never pitched is swept, teaching the ranker nothing (#4136)")
struct PassedKeptRetirementTests {
    private let today = "2026-09-24"

    @Test func keptDraftedAndApprovedShowsThatPassedAreSwept() throws {
        let ctx = try makeContext()
        let kept = makeShow(ctx, "kept", status: .queued, date: "2026-09-20")
        let drafted = makeShow(ctx, "drafted", status: .drafted, date: "2026-09-20", hasDraft: true)
        let approved = makeShow(ctx, "approved", status: .approved, date: "2026-09-10",
                                runEnd: "2026-09-23", hasDraft: true)

        #expect(PassedKeptRetirement.run(in: ctx, today: today) == 3)
        for p in [kept, drafted, approved] {
            #expect(p.status == .dismissed, "\(p.naturalKey) was not swept")
            #expect(p.showOutcome == .wentByUnpitched, "\(p.naturalKey) carries \(String(describing: p.showOutcome))")
            #expect(p.dismissedAt != nil)
        }
    }

    @Test func everythingElseIsLeftAlone() throws {
        let ctx = try makeContext()
        let ahead = makeShow(ctx, "ahead", status: .queued, date: "2026-10-10")
        let underway = makeShow(ctx, "underway", status: .drafted, date: "2026-09-20", runEnd: "2026-10-04",
                                hasDraft: true)
        let undated = makeShow(ctx, "undated", status: .queued, date: nil)
        // Untriaged shows are the other sweep's, judged on the opening night (#1540).
        let untriaged = makeShow(ctx, "untriaged", status: .new, date: "2026-09-20")
        let contacted = makeShow(ctx, "contacted", status: .contacted, date: "2026-09-20", hasDraft: true)
        contacted.sentAt = Date(timeIntervalSince1970: 1_789_000_000)
        // Partly sent: one contact went out, another is still pending. It WAS pitched, so "went by before
        // it was pitched" would be false of it.
        let partlySent = makeShow(ctx, "partly-sent", status: .approved, date: "2026-09-20", hasDraft: true)
        let went = Recipient(id: "a@aurora.example", email: "a@aurora.example", provenance: .act)
        went.sendState = .sent
        partlySent.recipients = [went,
                                 Recipient(id: "b@aurora.example", email: "b@aurora.example",
                                           provenance: .presenter)]
        let cut = makeShow(ctx, "cut", status: .dismissed, date: "2026-09-20")
        cut.showOutcome = .notAFit

        #expect(PassedKeptRetirement.run(in: ctx, today: today) == 0)
        #expect(ahead.status == .queued)
        #expect(underway.status == .drafted)
        #expect(undated.status == .queued)
        #expect(untriaged.status == .new)
        #expect(contacted.status == .contacted)
        #expect(partlySent.status == .approved)
        #expect(cut.showOutcome == .notAFit)
    }

    @Test func aSecondPassFindsNothing() throws {
        let ctx = try makeContext()
        makeShow(ctx, "kept", status: .queued, date: "2026-09-20")
        #expect(PassedKeptRetirement.run(in: ctx, today: today) == 1)
        #expect(PassedKeptRetirement.run(in: ctx, today: today) == 0)
    }

    // It rides the same tick as the went-by sweep, so a show that passes while the app is open does not
    // wait for a relaunch.
    @Test func itRunsOnTheReconcileTick() throws {
        let ctx = try makeContext()
        let show = makeShow(ctx, "kept-on-the-tick", status: .queued, date: "2096-10-01")
        let scheduler = ReconcileScheduler(context: ctx, replyRunAlive: { _ in false })

        #expect(scheduler.retireShowsThatOpened(now: Date(timeIntervalSince1970: 3_999_000_000)).count == 0)
        #expect(show.status == .queued)
        #expect(scheduler.retireShowsThatOpened(now: Date(timeIntervalSince1970: 4_000_000_000)).count == 1)
        #expect(show.showOutcome == .wentByUnpitched)
    }

    // And at launch, beside the went-by sweep.
    @Test func itRunsAtLaunch() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Overture/Domain/LaunchMigrations.swift")
        let lines = SwiftSource.scannableLines(in: try String(contentsOf: url, encoding: .utf8))
        #expect(!lines.isEmpty)
        #expect(lines.contains { $0.code.contains("PassedKeptRetirement.run(in: context)") },
                "the launch pass no longer sweeps passed kept shows")
    }

    // The reason is Overture's own, like `wentBy`: never on a menu, in no reported group, and nothing in
    // the history the scout learns from.
    @Test func theReasonTeachesTheRankerNothing() throws {
        let ctx = try makeContext()
        let p = makeShow(ctx, "kept", status: .queued, date: "2026-09-20")
        PassedKeptRetirement.run(in: ctx, today: today)

        #expect(ShowOutcome.wentByUnpitched.isOverturesOwn)
        #expect(!ShowOutcome.danCanChoose.contains(.wentByUnpitched))
        #expect(ShowOutcome.wentByUnpitched.group == nil)
        #expect(LocalHistory.records(from: [p]).isEmpty)
    }

    // Archive files it with the other calendar retirement, never among the cuts Dan made (#28), and the
    // row offers no Restore for either.
    @Test func archiveFilesItWithTheWentByShows() throws {
        let ctx = try makeContext()
        let p = makeShow(ctx, "kept", status: .queued, date: "2026-09-20")
        PassedKeptRetirement.run(in: ctx, today: today)
        #expect(ArchiveStatus.of(QueueItem(p)) == .wentBy)
        #expect(ShowOutcome.wentByUnpitched.isCalendarRetirement)
        #expect(ShowOutcome.wentBy.isCalendarRetirement)
        #expect(ShowOutcome.allCases.filter(\.isCalendarRetirement) == [.wentBy, .wentByUnpitched])
    }

    // A later night of the same show is a night Dan has not seen go by, and he did want the show.
    @Test func aNewNightReopensIt() {
        #expect(ShowOutcome.wentByUnpitched.newNightReopens)
    }

    // The stored raw value decodes back, through a real store.
    @Test func theStoredValueSurvivesARoundTrip() throws {
        let ctx = try makeContext()
        makeShow(ctx, "kept", status: .queued, date: "2026-09-20")
        PassedKeptRetirement.run(in: ctx, today: today)
        try ctx.save()

        let fresh = ModelContext(ctx.container)
        let back = try fresh.fetch(FetchDescriptor<Prospect>()).first
        #expect(back?.showOutcomeRaw == "went_by_unpitched")
        #expect(back?.showOutcome == .wentByUnpitched)
    }
}
