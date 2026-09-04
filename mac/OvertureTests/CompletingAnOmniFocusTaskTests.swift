import Testing
import Foundation
import SwiftData

// #2899: "I keep completing this task in omnifocus but it keeps getting added back" (Dan, 2026-08-17).
//
// `existingOvertureTasks` asked OmniFocus for tasks `whose completed is false`, so the only evidence
// that Dan had dealt with one, the completed task sitting right there, was filtered out before
// `reconcile` could see it. A task he COMPLETED and a task that was NEVER CREATED were the same state,
// and the sync resolved that ambiguity by creating. Every pass, for ever. L162's shape, arriving through
// the surface that exists precisely so he can work away from his desk.
@Suite("Completing an OmniFocus task")
struct CompletingAnOmniFocusTaskTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func show(_ ctx: ModelContext, key: String = "an evening of song|2026-09-04|the corner room") -> Prospect {
        let p = Prospect(naturalKey: key, groupName: "Corner Room Collective", discipline: "choral",
                         venue: "the corner room", performanceDate: "2026-09-04", sourceListingURL: nil, priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .contacted)
        ctx.insert(p)
        return p
    }

    @discardableResult
    private func repliedContact(_ ctx: ModelContext, on p: Prospect, id: String = "booking@example.invalid",
                                replyId: String? = "reply-1", now: Date) -> Recipient {
        let r = Recipient(id: id, email: id, provenance: .act)
        r.sentAt = now.addingTimeInterval(-86_400 * 5)
        r.sendState = .sent
        r.gmailMessageId = "msg-\(id)"
        r.replied = true
        r.lastReplyId = replyId
        r.inboundReplySentAt = now.addingTimeInterval(-3_600)
        r.prospect = p
        p.recipients.append(r)
        return r
    }

    // A client holding whatever OmniFocus is said to hold, open and completed kept apart.
    private final class FakeClient: OmniFocusClient, @unchecked Sendable {
        var open: [OmniFocusSync.ExistingTask]
        var done: [OmniFocusSync.ExistingTask]
        var created: [OmniFocusSync.DesiredTask] = []
        var completed: [OmniFocusSync.ExistingTask] = []
        init(open: [OmniFocusSync.ExistingTask] = [], done: [OmniFocusSync.ExistingTask] = []) {
            self.open = open
            self.done = done
        }
        func existingOvertureTasks() throws -> [OmniFocusSync.ExistingTask] { open }
        func completedOvertureTasks() throws -> [OmniFocusSync.ExistingTask] { done }
        func create(_ task: OmniFocusSync.DesiredTask) throws { created.append(task) }
        func complete(_ task: OmniFocusSync.ExistingTask) throws { completed.append(task) }
    }

    private func existing(_ d: OmniFocusSync.DesiredTask) -> OmniFocusSync.ExistingTask {
        OmniFocusSync.ExistingTask(naturalKey: d.naturalKey, recipientId: d.recipientId, dueDate: d.dueDate)
    }

    // MARK: - The reported bug

    @Test func aCompletedTaskIsNotCreatedAgain() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let p = show(ctx)
        repliedContact(ctx, on: p, now: now)

        let desired = OmniFocusSync.desired(from: [p], now: now, horizonDays: 14)
        #expect(desired.count == 1)
        let client = FakeClient(done: [existing(desired[0])])

        let result = try OmniFocusSync.apply(desired: desired, client: client)

        #expect(client.created.isEmpty)
        #expect(result.handled.map(\.recipientId) == ["booking@example.invalid"])
    }

    // MARK: - What a completion writes, per kind (#2899 point 1)

    @Test func completingAReplyTriageTaskStampsTheReplyHandled() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let p = show(ctx)
        let r = repliedContact(ctx, on: p, now: now)
        let desired = OmniFocusSync.desired(from: [p], now: now, horizonDays: 14)
        #expect(desired.first?.kind == .replyTriage)

        #expect(OmniFocusSync.recordCompletions(desired, in: [p], now: now) == 1)

        #expect(r.replyHandledAt == now)
        #expect(!r.hasUnhandledReply)
    }

    // Point 3: a completion supplies no message, so it must never claim one. `sentReplyBody` and
    // `replySentAt` mean "the words Dan committed through Overture" and feed the voice pair (#463).
    @Test func completingATaskNeverClaimsWordsOvertureNeverSaw() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let p = show(ctx)
        let r = repliedContact(ctx, on: p, now: now)
        r.replyDraftBody = "a draft he was still writing"

        OmniFocusSync.recordCompletions(OmniFocusSync.desired(from: [p], now: now, horizonDays: 14),
                                        in: [p], now: now)

        #expect(r.sentReplyBody == nil)
        #expect(r.replySentAt == nil)
        #expect(r.replyDraftBody == "a draft he was still writing")   // the draft is not consumed either
    }

    // Point 2: "I dealt with this reply" is a fact about the CONVERSATION, not one mailbox, so it fans
    // out to everybody on the same send who was marked by the same reply. Without it a colleague on that
    // send is left reading as waiting on Dan (#2191).
    @Test func completingATriageTaskFansOutToTheRestOfTheConversation() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let p = show(ctx)
        let first = repliedContact(ctx, on: p, id: "a@example.invalid", now: now)
        let peer = repliedContact(ctx, on: p, id: "b@example.invalid", now: now)
        for r in [first, peer] { r.sendGroupId = "group-1" }

        let desired = OmniFocusSync.desired(from: [p], now: now, horizonDays: 14)
        #expect(desired.count == 1)   // one row per email (#2033)
        OmniFocusSync.recordCompletions(desired, in: [p], now: now)

        #expect(first.replyHandledAt == now)
        #expect(peer.replyHandledAt == now, "a colleague on the same send is not left waiting")
    }

    // A peer marked by a DIFFERENT reply is somebody else's message, and answering one says nothing
    // about the other, so it stays asking (#2191's own rule, inherited rather than re-decided).
    @Test func aPeerCarryingADifferentReplyIsLeftAsking() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let p = show(ctx)
        let first = repliedContact(ctx, on: p, id: "a@example.invalid", replyId: "reply-1", now: now)
        let peer = repliedContact(ctx, on: p, id: "b@example.invalid", replyId: "reply-2", now: now)
        for r in [first, peer] { r.sendGroupId = "group-1" }

        AnsweredReply.recordHandled(on: first, in: p, now: now)

        #expect(first.replyHandledAt == now)
        #expect(peer.replyHandledAt == nil)
    }

    // Dan's call, 2026-08-17: ticking off a post-event task means "I know, I will do it in Overture".
    // Overture cannot invent WHICH ending, and the ending is the fact the whole funnel is reported on,
    // so it writes nothing. What the completion buys is that OmniFocus stops asking.
    @Test func completingAPostEventTaskWritesNothingAndStillStopsOmniFocusAsking() throws {
        let ctx = ModelContext(try container())
        let now = EasternDate.date(from: "2026-09-06")!
        let p = show(ctx)
        let r = repliedContact(ctx, on: p, now: now)
        r.replied = false            // nobody wrote back, so the post-event prompt is what is owed
        r.inboundReplySentAt = nil
        r.lastReplyId = nil

        let desired = OmniFocusSync.desired(from: [p], now: now, horizonDays: 14)
        #expect(desired.first?.kind == .postEventPrompt)

        #expect(OmniFocusSync.recordCompletions(desired, in: [p], now: now) == 0)
        #expect(p.showOutcome == nil, "no ending is invented")
        #expect(r.replyHandledAt == nil)

        let client = FakeClient(done: [existing(desired[0])])
        _ = try OmniFocusSync.apply(desired: desired, client: client)
        #expect(client.created.isEmpty)
    }

    // MARK: - Idempotence (#2899 point 4)

    // The completion is applied at most once because it only counts against a task that is desired RIGHT
    // NOW: once it lands, the reply is handled, the task stops being desired, and no later pass can match
    // it again. So a second run cannot move the stamp forward onto a later clock.
    @Test func asecondPassOverTheSameCompletedTaskStampsNothingFurther() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let p = show(ctx)
        let r = repliedContact(ctx, on: p, now: now)
        let firstDesired = OmniFocusSync.desired(from: [p], now: now, horizonDays: 14)
        let client = FakeClient(done: [existing(firstDesired[0])])
        _ = try OmniFocusSync.apply(desired: firstDesired, client: client)
        OmniFocusSync.recordCompletions(firstDesired, in: [p], now: now)

        let later = now.addingTimeInterval(86_400)
        let secondDesired = OmniFocusSync.desired(from: [p], now: later, horizonDays: 14)

        #expect(secondDesired.isEmpty)
        #expect(r.replyHandledAt == now)
    }

    // Point 4's other half: a state Dan has since REOPENED must not stay suppressed. A second reply
    // re-anchors the due, so the completed task no longer matches and a fresh task is created.
    @Test func aSecondReplyAfterTheCompletionEarnsAFreshTask() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let p = show(ctx)
        let r = repliedContact(ctx, on: p, now: now)
        let firstDesired = OmniFocusSync.desired(from: [p], now: now, horizonDays: 14)
        let doneTask = existing(firstDesired[0])
        OmniFocusSync.recordCompletions(firstDesired, in: [p], now: now)

        // They write again, two days later.
        let later = now.addingTimeInterval(86_400 * 2)
        r.inboundReplySentAt = later
        r.lastReplyId = "reply-2"

        let secondDesired = OmniFocusSync.desired(from: [p], now: later, horizonDays: 14)
        #expect(secondDesired.count == 1)
        let client = FakeClient(done: [doneTask])
        _ = try OmniFocusSync.apply(desired: secondDesired, client: client)

        #expect(client.created.count == 1, "the old completed task must not swallow the new one")
    }

    // Stale evidence: a completed task at a due nothing currently wants says nothing about today's task,
    // so it neither suppresses it nor stamps anything.
    @Test func aCompletedTaskAtADifferentDueIsIgnored() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let p = show(ctx)
        let r = repliedContact(ctx, on: p, now: now)
        let desired = OmniFocusSync.desired(from: [p], now: now, horizonDays: 14)
        let stale = OmniFocusSync.ExistingTask(naturalKey: desired[0].naturalKey,
                                               recipientId: desired[0].recipientId,
                                               dueDate: desired[0].dueDate.addingTimeInterval(-86_400 * 3))
        let client = FakeClient(done: [stale])

        let result = try OmniFocusSync.apply(desired: desired, client: client)

        #expect(client.created.count == 1)
        #expect(result.handled.isEmpty)
        #expect(OmniFocusSync.recordCompletions(result.handled, in: [p], now: now) == 0)
        #expect(r.replyHandledAt == nil)
    }
}

// The signal is only worth reading if it is carried back. Both sync sites compute `desired` on the main
// actor and both have to hand `plan.handled` to `recordCompletions`; a site that forgets leaves the task
// ticked off over there and nothing moved here, which is the exact state #2899 was filed about and is
// invisible from either file read alone (L46, L96).
@Suite("Both OmniFocus sync sites carry a completion back")
struct OmniFocusCompletionsAreCarriedBackTests {
    private func body(of function: String, in file: String) throws -> String {
        try #require(SourceGuardHelper.bodyOfFunction(named: function,
                                                      in: SourceGuardHelper.source(file)))
    }

    @Test func theLaunchAndManualSyncCarriesItBack() throws {
        let src = try body(of: "syncOmniFocus", in: "Overture/App/RootView.swift")
        #expect(src.contains("OmniFocusSync.recordCompletions"))
    }

    @Test func theScheduledSyncCarriesItBack() throws {
        let src = try body(of: "syncOmniFocus", in: "Overture/App/ReconcileScheduler.swift")
        #expect(src.contains("OmniFocusSync.recordCompletions"))
    }
}
