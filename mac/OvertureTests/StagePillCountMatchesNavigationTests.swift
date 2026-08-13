import Testing
import Foundation
import SwiftData

// #863: a pill's number is a promise about how many rows tapping it lands you on. Nothing kept it.
//
// StageNavigation's header has stated the rule since #338: "what a pill shows is what tapping it
// navigates to." It was never tested, and it broke twice. #792: the Send pill counted a contact held
// by a review guard, and tapping took Dan nowhere, because the show holding it was already `.contacted`
// and the navigation only resolved approved ones. #861: the Scout pill counted 102 shows to triage when
// 25 had already happened, so it sent him looking for work that could not be done.
//
// Two of the four pills, wrong, for two different reasons, with the rule written down the whole time.
// The reason neither was caught is structural: the counts were computed inline in QueueView, a SwiftUI
// view, and the targets in StageNavigation, a pure enum. Only one of those two halves was reachable
// from a test, so the invariant could not be asserted even in principle.
//
// So this suite asserts it end to end, from the same prospects the app holds: for every pill, the
// number it states equals the number of rows its tap resolves, and every one of those rows is a show
// the focused list will actually render.
@MainActor
@Suite("A pill's number is the rows its tap lands on (#863)")
struct StagePillCountMatchesNavigationTests {
    private let today = ScoutTestClock.stageNavigationAnchor
    private let now = Date(timeIntervalSince1970: 1_768_000_000)

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func show(_ ctx: ModelContext, _ key: String, status: ReviewStatus = .new,
                      date: String = "2026-09-19", hasDraft: Bool = true, sentAt: Date? = nil) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: key, discipline: "music", venue: "Merkin Hall",
                         performanceDate: date, sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: status)
        if hasDraft { p.draftBody = "Hello, I photograph performances." }
        p.sentAt = sentAt
        ctx.insert(p)
        return p
    }

    @discardableResult
    private func contact(_ ctx: ModelContext, on p: Prospect, email: String = "a@org.example") -> Recipient {
        let r = Recipient(id: "\(p.naturalKey)-\(email)", email: email, name: "Someone",
                          role: "Manager", provenance: .act)
        r.prospect = p
        p.recipients.append(r)
        ctx.insert(r)
        return r
    }

    private func inputs(_ ctx: ModelContext) throws -> AgentInputs {
        let all = try ctx.fetch(FetchDescriptor<Prospect>())
        return AgentInputs.from(prospects: all, context: .at(today, now: now),
                                gmailConnected: true, runInFlight: nil, replyRunAlive: false)
    }

    private func pill(_ ctx: ModelContext, _ name: String) throws -> AgentStatus {
        let statuses = AgentRoster.statuses(try inputs(ctx))
        return statuses.first { $0.name == name }!
    }

    private func targets(_ ctx: ModelContext, _ status: AgentStatus) throws -> [String] {
        let all = try ctx.fetch(FetchDescriptor<Prospect>())
        return StageNavigation.naturalKeys(for: status.focus, in: all, context: .at(today, now: now))
    }

    // MARK: - The invariant itself

    // Every pill that filters the queue, over a store holding one of everything: the number Dan reads is
    // the number of rows he lands on. Follow-ups is exempt and says so: it opens FollowUpsView, which
    // lists due RECIPIENTS, so it never lands him on show rows at all.
    @Test func everyPillsNumberEqualsTheRowsItsTapLandsOn() throws {
        let ctx = try context()
        show(ctx, "to-triage", status: .new, hasDraft: false)
        show(ctx, "went-by", status: .new, date: "2026-06-27", hasDraft: false)   // #861: not work
        show(ctx, "to-prep", status: .queued, hasDraft: false)
        show(ctx, "to-review", status: .drafted)
        show(ctx, "to-send", status: .approved)

        for status in AgentRoster.statuses(try inputs(ctx)) where status.focus != .followUps {
            let rows = try targets(ctx, status)
            #expect(status.count == rows.count,
                    "\(status.name) says \"\(status.detail)\" (\(status.count)) but its tap lands on \(rows.count) rows")
        }
    }

    // The other half of the promise: a row it navigates to is a show the focused list can render. The
    // focused list filters the non-dismissed prospects, so a key that names no live prospect renders as
    // "These leads are no longer in your queue", which is the dead end #792 put Dan in.
    @Test func everyTargetIsAShowTheFocusedListWillRender() throws {
        let ctx = try context()
        show(ctx, "to-triage", status: .new, hasDraft: false)
        show(ctx, "to-prep", status: .queued, hasDraft: false)
        show(ctx, "to-review", status: .drafted)
        show(ctx, "to-send", status: .approved)
        let live = Set(try ctx.fetch(FetchDescriptor<Prospect>()).map(\.naturalKey))

        for status in AgentRoster.statuses(try inputs(ctx)) {
            for key in try targets(ctx, status) {
                #expect(live.contains(key), "\(status.name) navigates to \(key), which no live show answers to")
            }
        }
    }

    // #901: a show Dan cannot work that night is NOT ordinary prep work. The Prep run refuses to draft it
    // (no money is spent on a show that cannot happen), so the Prep pill must not offer it as work waiting
    // on a run: a pill that offers work the run will then decline to do is #863 all over again.
    //
    // #1583/#1691 fixed the OTHER half of that, which was a bug of its own. The pill used to report zero and
    // take Dan nowhere, and because the queue is stage-scoped only, a show in no stage is rendered nowhere
    // in the app at all: the row vanished, taking the control for clearing the clash with it. So the pill
    // reports these shows under their OWN focus, whose count and destination are the same list, exactly as
    // the Send pill reports five different problems. Counted apart, reachable, still never drafted.
    @Test func thePrepPillReportsABlockedShowApartFromTheWorkTheRunWillDo() throws {
        let ctx = try context()
        let kept = show(ctx, "kept-but-booked", status: .queued, hasDraft: false)
        kept.setScoutConflict(BlockedCalendar.Day(date: "2026-09-19", kind: .bookedShoot,
                                                  name: "Nguyen Recital").key)
        try ctx.save()

        let prep = try pill(ctx, "Prep")
        #expect(prep.focus == .prepBlocked)                         // reported as a clash, not as work
        #expect(prep.count == 1)
        #expect(try targets(ctx, prep) == ["kept-but-booked"])      // #1691: and the tap actually lands on it
        #expect(PrepQueueBuilder.needsPrepEligible(kept) == false)  // the run still won't take it

        // And once he overrules the clash, it is ordinary work again, counted and reachable as such.
        kept.clearConflict()
        try ctx.save()
        let cleared = try pill(ctx, "Prep")
        #expect(cleared.focus == .prep)
        #expect(cleared.count == 1)
    }

    // MARK: - Send: five different problems wearing one pill

    // #483 + #863: the show was SENT, so it is neither approved nor holding a blocked contact. Keyed by
    // the pill's NAME, its tap resolved the approved queue, which contains none of these. The pill named
    // a number and took him nowhere.
    @Test func theSentButUnwatchablePillLandsOnExactlyThoseShows() throws {
        let ctx = try context()
        let degraded = show(ctx, "sent-unwatchable", status: .contacted, sentAt: now)
        contact(ctx, on: degraded).replyTrackingDegraded = true
        show(ctx, "unrelated-approved", status: .approved)

        let send = try pill(ctx, "Send issues")

        #expect(send.focus == .sendDegraded)
        #expect(send.count == 1)
        #expect(try targets(ctx, send) == ["sent-unwatchable"])
    }

    // A failed send named 2 and landed him on every approved show, healthy ones included.
    @Test func theFailedToSendPillLandsOnOnlyTheFailedShows() throws {
        let ctx = try context()
        let failed = show(ctx, "failed", status: .approved)
        failed.sendError = "550 mailbox unavailable"
        show(ctx, "healthy-1", status: .approved)
        show(ctx, "healthy-2", status: .approved)

        let send = try pill(ctx, "Send issues")

        #expect(send.focus == .sendErrors)
        #expect(send.count == 1)
        #expect(try targets(ctx, send) == ["failed"])
    }

    // #475/#476: an unconfirmed send is the one thing Dan must resolve by hand in Gmail. Landing him on
    // the healthy approved queue instead buries it.
    @Test func theUnconfirmedSendPillLandsOnOnlyTheStuckShows() throws {
        let ctx = try context()
        let stuck = show(ctx, "stuck", status: .approved)
        let r = contact(ctx, on: stuck)
        r.sendState = .sending
        r.sendClaimedAt = now.addingTimeInterval(-RunTimeouts.send - 60)
        show(ctx, "healthy", status: .approved)

        let send = try pill(ctx, "Send issues")

        #expect(send.focus == .sendStuck)
        #expect(send.count == 1)
        #expect(try targets(ctx, send) == ["stuck"])
    }

    // The count-versus-shows half of the bug: two contacts held on ONE show. The pill used to count the
    // contacts (2) and land him on the shows (1 row), so the number promised work that was not there.
    // It counts shows now, and says so.
    @Test func theHeldContactPillCountsShowsNotContacts() throws {
        let ctx = try context()
        let held = show(ctx, "two-held", status: .contacted, sentAt: now)
        contact(ctx, on: held, email: "one@org.example").looksLikeVenue = true
        contact(ctx, on: held, email: "two@org.example").looksLikePressContact = true

        let send = try pill(ctx, "Send issues")

        #expect(send.focus == .sendBlocked)
        #expect(send.count == 1)
        #expect(send.detail == "1 show with a contact held for a check")
        #expect(try targets(ctx, send) == ["two-held"])
    }

    // #1146: a plain approved-and-ready queue with Gmail connected no longer surfaces a pill at all (it's
    // transient, sent from the review card), so the strip carries no "Send issues" pill for it.
    @Test func aConnectedApprovedQueueSurfacesNoSendIssuesPill() throws {
        let ctx = try context()
        show(ctx, "approved-1", status: .approved)
        show(ctx, "approved-2", status: .approved)

        let all = try ctx.fetch(FetchDescriptor<Prospect>())
        let statuses = AgentRoster.statuses(try inputs(ctx))
        #expect(statuses.contains { $0.name == "Send issues" } == false)
        // The navigation itself still resolves the approved unsent shows (used by the disconnected pill).
        #expect(Set(StageNavigation.naturalKeys(for: .sendApproved, in: all, context: .at(today, now: now)))
                == Set(["approved-1", "approved-2"]))
    }
}
