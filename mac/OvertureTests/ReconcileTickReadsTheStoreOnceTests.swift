import Testing
import Foundation
import SwiftData

// #4107: the scheduled reconcile tick held the main actor for roughly one whole store fetch per pass,
// because every pass fetched every Prospect for itself (see `StoreRows` for the measurement). The tick now
// reads the store once and hands those rows to each pass.
//
// Three things are held here:
//
// 1. Each pass handed rows READS them rather than fetching its own. Asserted the only way that can fail:
//    the pass is handed rows that deliberately DISAGREE with the store, and has to act on the rows.
// 2. Holding rows across a network await is safe. A show deleted while the pass waited on Gmail does not
//    stop the tick, and the rows still standing are applied. What keeps a deleted row out of every pass is
//    `StoreRows.isLive`, held by the first two tests below (the tick level test cannot see it: a write to a
//    deleted contact was measured to be dropped silently, so removing the filter leaves it green).
// 3. A pass whose network half fails or times out leaves its apply half UNDONE rather than half done, and
//    says so on the tick's summary, while the passes after it still run.
private let me = "dan@danwrightphotography.com"
private let gmail = GmailFixture(selfEmail: me)
private let day: TimeInterval = 86_400
private let now = Date(timeIntervalSince1970: 1_786_000_000)

private final class RecordingOmniFocusClient: OmniFocusClient, @unchecked Sendable {
    var created: [OmniFocusSync.DesiredTask] = []
    func existingOvertureTasks() throws -> [OmniFocusSync.ExistingTask] { [] }
    func completedOvertureTasks() throws -> [OmniFocusSync.ExistingTask] { [] }
    func create(_ task: OmniFocusSync.DesiredTask) throws { created.append(task) }
    func complete(_ task: OmniFocusSync.ExistingTask) throws {}
}

private struct SilentNotifier: OmniFocusNotifier {
    func notifyPermissionNeeded() {}
    func notifySyncFailed(_ message: String) {}
}

