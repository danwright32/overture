import Testing
import Foundation
import SwiftData
@testable import Overture

// #196: the DEBUG-only staging helper that marks a prospect as already sent, so post-send
// flows (booking detection, follow-ups, reminders, reply handling) can be exercised without
// a live Gmail send. The helper itself is compiled out of release builds, so these tests
// (which always build in Debug) are the only thing that references it.
#if DEBUG
@Suite("Debug staging")
struct DebugStagingTests {
    private func makeProspect() -> Prospect {
        Prospect(naturalKey: "k", groupName: "G", discipline: "music", venue: nil,
                 performanceDate: nil, sourceListingURL: nil, websiteURL: nil,
                 priorRelationship: "warm", production: "self", profile: "neutral",
                 coverage: "unknown", fitScore: 3, tier: "longshot", fitReason: "r",
                 matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
    }

    @Test func stagesAsApprovedAndSent() {
        let p = makeProspect()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        DebugStaging.stageAsSent(p, now: now)

        #expect(p.sentAt == now)
        #expect(p.status == .approved)
        // The two together are exactly what wasContacted keys off, so the lead now counts
        // as contacted for every post-send flow.
        #expect(p.wasContacted)
    }

    @Test func snapshotsPriorRelationshipLikeARealSend() {
        let p = makeProspect()

        DebugStaging.stageAsSent(p, now: Date())

        // Booking detection (#66) compares against the relationship captured at send time, so
        // the helper must mirror SendService and snapshot it.
        #expect(p.priorRelationshipAtSend == "warm")
    }

    @Test func leavesUnrelatedOutreachStateUntouched() {
        let p = makeProspect()
        p.draftBody = "hello"
        p.draftSubject = "subj"

        DebugStaging.stageAsSent(p, now: Date())

        // No spurious outcome, reply, or thread state: it stages a fresh send, nothing more.
        #expect(p.outcome == .noResponse)
        #expect(p.gmailThreadId == nil)
        #expect(p.gmailMessageId == nil)
        #expect(p.lastReplyText == nil)
        #expect(p.draftBody == "hello")
        #expect(p.draftSubject == "subj")
    }

    // #325: a self-addressed lead so the real approve -> send path can be verified end to end
    // without risking a real email to a prospect.
    private func makeInMemoryContext() throws -> ModelContext {
        let container = try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        return ModelContext(container)
    }

    @Test func stagesASelfAddressedDraftedLead() throws {
        let ctx = try makeInMemoryContext()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let p = DebugStaging.stageSelfSendLead(in: ctx, now: now, address: "self@example.com")

        #expect(p.contactEmail == "self@example.com")
        #expect(p.draftBody != nil)
        // Drafted (not pre-approved) so Dan exercises the real approve + send clicks himself.
        #expect(p.status == .drafted)
        #expect(p.sentAt == nil)
        // Keyed under the debug prefix so clearDebugLeads can remove it.
        #expect(p.naturalKey.hasPrefix("debug-of-"))
    }

    @Test @MainActor func selfSendLeadEntersTheSendQueueOnceApproved() throws {
        let ctx = try makeInMemoryContext()
        let p = DebugStaging.stageSelfSendLead(in: ctx, now: Date(), address: "self@example.com")
        p.status = .approved
        try ctx.save()

        // The whole point: after approval the real Send button has a target, so a live send goes to self.
        #expect(SendService.nextPendingRecipient(for: p) != nil)
    }

    @Test func clearDebugLeadsRemovesTheSelfSendLead() throws {
        let ctx = try makeInMemoryContext()
        _ = DebugStaging.stageSelfSendLead(in: ctx, now: Date(), address: "self@example.com")
        try ctx.save()

        DebugStaging.clearDebugLeads(in: ctx)

        #expect((try ctx.fetchCount(FetchDescriptor<Prospect>())) == 0)
    }

    // #391: each stager must seed a matching recipients[0] in-session, or a freshly staged lead shows
    // zero recipients until a relaunch triggers the backfill (same unaudited-path class as #317).
    @Test func stageAsSentSeedsASentRecipient() {
        let p = makeProspect()
        p.contactEmail = "ann@example.com"
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        DebugStaging.stageAsSent(p, now: now)

        #expect(p.recipients.count == 1)
        #expect(p.recipients.first?.provenance == .act)
        #expect(p.recipients.first?.sendState == .sent)
        #expect(p.recipients.first?.sentAt == now)
    }

    @Test func reminderDueLeadSeedsARepliedRecipient() throws {
        let ctx = try makeInMemoryContext()

        let p = DebugStaging.stageReminderDueLead(in: ctx, now: Date())

        #expect(p.recipients.count == 1)
        #expect(p.recipients.first?.email == "reminder@debug.example")
        #expect(p.recipients.first?.sendState == .sent)
        #expect(p.recipients.first?.replied == true)
    }

    @Test func selfSendLeadSeedsAPendingRecipient() throws {
        let ctx = try makeInMemoryContext()

        let p = DebugStaging.stageSelfSendLead(in: ctx, now: Date(), address: "self@example.com")

        #expect(p.recipients.count == 1)
        #expect(p.recipients.first?.email == "self@example.com")
        #expect(p.recipients.first?.sendState == .pending)
    }

    // #564: the live app's queue is driven by a `@Query`, which re-hydrates `Prospect` from the
    // persisted store as its OWN Swift instances, distinct from the one `stageSelfSendLead` returns.
    // Reading `p.recipients` on that original instance (as the test above does) proves nothing about
    // what actually got saved. Approve then re-fetch, the way the real Approve click + queue refresh
    // would see it, and check the same `hasPendingRecipient` gate `DraftReviewView` uses for Send.
    @Test func selfSendLeadKeepsItsPendingRecipientAfterApproveAndRefetch() throws {
        let ctx = try makeInMemoryContext()
        let p = DebugStaging.stageSelfSendLead(in: ctx, now: Date(), address: "self@example.com")
        p.status = .approved
        try ctx.save()

        let refetched = try #require(try ctx.fetch(FetchDescriptor<Prospect>()).first)
        #expect(refetched.recipients.count == 1)
        #expect(QueueItem(refetched).hasPendingRecipient == true)
    }

    // Same as above but against a real FILE-BACKED store, read back through a SECOND, independent
    // ModelContext on the same container (mimicking the live app: staging happens on one context,
    // the queue's `@Query` re-reads through its own). An in-memory store or a same-context refetch
    // could both mask a real persistence gap that only a genuinely separate read surfaces.
    @Test func selfSendLeadKeepsItsPendingRecipientInAFileBackedStoreAcrossContexts() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("overture-test-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let container = try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                           configurations: [ModelConfiguration(url: storeURL)])

        let writeContext = ModelContext(container)
        let p = DebugStaging.stageSelfSendLead(in: writeContext, now: Date(), address: "self@example.com")
        p.status = .approved
        try writeContext.save()

        let readContext = ModelContext(container)
        let refetched = try #require(try readContext.fetch(FetchDescriptor<Prospect>()).first)
        #expect(refetched.recipients.count == 1)
        #expect(QueueItem(refetched).hasPendingRecipient == true)
    }

    // #432: the self-send target is configurable (via the `selfSendTestAddress` default) so the
    // reply-drafter path can be exercised against an alternate inbox without editing code. A blank
    // or absent override falls back to Dan's primary address.
    @Test func resolvesConfiguredSelfSendAddressOverDefault() {
        #expect(DebugStaging.resolvedSelfSendAddress(override: nil) == DebugStaging.defaultSelfSendAddress)
        #expect(DebugStaging.resolvedSelfSendAddress(override: "   ") == DebugStaging.defaultSelfSendAddress)
        #expect(DebugStaging.resolvedSelfSendAddress(override: "daniel.wright33@icloud.com")
                == "daniel.wright33@icloud.com")
    }

