import Testing
import Foundation
import SwiftData

// #217/#652: the "reached out" pipeline lists contacted RECIPIENTS Dan is still working, ordered by
// when he should next reach out, and drops a recipient off once outreach to THAT contact should stop
// (booked, lost, or nothing scheduled). Per-recipient so a multi-contact show can have one contact
// due for a touch while another has already gone quiet for good.
@MainActor
@Suite("Reached-out queue")
struct ReachedOutQueueTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func makeShow(_ ctx: ModelContext, group: String) -> Prospect {
        let p = Prospect(naturalKey: group, groupName: group, discipline: "choral", venue: "V",
                         performanceDate: nil, sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .contacted)
        ctx.insert(p)
        return p
    }

    // A single recipient on its own show, sent/outcome-shaped like the old lead-level `make` helper,
    // so each scenario below can still be expressed as one recipient's own standing.
    private func makeRecipient(_ ctx: ModelContext, on p: Prospect, id: String = "contact@example.com",
                               sentAt: Date?, outcome: Outcome = .noResponse,
                               hasEmail: Bool = true) -> Recipient {
        let r = Recipient(id: id, email: hasEmail ? id : nil, provenance: .act)
        r.sentAt = sentAt
        r.sendState = sentAt != nil ? .sent : .pending
        // A genuine send always stamps a Gmail message id (GmailSender.performSend), so every
        // scenario here defaults to carrying one once sent, mirroring the real send path.
        // #378's own test overwrites this back to nil to model a record with no send proof.
        r.gmailMessageId = sentAt != nil ? "msg-\(id)" : nil
        if outcome == .replied { r.replied = true }
        if outcome == .lostSoft { r.resolution = .declinedSoft }
        if outcome == .lostHard { r.resolution = .declinedHard }
        if outcome == .booked { r.resolution = .booked }
        p.setRecipients(p.recipients + [r])
        return r
    }

    @Test func notContactedHasNoNextReachOut() throws {
        let ctx = ModelContext(try container())
        let p = makeShow(ctx, group: "A")
        let r = makeRecipient(ctx, on: p, sentAt: nil)
        #expect(ReachedOutQueue.nextReachOut(for: r, of: p, now: Date(timeIntervalSince1970: 1_000_000)) == nil)
    }

    // #331: a record with a sent timestamp but no contact address was never really emailed
    // (a real send requires a contact). It must not show up in the reached-out pipeline.
    @Test func sentWithoutAContactIsNotReachedOut() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 1_000_000)
        let p = makeShow(ctx, group: "Ghost")
        let ghost = makeRecipient(ctx, on: p, sentAt: now.addingTimeInterval(-86_400), hasEmail: false)
        #expect(ReachedOutQueue.nextReachOut(for: ghost, of: p, now: now) == nil)
        #expect(ReachedOutQueue.active(from: [p], now: now).isEmpty)
    }

    // #378: a sent timestamp alone is not proof of a real send (DebugStaging's #331 root cause,
    // or any future bug that sets sentAt without going through SendService.deliver). A genuine
    // send always stamps gmailMessageId from the actual Gmail response, so a recipient missing it
    // must not show up in the reached-out pipeline even though it has a timestamp and an address.
    @Test func sentWithoutGmailProofIsNotReachedOut() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 1_000_000)
        let p = makeShow(ctx, group: "Unproven")
        let unproven = makeRecipient(ctx, on: p, sentAt: now.addingTimeInterval(-86_400))
        unproven.gmailMessageId = nil   // explicit: no Gmail proof of a real send
        #expect(ReachedOutQueue.nextReachOut(for: unproven, of: p, now: now) == nil)
        #expect(ReachedOutQueue.active(from: [p], now: now).isEmpty)
    }

    @Test func bookedOrLostDropsOff() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 1_000_000)
        for oc: Outcome in [.booked, .lostSoft, .lostHard] {
            let p = makeShow(ctx, group: "g-\(oc.rawValue)")
            let r = makeRecipient(ctx, on: p, id: "c-\(oc.rawValue)@example.com",
                                  sentAt: now.addingTimeInterval(-86_400), outcome: oc)
            #expect(ReachedOutQueue.nextReachOut(for: r, of: p, now: now) == nil)
        }
    }

    @Test func noResponseSchedulesNextFollowUp() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 1_000_000)
        let sent = now.addingTimeInterval(-2 * 86_400)
        let p = makeShow(ctx, group: "A")
        let r = makeRecipient(ctx, on: p, sentAt: sent, outcome: .noResponse)
        // gapDays default 6: next nudge is sent + 6 days.
        #expect(ReachedOutQueue.nextReachOut(for: r, of: p, now: now) == sent.addingTimeInterval(6 * 86_400))
    }

    @Test func exhaustedFollowUpsWithNoReplyDropsOff() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 1_000_000)
        let p = makeShow(ctx, group: "A")
        let r = makeRecipient(ctx, on: p, sentAt: now.addingTimeInterval(-30 * 86_400), outcome: .noResponse)
        r.followUpCount = 2 // maxFollowUps default 2: exhausted, nothing scheduled
        #expect(ReachedOutQueue.nextReachOut(for: r, of: p, now: now) == nil)
    }

    @Test func repliedWithoutStateNeedsAttentionNow() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 1_000_000)
        let p = makeShow(ctx, group: "A")
        let r = makeRecipient(ctx, on: p, sentAt: now.addingTimeInterval(-86_400), outcome: .replied)
        // Replied but uncategorized: needs a state, so it should surface now.
        #expect(ReachedOutQueue.nextReachOut(for: r, of: p, now: now) == now)
    }

    // #223: a plain-language label for when to next reach out, shown on each reached-out row.
    @Test func timingLabelReadsOverdueTodayAndFuture() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        #expect(ReachedOutQueue.timingLabel(next: now, now: now) == "Reach out now")
        #expect(ReachedOutQueue.timingLabel(next: now.addingTimeInterval(-5 * 86_400), now: now) == "Reach out now")
        #expect(ReachedOutQueue.timingLabel(next: now.addingTimeInterval(86_400), now: now) == "in 1 day")
        #expect(ReachedOutQueue.timingLabel(next: now.addingTimeInterval(3 * 86_400), now: now) == "in 3 days")
    }

    // #661: the lightweight reached-out row only offers a "Send a follow-up" action once it's
    // actually due, the same "overdue or now" threshold timingLabel's "Reach out now" case uses, so
    // the button and the label can never disagree about whether something is due yet.
    @Test func isDueNowMatchesTheReachOutNowThreshold() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        #expect(ReachedOutQueue.isDueNow(next: now, now: now))
        #expect(ReachedOutQueue.isDueNow(next: now.addingTimeInterval(-5 * 86_400), now: now))
        #expect(!ReachedOutQueue.isDueNow(next: now.addingTimeInterval(86_400), now: now))
    }

    @Test func activeListIsSortedSoonestFirstAndExcludesStopped() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 10_000_000)
        let overdueShow = makeShow(ctx, group: "Overdue")
        _ = makeRecipient(ctx, on: overdueShow, sentAt: now.addingTimeInterval(-30 * 86_400), outcome: .noResponse)
        let freshShow = makeShow(ctx, group: "Fresh")
        _ = makeRecipient(ctx, on: freshShow, sentAt: now, outcome: .noResponse)
        let bookedShow = makeShow(ctx, group: "Booked")
        _ = makeRecipient(ctx, on: bookedShow, sentAt: now.addingTimeInterval(-86_400), outcome: .booked)

        let list = ReachedOutQueue.active(from: [freshShow, bookedShow, overdueShow], now: now)
        #expect(list.map(\.prospect.groupName) == ["Overdue", "Fresh"]) // booked excluded; overdue first
    }

    // #2396 reversed #652 deliberately. A show with two contacts, one overdue and one not yet due, is ONE
    // row: Dan judges events, not contacts. The row still speaks for a person (nobody replied here, so it is
    // the contact due soonest) and carries the soonest date across the whole show, so a show cannot sit
    // lower in the list than its most urgent contact deserves.
    @Test func aMultiContactShowIsOneRowSpeakingForItsMostUrgentContact() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 10_000_000)
        let p = makeShow(ctx, group: "Aurora Strings")
        let overdue = makeRecipient(ctx, on: p, id: "overdue@example.com",
                                    sentAt: now.addingTimeInterval(-30 * 86_400), outcome: .noResponse)
        let fresh = makeRecipient(ctx, on: p, id: "fresh@example.com", sentAt: now, outcome: .noResponse)

        let list = ReachedOutQueue.activeWithDates(from: [p], now: now)
        #expect(list.count == 1)
        #expect(list.first?.recipient.id == overdue.id)
        #expect(list.first?.next == ReachedOutQueue.nextReachOut(for: overdue, of: p, now: now))
        #expect(ReachedOutQueue.nextReachOut(for: fresh, of: p, now: now) != nil,
                "the fresh contact is still being chased, it just does not get a row of its own")
    }

    // #1194 made the PILL count shows while the list counted recipients. #2396 made the list count shows
    // too, so the pill's number and the rows beneath it are now the same quantity, which is what #1232's
    // reconciling note existed to explain away.
    @Test func thepillAndTheRowsCountTheSameThing() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 10_000_000)
        let sent = now.addingTimeInterval(-86_400)

        let a = makeShow(ctx, group: "A")
        _ = makeRecipient(ctx, on: a, id: "one@a.org", sentAt: sent)
        _ = makeRecipient(ctx, on: a, id: "two@a.org", sentAt: sent)   // same show, second contact
        let b = makeShow(ctx, group: "B")
        _ = makeRecipient(ctx, on: b, id: "one@b.org", sentAt: sent)

        #expect(ReachedOutQueue.active(from: [a, b], now: now).count == 2)   // two shows, two rows
        #expect(ReachedOutQueue.showCount(from: [a, b], now: now) == 2)      // and the pill agrees
    }
}