@MainActor
@Suite("A reconcile tick reads the store once and survives its network failing (#4107)")
struct ReconcileTickReadsTheStoreOnceTests {

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self, Inquiry.self, DayOff.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private func show(_ ctx: ModelContext, key: String = "k", date: String = "2026-09-01") -> Prospect {
        let p = Prospect(naturalKey: key, groupName: "G \(key)", discipline: "music", venue: "V",
                         performanceDate: date, sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        ctx.insert(p)
        return p
    }

    // A pitch through a contact form: in scope for the mailbox search, which is what the tick's reply
    // search pass reads.
    @discardableResult
    private func formPitch(_ ctx: ModelContext, on p: Prospect, daysAgo: Double = 3) -> Recipient {
        let r = Recipient(id: "form:\(p.naturalKey)", email: nil, provenance: .act)
        r.contactFormURL = "https://act.example/contact"
        r.outreachChannel = .contactForm
        r.formOutreachRecordedAt = now.addingTimeInterval(-daysAgo * day)
        r.formOutreachURL = "https://act.example/contact"
        r.sendState = .sent
        r.sentAt = now.addingTimeInterval(-daysAgo * day)
        p.addRecipient(r)
        return r
    }

    private func respond(_ req: URLRequest, _ data: Data, _ code: Int) -> (Data, URLResponse) {
        (data, HTTPURLResponse(url: req.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
    }

    private func emptyList() -> Data {
        try! JSONSerialization.data(withJSONObject: ["messages": [Any](), "resultSizeEstimate": 0])
    }

    // MARK: the rows themselves

    @Test func aRowDeletedAndSavedSinceTheReadIsNotLive() throws {
        let ctx = try context()
        let kept = show(ctx, key: "kept")
        let gone = show(ctx, key: "gone")
        try ctx.save()
        let rows = StoreRows.fetch(from: ctx)
        #expect(rows.prospects.count == 2)

        ctx.delete(gone)
        try ctx.save()

        #expect(rows.liveProspects.map(\.naturalKey) == [kept.naturalKey])
    }

    @Test func aRowDeletedAndNotYetSavedIsNotLive() throws {
        let ctx = try context()
        _ = show(ctx, key: "kept")
        let gone = show(ctx, key: "gone")
        try ctx.save()
        let rows = StoreRows.fetch(from: ctx)

        ctx.delete(gone)

        #expect(rows.liveProspects.map(\.naturalKey) == ["kept"])
    }

    // MARK: 1. a pass handed rows reads them

    @Test func theReplySearchReadsTheRowsItIsHandedRatherThanTheStore() async throws {
        let ctx = try context()
        formPitch(ctx, on: show(ctx))
        try ctx.save()
        var asked = false

        // The store holds a contact in scope; the rows handed in hold nobody. A pass that fetched for
        // itself would find the contact and call Gmail.
        let outcome = await GmailReplySearch(fromEmail: me).searchMailbox(
            in: ctx, token: "tok", now: now, defaults: ScratchDefaults.make("4107-search"),
            rows: StoreRows(prospects: [], inquiries: []),
            fetch: { req in asked = true; return self.respond(req, self.emptyList(), 200) })

        #expect(outcome == .nothingInScope)
        #expect(asked == false)
    }

    @Test func theThreadingRepairReadsTheRowsItIsHandedRatherThanTheStore() async throws {
        let ctx = try context()
        let r = Recipient(id: "them@example.com", email: "them@example.com", provenance: .act)
        r.gmailThreadId = "t1"
        r.gmailMessageId = "<AA037CFE-0D5F-4B13-8E67-5B765CD60A56@danwrightphotography.com>"
        r.sendState = .sent
        show(ctx).addRecipient(r)
        try ctx.save()
        var asked = false

        let outcome = await GmailThreadingRepair(fromEmail: me).repairMessageIds(
            in: ctx, token: "tok", rows: StoreRows(prospects: [], inquiries: []),
            fetch: { req in asked = true; return self.respond(req, Data(), 500) })

        #expect(outcome == GmailThreadingRepair.Outcome())
        #expect(asked == false)
    }

    @Test func theReplyCheckReadsTheRowsItIsHandedRatherThanTheStore() async throws {
        let ctx = try context()
        let p = show(ctx)
        let r = Recipient(id: "them@example.com", email: "them@example.com", provenance: .act)
        r.gmailThreadId = "t1"
        r.gmailMessageId = "m1"
        r.sendState = .sent
        r.sentAt = now.addingTimeInterval(-day)
        p.addRecipient(r)
        p.sentAt = now.addingTimeInterval(-day)
        try ctx.save()
        var asked = false

        let outcome = await GmailReplyChecker().markReplies(
            in: ctx, token: "tok", now: now, rows: StoreRows(prospects: [], inquiries: []),
            fetch: { req in asked = true; return self.respond(req, Data(), 500) })

        #expect(outcome.threadsChecked == 0)
        #expect(asked == false)
    }

    @Test func theConflictSweepReadsTheShowsItIsHandedRatherThanTheStore() throws {
        let ctx = try context()
        let p = show(ctx, date: "2026-11-18")
        try ctx.save()
        let booking = OvertureBooking(id: "b1", clientId: "c1", clientDisplayName: "A Client",
                                      shootName: "Nguyen Recital", startDate: "2026-11-18",
                                      endDate: "2026-11-18", venueId: nil, venueName: "V")

        ConflictSweep.reapplyAll(export: (bookings: [booking], blockedDates: [], health: .ok), in: ctx,
                                 prospects: [])

        #expect(p.hasUnclearedConflict == false, "the sweep judged a show it was not handed")
        ConflictSweep.reapplyAll(export: (bookings: [booking], blockedDates: [], health: .ok), in: ctx,
                                 prospects: [p])
        #expect(p.hasUnclearedConflict)
    }

    @Test func theOmniFocusPushReadsTheRowsItIsHandedRatherThanTheStore() async throws {
        let ctx = try context()
        let at = Date(timeIntervalSince1970: 40 * day)
        let p = show(ctx, key: "warm-lead")
        p.sentAt = Date(timeIntervalSince1970: 1)
        let r = Recipient(id: "contact@warm-lead.example", email: "contact@warm-lead.example", provenance: .act)
        r.sendState = .sent
        r.sentAt = Date(timeIntervalSince1970: 1)
        r.gmailMessageId = "m1"
        r.reopenOnReply(at: at.addingTimeInterval(-30 * day))
        p.setRecipients([r])
        try ctx.save()
        let scheduler = ReconcileScheduler(context: ctx, replyRunAlive: { _ in false })

        let handedNothing = RecordingOmniFocusClient()
        await scheduler.syncOmniFocus(now: at, client: handedNothing, horizonDays: 14, permission: .granted,
                                      notifier: SilentNotifier(),
                                      statusDefaults: ScratchDefaults.make("4107-of-a"),
                                      rows: StoreRows(prospects: [], inquiries: []))
        let handedTheShow = RecordingOmniFocusClient()
        await scheduler.syncOmniFocus(now: at, client: handedTheShow, horizonDays: 14, permission: .granted,
                                      notifier: SilentNotifier(),
                                      statusDefaults: ScratchDefaults.make("4107-of-b"),
                                      rows: StoreRows(prospects: [p], inquiries: []))

        #expect(handedNothing.created.isEmpty)
        #expect(handedTheShow.created.contains { $0.naturalKey == "warm-lead" })
    }

    // MARK: 2 and 3, through the tick itself

    // The real proposal sweep and the real mailbox search, with only Gmail faked, so what is asserted is
    // the tick's own path from the rows it read to what it reports.
    private func tick(_ ctx: ModelContext, defaults: UserDefaults,
                      clock: @escaping () -> Date = { Date() },
                      timeline: ((ReconcileTickTimeline) -> Void)? = nil,
                      mailbox: @escaping (URLRequest) async throws -> (Data, URLResponse)) async -> ReconcileSummary {
        await ReconcileScheduler(context: ctx, replyRunAlive: { _ in false }).runSafeReconcilesOnce(
            now: now, defaults: defaults,
            repairThreading: { _, _ in nil },
            sweepProposals: { context, at, rows in
                await ReplyProposalSweep(fromEmail: me).run(
                    in: context, now: at, defaults: defaults, rows: rows,
                    search: {
                        await GmailReplySearch(fromEmail: me).searchMailbox(
                            in: context, token: "tok", now: at, defaults: defaults, clock: clock,
                            rows: rows, fetch: mailbox)
                    },
                    attach: { _, _ in InquiryConversationAttach.Outcome() })
            },
            recordTimeline: timeline ?? { _ in })
    }

    @Test func aSearchWhoseNetworkFailsStampsNobodyAndSaysSo() async throws {
        let ctx = try context()
        let r = formPitch(ctx, on: show(ctx))
        try ctx.save()
        let defaults = ScratchDefaults.make("4107-fail")
        let markBefore = ReplySearchHighWater.searchedThrough(from: defaults)

        let summary = await tick(ctx, defaults: defaults, mailbox: { _ in throw URLError(.notConnectedToInternet) })

        // Surfaced, not swallowed.
        #expect(summary.replySearchFailure != nil)
        // The apply half did not run at all: nobody is stamped as searched and the mark did not move, so
        // the next tick reads the same window again rather than stepping over it for ever.
        #expect(r.replyCandidateSearchedAt == nil)
        #expect(ReplySearchHighWater.searchedThrough(from: defaults) == markBefore)
        // And the passes after it were not skipped: the tick finished and stamped itself.
        #expect(defaults.double(forKey: ReconcileScheduler.lastReconcileKey) == now.timeIntervalSince1970)
    }

    @Test func aSearchThatTimesOutStampsNobodyAndSaysSo() async throws {
        let ctx = try context()
        let r = formPitch(ctx, on: show(ctx))
        try ctx.save()
        let defaults = ScratchDefaults.make("4107-timeout")
        // A clock that has already passed any deadline the search sets by the time Gmail answers.
        var reads = 0
        let clock: () -> Date = { reads += 1; return now.addingTimeInterval(reads == 1 ? 0 : 3_600) }

        let summary = await tick(ctx, defaults: defaults, clock: clock,
                                 mailbox: { req in self.respond(req, self.emptyList(), 200) })

        #expect(summary.replySearchFailure != nil)
        #expect(r.replyCandidateSearchedAt == nil)
        #expect(defaults.double(forKey: ReconcileScheduler.lastReconcileKey) == now.timeIntervalSince1970)
    }

    @Test func aSearchThatSucceedsStampsTheContactsItRead() async throws {
        // The positive control for the two above, in the same fixture, so their "nobody stamped" cannot be
        // a fixture where nobody COULD be stamped (L159).
        let ctx = try context()
        let r = formPitch(ctx, on: show(ctx))
        try ctx.save()
        let defaults = ScratchDefaults.make("4107-ok")

        let summary = await tick(ctx, defaults: defaults, mailbox: { req in self.respond(req, self.emptyList(), 200) })

        #expect(summary.replySearchFailure == nil)
        #expect(r.replyCandidateSearchedAt == now)
    }

    @Test func aShowDeletedWhileTheSearchWaitedOnGmailIsNotWrittenTo() async throws {
        let ctx = try context()
        let stays = formPitch(ctx, on: show(ctx, key: "stays"))
        let goes = show(ctx, key: "goes")
        formPitch(ctx, on: goes)
        try ctx.save()
        let defaults = ScratchDefaults.make("4107-deleted")

        // Another writer removes a show while the tick is waiting on Gmail, which is exactly when one can.
        let summary = await tick(ctx, defaults: defaults, mailbox: { req in
            if ctx.model(for: goes.persistentModelID) is Prospect, !goes.isDeleted {
                ctx.delete(goes)
                try? ctx.save()
            }
            return self.respond(req, self.emptyList(), 200)
        })

        #expect(summary.replySearchFailure == nil)
        #expect(stays.replyCandidateSearchedAt == now)
        let remaining = try ctx.fetch(FetchDescriptor<Prospect>()).map(\.naturalKey)
        #expect(remaining == ["stays"])
    }

    @Test func aThreadThatCannotBeReadIsLeftExactlyAsItWas() async throws {
        let ctx = try context()
        let minted = "<AA037CFE-0D5F-4B13-8E67-5B765CD60A56@danwrightphotography.com>"
        let r = Recipient(id: "them@example.com", email: "them@example.com", provenance: .act)
        r.gmailThreadId = "t1"
        r.gmailMessageId = minted
        r.sendState = .sent
        show(ctx).addRecipient(r)
        try ctx.save()

        let outcome = await GmailThreadingRepair(fromEmail: me).repairMessageIds(
            in: ctx, token: "tok", rows: StoreRows.fetch(from: ctx),
            fetch: { _ in throw URLError(.timedOut) })

        #expect(outcome.unreadable == 1)
        #expect(outcome.repaired == 0)
        #expect(r.gmailMessageId == minted, "a thread nobody could read must not change what is stored")
        #expect(r.threadingDegraded == false, "unreadable is not unthreadable")
    }

    // MARK: the instrument

    @Test func everyPassOfTheTickIsTimedInOrder() async throws {
        let ctx = try context()
        var recorded: ReconcileTickTimeline?

        _ = await tick(ctx, defaults: ScratchDefaults.make("4107-timeline"), timeline: { recorded = $0 },
                       mailbox: { req in self.respond(req, self.emptyList(), 200) })

        let timeline = try #require(recorded, "the tick recorded no timeline")
        #expect(timeline.entries.map(\.phase) == ReconcileTickTimeline.Phase.allCases)
        #expect(timeline.logLine.contains("readRows"))
    }

    @Test func theLongestHoldIgnoresPassesThatWait() {
        var t = ReconcileTickTimeline()
        t.record(.bookings, seconds: 0.020)
        t.record(.replyProposals, seconds: 4.0)
        t.record(.closingCount, seconds: 0.050)

        #expect(t.longestHold?.phase == .closingCount)
        #expect(t.logLine.contains("replyProposals ~4000"))
        #expect(t.logLine.contains("longest main actor hold: closingCount 50"))
    }
}