    // #425: a self-addressed lead with TWO recipients (act + presenter), so the per-recipient send
    // fan-out (#415) can be proven end to end by a live self-send: approve, then send twice, should
    // produce two separate emails, each to its own address and greeting its own name, on their own
    // Gmail threads. The single-recipient stager above cannot exercise the fan-out at all.
    @Test func stagesAMultiRecipientSelfSendLead() throws {
        let ctx = try makeInMemoryContext()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let p = DebugStaging.stageMultiRecipientSelfSendLead(in: ctx, now: now, address: "self@example.com")

        #expect(p.status == .drafted)
        #expect(p.sentAt == nil)
        #expect(p.naturalKey.hasPrefix("debug-of-"))
        #expect(p.recipients.count == 2)
    }

    @Test func multiRecipientLeadHasOneActAndOnePresenterBothPendingWithDistinctAddresses() throws {
        let ctx = try makeInMemoryContext()

        let p = DebugStaging.stageMultiRecipientSelfSendLead(in: ctx, now: Date(), address: "self@example.com")

        let act = p.recipients.first { $0.provenance == .act }
        let presenter = p.recipients.first { $0.provenance == .presenter }
        #expect(act != nil)
        #expect(presenter != nil)
        #expect(act?.sendState == .pending)
        #expect(presenter?.sendState == .pending)
        // Both land in Dan's own inbox but must carry distinct ids (the canonicalized email), or the
        // second recipient's row collides with the first's identity within this one performance.
        #expect(act?.email != presenter?.email)
        #expect(act?.id != presenter?.id)
        #expect(act?.email?.hasSuffix("@example.com") == true)
        #expect(presenter?.email?.hasSuffix("@example.com") == true)
    }

