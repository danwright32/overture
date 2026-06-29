import Testing
import Foundation
import SwiftData
@testable import Overture

// #217: the "reached out" pipeline lists contacted prospects Dan is still working, ordered by
// when he should next reach out, and drops anyone off once outreach should stop (booked, lost,
// or nothing scheduled). Covers the next-reach-out computation and the sorted active list.
@MainActor
@Suite("Reached-out queue")
struct ReachedOutQueueTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func make(_ ctx: ModelContext, group: String, sentAt: Date?,
                      outcome: Outcome = .noResponse,
                      contactEmail: String? = "contact@example.com") -> Prospect {
        let p = Prospect(naturalKey: group, groupName: group, discipline: "choral", venue: "V",
                         performanceDate: nil, sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .contacted)
        p.sentAt = sentAt
        p.outcome = outcome
        p.contactEmail = contactEmail
        ctx.insert(p)
        // Phase F: the derived reads come from contacts, so seed one whose standing matches `outcome`.
        if let contactEmail {
            let r = Recipient(id: contactEmail, email: contactEmail, provenance: .act)
            r.sendState = .sent
            if outcome == .replied { r.replied = true }
            if outcome == .lostSoft { r.resolution = .declinedSoft }
            if outcome == .lostHard { r.resolution = .declinedHard }
            ctx.insert(r)
            p.setRecipients([r])
        }
        return p
    }

    @Test func notContactedHasNoNextReachOut() throws {
        let ctx = ModelContext(try container())
        let p = make(ctx, group: "A", sentAt: nil)
        #expect(ReachedOutQueue.nextReachOut(for: p, now: Date(timeIntervalSince1970: 1_000_000)) == nil)
    }

    // #331: a record with a sent timestamp but no contact address was never really emailed
    // (a real send requires a contact). It must not show up in the reached-out pipeline.
    @Test func sentWithoutAContactIsNotReachedOut() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 1_000_000)
        let ghost = make(ctx, group: "Ghost", sentAt: now.addingTimeInterval(-86_400),
                         outcome: .noResponse, contactEmail: nil)
        #expect(ReachedOutQueue.nextReachOut(for: ghost, now: now) == nil)
        #expect(ReachedOutQueue.active(from: [ghost], now: now).isEmpty)
    }

    @Test func bookedOrLostDropsOff() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 1_000_000)
        for oc: Outcome in [.booked, .lostSoft, .lostHard] {
            let p = make(ctx, group: "g-\(oc.rawValue)", sentAt: now.addingTimeInterval(-86_400), outcome: oc)
            #expect(ReachedOutQueue.nextReachOut(for: p, now: now) == nil)
        }
    }

    @Test func noResponseSchedulesNextFollowUp() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 1_000_000)
        let sent = now.addingTimeInterval(-2 * 86_400)
        let p = make(ctx, group: "A", sentAt: sent, outcome: .noResponse)
        // gapDays default 6: next nudge is sent + 6 days.
        #expect(ReachedOutQueue.nextReachOut(for: p, now: now) == sent.addingTimeInterval(6 * 86_400))
    }

    @Test func exhaustedFollowUpsWithNoReplyDropsOff() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 1_000_000)
        let p = make(ctx, group: "A", sentAt: now.addingTimeInterval(-30 * 86_400), outcome: .noResponse)
        p.followUpCount = 2 // maxFollowUps default 2: exhausted, nothing scheduled
        #expect(ReachedOutQueue.nextReachOut(for: p, now: now) == nil)
    }

    @Test func repliedWithoutStateNeedsAttentionNow() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 1_000_000)
        let p = make(ctx, group: "A", sentAt: now.addingTimeInterval(-86_400), outcome: .replied)
        // Replied but uncategorized: needs a state, so it should surface now.
        #expect(ReachedOutQueue.nextReachOut(for: p, now: now) == now)
    }

    // #223: a plain-language label for when to next reach out, shown on each reached-out row.
    @Test func timingLabelReadsOverdueTodayAndFuture() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        #expect(ReachedOutQueue.timingLabel(next: now, now: now) == "Reach out now")
        #expect(ReachedOutQueue.timingLabel(next: now.addingTimeInterval(-5 * 86_400), now: now) == "Reach out now")
        #expect(ReachedOutQueue.timingLabel(next: now.addingTimeInterval(86_400), now: now) == "in 1 day")
        #expect(ReachedOutQueue.timingLabel(next: now.addingTimeInterval(3 * 86_400), now: now) == "in 3 days")
    }

    @Test func activeListIsSortedSoonestFirstAndExcludesStopped() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 10_000_000)
        let overdue = make(ctx, group: "Overdue", sentAt: now.addingTimeInterval(-30 * 86_400), outcome: .noResponse)
        let fresh = make(ctx, group: "Fresh", sentAt: now, outcome: .noResponse)
        let booked = make(ctx, group: "Booked", sentAt: now.addingTimeInterval(-86_400), outcome: .booked)
        let list = ReachedOutQueue.active(from: [fresh, booked, overdue], now: now)
        #expect(list.map(\.groupName) == ["Overdue", "Fresh"]) // booked excluded; overdue first
    }
}
