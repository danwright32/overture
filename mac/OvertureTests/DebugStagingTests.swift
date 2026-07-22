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
        // #963: and the synthetic gmailMessageId means it counts as PROVABLY contacted too, so
        // outreach stats/booking auto-detection see it, not just the older, weaker check.
        #expect(p.wasProvablyContacted)
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
        // #963: gmailMessageId IS deliberately set now (the prospect-level proof-of-send synthetic
        // id), unlike gmailThreadId above, which nothing reads for that purpose.
        #expect(p.gmailMessageId != nil)
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

        #expect(p.recipients.first?.email == "self@example.com")
        #expect(p.draftBody != nil)
        // Drafted (not pre-approved) so Dan exercises the real approve + send clicks himself.
        #expect(p.status == .drafted)
        #expect(p.sentAt == nil)
        // Keyed under the debug prefix so clearDebugLeads can remove it.
        #expect(p.naturalKey.hasPrefix("debug-of-"))
    }

    // #1292: a returning-client "warm register" draft in Review, so the #1215 keyed-off-prior-relationship
    // surface can be SEEN in the near-empty dev store instead of shipping green-but-unseen.
    @Test func stagesAWarmRegisterReturningClientDraft() throws {
        let ctx = try makeInMemoryContext()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let p = DebugStaging.stageWarmRegisterDraft(in: ctx, now: now)

        #expect(p.priorRelationship == "warm")                 // the returning-client tone
        #expect(p.priorRelationshipForDrafting == "warm")      // and the drafter is allowed to see it
        #expect(p.matchedClientName != nil)                    // a named prior client
        #expect(p.status == .drafted)                          // sits in Review
        #expect(p.draftBody != nil)
        #expect(p.naturalKey.hasPrefix("debug-of-"))
    }

    // #1292: a re-prep-queued draft, so the gold "Re-prep queued" badge (#1143) can be seen on the review card.
    @Test @MainActor func stagesAReprepQueuedDraft() throws {
        let ctx = try makeInMemoryContext()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let p = DebugStaging.stageReprepQueuedDraft(in: ctx, now: now)

        // reprepDraftRequested is what QueueItem.isReprepQueued reads to show the "Re-prep queued" badge.
        #expect(p.reprepDraftRequested == true)
        #expect(QueueItem(p).isReprepQueued == true)
        #expect(p.status == .drafted)
        #expect(p.draftBody != nil)
        #expect(p.naturalKey.hasPrefix("debug-of-"))
    }

    // #1292: two still-open shows on ONE date after a reachability probe, one with a sendable contact and one
    // without, so the #1338 "best contact" highlight (the forest row emphasis on the emailable one) can be
    // seen against a competitor that is not highlighted.
    @Test @MainActor func stagesAReachabilityEmailFoundCompetition() throws {
        let ctx = try makeInMemoryContext()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let shows = DebugStaging.stageReachabilityCompetition(in: ctx, now: now)

        #expect(shows.count == 2)
        #expect(shows[0].performanceDate == shows[1].performanceDate)   // same date: a genuine competition
        #expect(shows.allSatisfy { $0.status == .new })                 // both still open
        // One is a best (sendable) reachable contact, highlighted; the other is not.
        let flags = shows.map { QueueItem($0).isBestReachableContact(now: now.addingTimeInterval(60)) }
        #expect(flags.contains(true))
        #expect(flags.contains(false))
        #expect(shows.allSatisfy { $0.naturalKey.hasPrefix("debug-of-") })
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

    // #654: a real prospect already carries its own recipients (from PrepImporter); staging a send
    // must mark them sent too, mirroring what a real SendService.deliver call does, or every
    // per-recipient downstream flow (follow-ups, reminders, reply handling) would see nothing to act on.
    @Test func stageAsSentMarksExistingPendingRecipientsAsSent() {
        let p = makeProspect()
        let recipient = Recipient(id: "ann@example.com", email: "ann@example.com", provenance: .act)
        p.setRecipients([recipient])
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        DebugStaging.stageAsSent(p, now: now)

        #expect(p.recipients.count == 1)
        #expect(p.recipients.first?.sendState == .sent)
        #expect(p.recipients.first?.sentAt == now)
        // #378: ReachedOutQueue now requires a Gmail message id as proof of a real send, so a
        // staged recipient must carry a (synthetic) one too or it silently drops off that view.
        #expect(p.recipients.first?.gmailMessageId != nil)
    }

    // #378 end to end: the whole reason stageAsSent stamps a synthetic gmailMessageId is so a
    // staged lead still shows up in the Reached-out queue Dan uses to test follow-up/reminder
    // flows in Debug builds, exactly as it did before the real-send-proof gate was added.
    @Test func stagedRecipientStillShowsUpInReachedOutQueue() {
        let p = makeProspect()
        let recipient = Recipient(id: "ann@example.com", email: "ann@example.com", provenance: .act)
        p.setRecipients([recipient])
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        DebugStaging.stageAsSent(p, now: now)

        #expect(ReachedOutQueue.nextReachOut(for: recipient, of: p, now: now) != nil)
    }

    @Test func reminderDueLeadSeedsARepliedRecipient() throws {
        let ctx = try makeInMemoryContext()

        let p = DebugStaging.stageReminderDueLead(in: ctx, now: Date())

        #expect(p.recipients.count == 1)
        #expect(p.recipients.first?.email == "reminder@debug.example")
        #expect(p.recipients.first?.sendState == .sent)
        #expect(p.recipients.first?.replied == true)
        #expect(p.recipients.first?.gmailMessageId != nil)
        // #963: the prospect-level proof-of-send id too, so this staged lead counts as contacted
        // for outreach stats/booking auto-detection, not just the recipient-level Reached-out queue.
        #expect(p.wasProvablyContacted)
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

    // MARK: - #1245: the one-action visual-QA seed (draft + signature + same-date double-booking).

    private func qaDefaults() -> UserDefaults {
        UserDefaults(suiteName: "DebugStagingVisualQATests-\(UUID().uuidString)")!
    }

    @Test @MainActor func visualQAScenarioSeedsADraftInReviewWithAReachableRecipient() throws {
        let ctx = try makeInMemoryContext()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let drafted = DebugStaging.stageVisualQAScenario(in: ctx, now: now, defaults: qaDefaults())
        try ctx.save()

        // The show Dan reviews: a real draft, not yet sent, with an emailable recipient (the #1203 preview
        // only appears for a draft that has a body and a place to send).
        #expect(drafted.status == .drafted)
        #expect(drafted.sentAt == nil)
        #expect(drafted.draftSubject?.isEmpty == false)
        #expect(drafted.draftBody?.isEmpty == false)
        #expect(drafted.recipients.count == 1)
        #expect(drafted.recipients.first?.email == DebugStaging.defaultSelfSendAddress)
    }

    @Test @MainActor func visualQAScenarioStoresARenderableGmailSignature() throws {
        let ctx = try makeInMemoryContext()
        let defaults = qaDefaults()

        _ = DebugStaging.stageVisualQAScenario(in: ctx, now: Date(), defaults: defaults)

        // Stored AND healthy: currentHTML hides a corrupt signature, so a non-nil return proves #1203's
        // styled preview has something real to render rather than falling back to plain text.
        #expect(GmailSignatureStore.currentHTML(defaults: defaults) != nil)
        #expect(GmailSignatureStore.currentSignatureIssue(defaults: defaults) == nil)
    }

    @Test @MainActor func visualQAScenarioSeedsASecondSameDateShowThatIsAlreadyEmailed() throws {
        let ctx = try makeInMemoryContext()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let drafted = DebugStaging.stageVisualQAScenario(in: ctx, now: now, defaults: qaDefaults())
        try ctx.save()

        let all = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(all.count == 2)
        let other = try #require(all.first { $0.naturalKey != drafted.naturalKey })

        // A DIFFERENT show (distinct name/venue) on the SAME date, already emailed: exactly the shape #1219
        // flags as a self double-booking.
        #expect(other.performanceDate == drafted.performanceDate)
        #expect(other.groupName != drafted.groupName)
        #expect(other.venue != drafted.venue)
        #expect(other.wasProvablyContacted)   // sentAt + a gmailMessageId: an actually-emailed commitment
    }

    // The seed must actually TRIGGER the surface it exists to demo, not merely look plausible: the real
    // #1219 detector must report the two seeded shows as a same-date clash.
    @Test @MainActor func theSeededShowsGenuinelyCollideUnderTheSelfBookingDetector() throws {
        let ctx = try makeInMemoryContext()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let drafted = DebugStaging.stageVisualQAScenario(in: ctx, now: now, defaults: qaDefaults())
        try ctx.save()
        let all = try ctx.fetch(FetchDescriptor<Prospect>())

        // Build the detector's Show for each seeded prospect the way QueueModel does (a live draft and an
        // emailed pitch are both commitments; engagementKey is the groupName, which differs between them).
        let shows = all.map {
            SelfBookingConflict.Show(key: $0.naturalKey, date: $0.performanceDate, isCommitment: true,
                                     engagementKey: $0.groupName, name: $0.groupName)
        }
        let target = try #require(shows.first { $0.key == drafted.naturalKey })
        #expect(SelfBookingConflict.conflicts(for: target, among: shows).count == 1)
    }

    @Test @MainActor func clearDebugLeadsRemovesBothVisualQAShows() throws {
        let ctx = try makeInMemoryContext()
        _ = DebugStaging.stageVisualQAScenario(in: ctx, now: Date(), defaults: qaDefaults())
        try ctx.save()

        DebugStaging.clearDebugLeads(in: ctx)

        #expect((try ctx.fetchCount(FetchDescriptor<Prospect>())) == 0)
    }
}
#endif