    @Test func multiRecipientLeadGreetsEachRecipientByItsOwnName() throws {
        let ctx = try makeInMemoryContext()

        let p = DebugStaging.stageMultiRecipientSelfSendLead(in: ctx, now: Date(), address: "self@example.com")

        #expect(p.recipients.allSatisfy { $0.name != nil })
        #expect(Set(p.recipients.map { $0.name }).count == 2)   // must not share a display name
    }

    // DraftReviewView disables Approve when contactEmail is nil, so the legacy singular field must
    // stay in sync with the act recipient or a multi-recipient lead would be stuck un-approvable.
    @Test func multiRecipientLeadKeepsLegacyContactFieldInSyncWithTheActRecipient() throws {
        let ctx = try makeInMemoryContext()

        let p = DebugStaging.stageMultiRecipientSelfSendLead(in: ctx, now: Date(), address: "self@example.com")

        let act = p.recipients.first { $0.provenance == .act }
        #expect(p.contactEmail != nil)
        #expect(p.contactEmail == act?.email)
    }

    @Test @MainActor func multiRecipientLeadEntersTheSendQueueTwiceOnceApproved() throws {
        let ctx = try makeInMemoryContext()
        let p = DebugStaging.stageMultiRecipientSelfSendLead(in: ctx, now: Date(), address: "self@example.com")
        p.status = .approved
        try ctx.save()

        // Both recipients are pending with real addresses, so the real Send button must offer both in
        // turn, act before presenter (the #366/#368 contact ladder), so two Send clicks reach two inboxes.
        #expect(SendService.nextPendingRecipient(for: p)?.provenance == .act)
        SendService.nextPendingRecipient(for: p)?.sendState = .sent
        #expect(SendService.nextPendingRecipient(for: p)?.provenance == .presenter)
    }

    @Test func clearDebugLeadsRemovesTheMultiRecipientSelfSendLead() throws {
        let ctx = try makeInMemoryContext()
        _ = DebugStaging.stageMultiRecipientSelfSendLead(in: ctx, now: Date(), address: "self@example.com")
        try ctx.save()

        DebugStaging.clearDebugLeads(in: ctx)

        #expect((try ctx.fetchCount(FetchDescriptor<Prospect>())) == 0)
    }
}
#endif
